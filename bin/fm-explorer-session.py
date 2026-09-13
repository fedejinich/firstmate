#!/usr/bin/env python3
"""Firstmate's local Artifact Explorer broker.

The v1 interface is documented in docs/artifact-explorer-session.md.

Only an ancestor holding this home's session lock may start the broker.
It never polls Lavish, resolves renderer paths, or writes terminal input.
The inherited local process boundary and private capability protect the broker;
Explorer's main process must additionally authenticate its own IPC senders.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import socket
import socketserver
import struct
import sqlite3
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
SCHEMA = "fm-explorer-session/1"
ORIGIN = "artifact-explorer://app"
SENDER = "artifact-explorer-main"
LIMIT = 65536


def run(*argv, env=None):
    return subprocess.check_output(argv, text=True, env=env, timeout=15).strip()


def process_identity(pid):
    # Kernel process facts, not vendor banners or terminal titles.
    return run("/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "pid=")


def regular(path):
    """Open every component without following symlinks; retain the opened inode."""
    path = Path(path).absolute()
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        file_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
    finally:
        os.close(fd)
    with os.fdopen(file_fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("not a single-link regular file")
        digest = hashlib.sha256()
        while chunk := stream.read(65536):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        if (info.st_size, info.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError("file changed during read")
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, digest.hexdigest()]


class Broker:
    def __init__(self, home, task, artifact, version, directory, sender_pid):
        self.home = Path(home).absolute()
        self.state = self.home / "state"
        self.artifact = Path(artifact).absolute()
        self.task = task
        self.version = version
        self.sender_pid = sender_pid
        self.sender_identity = process_identity(sender_pid)
        self.directory = Path(directory).absolute()
        if len(os.fsencode(self.directory / "session.sock")) > 103:
            raise ValueError("socket path exceeds 103 bytes; choose a shorter private directory")
        if self.directory.parent.resolve() != self.directory.parent:
            raise ValueError("socket directory parent must not contain symlinks")
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}", task):
            raise ValueError("invalid task")
        if not version or len(version) > 256:
            raise ValueError("invalid version")
        self.env = dict(os.environ, FM_HOME=str(self.home))
        # Overrides must not redirect delivery away from the authenticated home.
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_ROOT_OVERRIDE"):
            self.env.pop(key, None)
        self.owner = int((self.state / ".lock").read_text().strip())
        parent = os.getpid()
        while parent != self.owner and parent > 1:
            parent = int(run("/bin/ps", "-p", str(parent), "-o", "ppid="))
        if parent != self.owner:
            raise ValueError("only the owning supervisor may start this adapter")
        self.identity = process_identity(self.owner)
        self.lock = regular(self.state / ".lock")
        self.meta = regular(self.state / (task + ".meta"))
        self.file = regular(self.artifact)
        self.source = run(str(ROOT / "fm-procevent-lavish.sh"), "source-id", str(self.artifact), env=self.env)
        self.source_path = self.state / "procevent" / (self.source + ".source")
        self.registration = regular(self.source_path)
        self.require_source()
        self.nonce = secrets.token_hex(32)
        self.token = secrets.token_hex(32)
        self.candidate = secrets.token_hex(16)
        self.binding = None
        self.generation = 0
        self.connected = False
        # A fresh private directory per launch prevents stale socket replacement.
        self.directory.mkdir(mode=0o700)
        ledger = self.state / "explorer-receipts"
        ledger.mkdir(mode=0o700, exist_ok=True)
        info = ledger.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("receipt directory must be private and owned")
        database = ledger / "receipts.sqlite"
        if database.exists() or database.is_symlink():
            regular(database)
        self.db = sqlite3.connect(database)
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, body TEXT NOT NULL)")
        self.db.execute("CREATE TABLE IF NOT EXISTS generations (id INTEGER PRIMARY KEY AUTOINCREMENT)")
        self.db.commit()

    def require_source(self):
        run(str(ROOT / "fm-procevent-lavish.sh"), "verify-source", str(self.artifact), env=self.env)
        rows = run(str(ROOT / "fm-procevent.sh"), "list", env=self.env).splitlines()
        if not any(row.split()[:3] == [self.source, "lavish", "live"] for row in rows):
            raise ValueError("review has no live Firstmate-owned listener")

    def live(self):
        try:
            if self.identity != process_identity(self.owner) or self.lock != regular(self.state / ".lock"):
                return "ended_session"
            if self.meta != regular(self.state / (self.task + ".meta")):
                return "stale_generation"
            if self.registration != regular(self.source_path):
                return "stale_generation"
            if self.file != regular(self.artifact):
                return "artifact_mismatch"
            self.require_source()
            return None
        except (OSError, ValueError, subprocess.SubprocessError):
            return "ended_session"

    def context(self):
        return dict(candidate=self.candidate, supervisor=self.nonce, task=self.task,
                    artifact_version=self.version, artifact_hash=self.file[-1],
                    review_source=self.source, lavish_key=self.source.removeprefix("lavish-"))

    def response(self, status, **fields):
        return dict(schema=SCHEMA, status=status, **fields)

    def reconcile(self, submission):
        row = self.db.execute("SELECT 1 FROM receipts WHERE id=?", (submission,)).fetchone()
        if not row:
            return self.response("known_non_delivery", submission=submission)
        status = "unknown_acknowledgement"
        # Locate only our exact body through the inbox owner's receipt interface.
        # Missing evidence after an attempted write is UNKNOWN, never retry permission.
        try:
            receipt = json.loads(run(str(ROOT / "fm-inbox.sh"), "receipt", submission, env=self.env))
            if receipt["status"] in ("queued", "delivered"):
                status = receipt["status"]
        except (OSError, ValueError, subprocess.SubprocessError):
            status = "unknown_acknowledgement"
        return self.response(status, submission=submission)

    def request(self, obj):
        if not isinstance(obj, dict) or obj.get("schema") != SCHEMA:
            return self.response("invalid_request")
        op = obj.get("operation")
        # Reconciliation is read-only and remains available after session end.
        if op == "reconcile":
            sid = obj.get("submission")
            if not isinstance(sid, str) or not re.fullmatch(r"[a-f0-9]{32}", sid):
                return self.response("invalid_request")
            return self.reconcile(sid)
        if error := self.live():
            return self.response(error)
        if op == "discover":
            return self.response("candidate", **self.context())
        if obj.get("context") != self.context():
            return self.response("context_mismatch")
        if op in ("select", "reconnect"):
            if op == "reconnect" and (obj.get("binding") != self.binding or obj.get("generation") != self.generation):
                return self.response("stale_generation")
            if op == "select" and self.binding is not None:
                return self.response("stale_generation")
            self.generation = self.db.execute("INSERT INTO generations DEFAULT VALUES").lastrowid
            self.db.commit()
            self.binding = secrets.token_hex(32)
            self.connected = False
            return self.response("pending_confirmation", binding=self.binding, generation=self.generation)
        if obj.get("binding") != self.binding or obj.get("generation") != self.generation or self.binding is None:
            return self.response("stale_generation")
        if op == "confirm":
            self.connected = True
            return self.response("connected", binding=self.binding, generation=self.generation)
        if op != "submit" or not self.connected:
            return self.response("pending_confirmation" if not self.connected else "invalid_request")
        sid, text = obj.get("submission"), obj.get("text")
        if not isinstance(sid, str) or not re.fullmatch(r"[a-f0-9]{32}", sid):
            return self.response("invalid_request")
        if not isinstance(text, str) or not text.strip() or len(text.encode()) > 32768 or "\0" in text:
            return self.response("invalid_request")
        body = json.dumps(dict(context=self.context(), binding=self.binding,
                               generation=self.generation, submission=sid, feedback=text), sort_keys=True)
        old = self.db.execute("SELECT body FROM receipts WHERE id=?", (sid,)).fetchone()
        if old:
            return self.response("duplicate_delivery" if old[0] == body else "submission_mismatch", submission=sid)
        # Record intent BEFORE any side effect. Never execute a repeated submission.
        try:
            self.db.execute("INSERT INTO receipts VALUES (?,?)", (sid, body))
            self.db.commit()
        except sqlite3.IntegrityError:
            self.db.rollback()
            return self.response("duplicate_delivery", submission=sid)
        try:
            subprocess.run([str(ROOT / "fm-inbox.sh"), "feedback", sid],
                           input=body, text=True, env=self.env, check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
        except (OSError, subprocess.SubprocessError):
            pass
        return self.reconcile(sid)


class Server(socketserver.UnixStreamServer):
    # Single request at a time serializes reconnect and submission without locks.
    def get_request(self):
        conn, address = super().get_request()
        conn.settimeout(5)
        return conn, address


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        broker = self.server.broker
        try:
            if sys.platform == "darwin":
                # Darwin LOCAL_PEERPID is a kernel credential, not a request header.
                peer_pid = struct.unpack("i", self.connection.getsockopt(0, 2, 4))[0]
            else:
                peer_pid, _, _ = struct.unpack("3i", self.connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            sender_matches = peer_pid == broker.sender_pid and process_identity(peer_pid) == broker.sender_identity
        except (OSError, subprocess.SubprocessError):
            sender_matches = False
        authorized = (sender_matches and self.path == "/v1" and
                      self.headers.get_all("Host") == ["firstmate.local"] and
                      self.headers.get_all("Origin") == [ORIGIN] and
                      self.headers.get_all("X-Firstmate-Sender") == [SENDER] and
                      self.headers.get_all("Authorization") == ["Bearer " + broker.token] and
                      not self.headers.get("Transfer-Encoding"))
        if not authorized:
            self.send_error(403)
            return
        try:
            length = int(self.headers["Content-Length"])
            if not 0 < length <= LIMIT or len(self.headers.get_all("Content-Length")) != 1:
                raise ValueError("invalid length")
            obj = json.loads(self.rfile.read(length))
            result = broker.request(obj)
        except (ValueError, KeyError, TypeError):
            result = broker.response("invalid_request")
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--launch", action="store_true", help="start locally, return the private grant path after readiness")
    parser.add_argument("--detached", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--home", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--artifact", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--directory", required=True, help="new private directory for socket and grant; never reused")
    parser.add_argument("--sender-pid", required=True, type=int, help="supervisor-approved Explorer main PID; kernel-verified on every request")
    args = parser.parse_args()
    os.umask(0o077)
    if args.launch:
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                  *[arg for arg in sys.argv[1:] if arg != "--launch"], "--detached"],
                                 stdout=subprocess.PIPE, text=True, start_new_session=True)
        grant_path = child.stdout.readline().strip()
        child.stdout.close()
        if not grant_path:
            raise SystemExit("adapter failed before publishing its grant")
        print(grant_path)
        return
    broker = Broker(args.home, args.task, args.artifact, args.version, args.directory, args.sender_pid)
    with Server(str(broker.directory / "session.sock"), Handler) as server:
        server.broker = broker
        grant = dict(schema=SCHEMA, socket=str(broker.directory / "session.sock"),
                     token=broker.token, origin=ORIGIN, sender=SENDER)
        (broker.directory / "grant.json").write_text(json.dumps(grant) + "\n")
        print(str(broker.directory / "grant.json"), flush=True)
        if args.detached:
            with open(os.devnull, "wb") as sink:
                os.dup2(sink.fileno(), 1)
                os.dup2(sink.fileno(), 2)
        server.timeout = 5
        while True:
            # This service follows only its own supervisor, not the fleet.
            try:
                if broker.identity != process_identity(broker.owner) or broker.lock != regular(broker.state / ".lock"):
                    break
            except (OSError, ValueError, subprocess.SubprocessError):
                break
            server.handle_request()


if __name__ == "__main__":
    main()
