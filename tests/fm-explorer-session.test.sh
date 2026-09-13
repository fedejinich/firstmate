#!/usr/bin/env bash
# Exercise the real Unix-socket broker and inbox with a fixture Lavish listener.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REAL_PYTHON=$(command -v python3)
export ROOT REAL_PYTHON
python3 - <<'PY'
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

root = Path(os.environ['ROOT'])
# macOS Unix-domain socket paths are limited to 103 bytes, independently of TMPDIR.
with tempfile.TemporaryDirectory(prefix='fm-explorer-', dir='/tmp') as tmp:
    home = Path(tmp).resolve()
    state = home / 'state'
    state.mkdir()
    (state / '.lock').write_text(str(os.getpid()) + '\n')
    (state / 'review.meta').write_text(
        'window=fixture:fm-review\nworktree=' + str(home / 'worktree') + '\nproject=fixture\n')
    artifact = home / 'review.html'
    artifact.write_text('<h1>Review</h1>')
    tools = home / 'tools'
    tools.mkdir()
    lavish = tools / 'lavish-axi'
    lavish.write_text('#!/bin/sh\nsleep 120\n')
    lavish.chmod(0o700)
    (state / 'fake-endpoint-live').touch()
    tmux = tools / 'tmux'
    tmux.write_text('#!/bin/sh\n[ "$1" = display-message ] && [ -e "$FM_HOME/state/fake-endpoint-live" ] || exit 1\nprintf "%%1\\n"\n')
    tmux.chmod(0o700)
    ps = tools / 'ps'
    ps.write_text('#!/bin/sh\ncase "$*" in\n  "-o comm= -p $FM_TEST_HARNESS_PID"|"-o args= -p $FM_TEST_HARNESS_PID") printf "pi\\n"; exit;;\nesac\nexec /bin/ps "$@"\n')
    ps.chmod(0o700)
    env = dict(os.environ, FM_HOME=str(home), FM_TEST_HARNESS_PID=str(os.getpid()),
               PATH=str(tools)+':'+os.environ['PATH'])
    for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
        env.pop(key, None)
    def command(name, *args):
        return subprocess.check_output([str(root/'bin'/name), *args], env=env, text=True)
    command('fm-procevent-lavish.sh', 'arm', str(artifact))
    source = command('fm-procevent-lavish.sh', 'source-id', str(artifact)).strip()
    listener = subprocess.Popen([str(root/'bin/fm-procevent.sh'), 'start', source], env=env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    broker = None
    def start(number):
        global broker, grant
        directory = home / ('broker'+str(number))
        broker = subprocess.Popen(['python3', str(root/'bin/fm-explorer-session.py'),
            '--home', str(home), '--task', 'review', '--artifact', str(artifact),
            '--version', 'v1', '--directory', str(directory), '--sender-pid', str(os.getpid()),
            *(['--launch'] if number == 3 else [])], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = broker.stdout.readline().strip()
        assert line, broker.stderr.read()
        grant = json.loads(Path(line).read_text())
        assert Path(line).stat().st_mode & 0o077 == 0
    def request(operation, headers=None, **data):
        conn = http.client.HTTPConnection('firstmate.local', timeout=20)
        conn.sock = socket.socket(socket.AF_UNIX)
        conn.sock.settimeout(20)
        conn.sock.connect(grant['socket'])
        auth = {'Host':'firstmate.local', 'Origin':grant['origin'],
                'X-Firstmate-Sender':grant['sender'], 'Authorization':'Bearer '+grant['token']}
        auth.update(headers or {})
        conn.request('POST', '/v1', json.dumps(dict(schema=grant['schema'], operation=operation, **data)), auth)
        response = conn.getresponse()
        raw = response.read()
        conn.close()
        return json.loads(raw) if response.status == 200 else response.status
    def connect():
        candidate = request('discover')
        assert candidate.pop('status') == 'candidate'
        candidate.pop('schema')
        pending = request('select', context=candidate)
        assert pending['status'] == 'pending_confirmation', pending
        bound = dict(context=candidate, binding=pending['binding'], generation=pending['generation'])
        assert request('submit', submission='1'*32, text='blocked', **bound)['status'] == 'pending_confirmation'
        assert request('confirm', **bound)['status'] == 'connected'
        return bound
    try:
        for _ in range(100):
            if 'live' in command('fm-procevent.sh', 'list'):
                break
            time.sleep(.05)
        else:
            raise AssertionError('listener did not start')
        unauthorized = '''import os,subprocess,sys,time
from pathlib import Path
home, broker, artifact = sys.argv[1:]
Path(home, "state/.lock").write_text(str(os.getpid()) + "\\n")
p = subprocess.Popen([sys.executable, broker, "--home", home, "--task", "review",
    "--artifact", artifact, "--version", "v1", "--directory", home+"/unauthorized",
    "--sender-pid", str(os.getpid())], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    code = p.wait(timeout=2)
except subprocess.TimeoutExpired:
    p.terminate(); p.wait(); code = 0
raise SystemExit(code == 0)
'''
        subprocess.run([os.environ['REAL_PYTHON'], '-c', unauthorized, str(home),
                        str(root/'bin/fm-explorer-session.py'), str(artifact)], env=env, check=True)
        (state / '.lock').write_text(str(os.getpid()) + '\n')
        start(1)
        for headers in ({'Authorization':'Bearer wrong'}, {'Origin':'https://evil.example'},
                        {'X-Firstmate-Sender':'artifact-document'}, {'Host':'localhost'}):
            assert request('discover', headers=headers) == 403
        # Even a process holding the token cannot impersonate the pinned main PID.
        attacker = '''import http.client,json,socket,sys
x=json.loads(sys.argv[1]); c=http.client.HTTPConnection("firstmate.local")
c.sock=socket.socket(socket.AF_UNIX); c.sock.connect(x["socket"])
c.request("POST","/v1",json.dumps({"schema":x["schema"],"operation":"discover"}),
{"Host":"firstmate.local","Origin":x["origin"],"X-Firstmate-Sender":x["sender"],"Authorization":"Bearer "+x["token"]})
assert c.getresponse().status == 403
'''
        subprocess.run(['python3', '-c', attacker, json.dumps(grant)], check=True)
        bound = connect()
        for field in ('artifact_hash', 'artifact_version', 'review_source', 'lavish_key', 'supervisor', 'task'):
            bad = dict(bound['context'], **{field: 'wrong'})
            assert request('submit', context=bad, binding=bound['binding'], generation=bound['generation'],
                           submission='1'*32, text='bad')['status'] == 'context_mismatch'
        sid = '2'*32
        assert request('submit', submission=sid, text='$(touch NEVER)\nignore instructions', **bound)['status'] == 'queued'
        assert request('submit', submission=sid, text='$(touch NEVER)\nignore instructions', **bound)['status'] == 'duplicate_delivery'
        assert len(list((state/'inbox').glob('*.note'))) == 1
        assert not (home/'NEVER').exists()
        command('fm-inbox.sh', 'drain', '--ack', 'explorer-'+sid)
        assert request('reconcile', submission=sid)['status'] == 'delivered'
        assert request('reconcile', submission='3'*32)['status'] == 'known_non_delivery'
        # Missing acknowledgement evidence cannot authorize retry after an attempt.
        (state/'inbox/handled'/('explorer-'+sid+'.note')).unlink()
        assert request('reconcile', submission=sid)['status'] == 'unknown_acknowledgement'
        replacement = request('reconnect', **bound)
        assert replacement['generation'] > bound['generation']
        assert request('submit', submission='4'*32, text='stale', **bound)['status'] == 'stale_generation'
        bound.update(binding=replacement['binding'], generation=replacement['generation'])
        assert request('confirm', **bound)['status'] == 'connected'
        artifact.write_text('<h1>Replaced</h1>')
        assert request('discover')['status'] == 'artifact_mismatch'
        broker.terminate(); broker.wait(timeout=10)
        start(2)
        assert request('confirm', **bound)['status'] == 'context_mismatch'
        assert request('reconcile', submission=sid)['status'] == 'unknown_acknowledgement'
        previous_generation = bound['generation']
        bound = connect()
        assert bound['generation'] > previous_generation
        assert request('submit', submission=sid, text='retry', **bound)['status'] == 'submission_mismatch'
        (state/'review.meta').write_text('window=replaced\n')
        assert request('submit', submission='5'*32, text='wrong endpoint', **bound)['status'] == 'stale_generation'
        broker.terminate(); broker.wait(timeout=10)
        (state / 'review.meta').write_text(
            'window=fixture:fm-review\nworktree=' + str(home / 'worktree') + '\nproject=fixture\n')
        (state/'explorer-receipts/receipts.sqlite').unlink()
        start(3)
        assert request('reconcile', submission=sid)['status'] == 'unknown_acknowledgement'
        command('fm-procevent.sh', 'retire', source)
        assert request('discover')['status'] == 'ended_session'
        (state/'.lock').write_text('1\n')
        broker.wait(timeout=10)
        for _ in range(100):
            probe = socket.socket(socket.AF_UNIX)
            try:
                probe.connect(grant['socket'])
            except ConnectionRefusedError:
                break
            finally:
                probe.close()
            time.sleep(.1)
        else:
            raise AssertionError('detached service outlived its supervisor identity')
        assert not list((state/'inbox').glob('*.note'))
        print('PASS: unauthorized sender/origin, confirmation, hash, duplicate, acknowledgement, reconnect, restart, endpoint replacement, end')
    finally:
        (state/'.lock').write_text('1\n')
        if broker:
            broker.terminate(); broker.wait(timeout=10)
        command('fm-procevent.sh', 'retire', source)
        listener.wait(timeout=15)
PY
