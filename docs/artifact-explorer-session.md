# Artifact Explorer session adapter

`bin/fm-explorer-session.py` owns the local `fm-explorer-session/1` interface described here.
Artifact Explorer consumes this interface, not Firstmate's private records or terminal endpoints.
This release supplies feedback delivery to the selected supervisor, not a transcript, terminal control, remote access, publishing, or a Lavish proxy.

## Start and handoff

The supervisor starts the adapter from its own process ancestry, with its current home, a recorded task, an existing artifact version, and the approved Explorer main-process PID.
Use `python3 bin/fm-explorer-session.py --help` for launch arguments.
`--launch` returns after the socket and grant exist; without it the service remains in the foreground.
The directory argument must name a new directory beneath an operator-controlled parent.
Each launch gets a new socket, secret capability, supervisor nonce and candidate ID.
The service follows the owning supervisor's process identity and session-lock identity and exits when either changes.
It never starts, stops or replaces a terminal endpoint.

Firstmate must already own the artifact's live Lavish listener through `bin/fm-procevent-lavish.sh arm`.
The adapter verifies the exact registered poll command and reads its owner's liveness without consuming any feedback.
No second Lavish poll is started.
The artifact must be an existing single-link regular file reached without symlinks in any path component.
The operator supplies its version identifier; the adapter computes its SHA-256 and pins the opened file identity.

The returned private `grant.json` contains `schema`, `socket`, `token`, `origin` and `sender`.
Deliver its path only to the approved Explorer main process over the application's trusted local handoff.
The main process can hold several supplied grants and call `discover` on each to build the session picker.
There is no filesystem-wide or terminal-wide discovery.
Neither an arbitrary library document nor its renderer may discover grants or obtain their tokens.
A token does not authorize another process: the socket checks the kernel peer PID and its process-start identity against the supervisor-approved PID on every request.
Restarting Explorer requires a fresh grant for its new main process.

## Transport and authorization

Use Node's Unix-domain `http.request` with `socketPath` in the approved main process.
There is no TCP listener and no browser-accessible HTTP endpoint.
The only method is `POST /v1`, with a JSON body, a single `Content-Length` of at most 65536 bytes, and these exact headers:

```text
Host: firstmate.local
Origin: artifact-explorer://app
X-Firstmate-Sender: artifact-explorer-main
Authorization: Bearer <grant token>
```

Duplicate authorization headers, a foreign origin, a different kernel peer, and transfer encoding are rejected with HTTP 403.
Application replies have HTTP 200 and `{ "schema": "fm-explorer-session/1", "status": "..." }` plus the fields below.
Explorer must still enforce exact shell webContents/frame ownership on its IPC handlers before invoking this transport.
Do not expose a raw broker-request method, token, socket path, or arbitrary request headers to renderer code.
The adapter trusts the owning OS account and supervisor-selected main process; it does not defend against compromise of either or an administrator.
Unsupported kernel peer-credential platforms are not authorized.
The implemented platforms are macOS and Linux.

## Binding operations

Every request includes `schema` and `operation`.
Unknown versions and malformed payloads return `invalid_request`.

- `discover` returns `candidate` and the exact context fields `candidate`, `supervisor`, `task`, `artifact_version`, `artifact_hash`, `review_source`, and `lavish_key`.
- `select` takes that object as `context` and returns `pending_confirmation`, an opaque `binding`, and an integer `generation`.
- `confirm` takes `context`, `binding`, and `generation` and returns `connected`.
- `reconnect` takes the old `context`, `binding`, and `generation`, immediately invalidates that binding, and returns a new `pending_confirmation` binding with a strictly increased generation.
- The replacement also requires `confirm`; no draft transfers and no submission is allowed during confirmation.

Generations are allocated durably across launches within a home.
A restarted supervisor has a new candidate and nonce and requires discovery, selection and confirmation again.
Reusing the old binding returns `stale_generation` or `context_mismatch`, not implicit reconnection.
A changed task record or source registration returns `stale_generation`.
An artifact replacement or content change returns `artifact_mismatch`.
An absent owner, task, artifact or listener returns `ended_session`.
No operation accepts a terminal endpoint, shell command, executable, filesystem path or replacement artifact from the client.
A revised artifact needs a newly authorized launch, rather than a renderer-requested path switch.

## Submission and reconciliation

`submit` requires the confirmed binding fields, a client-generated 32-character lowercase hexadecimal `submission` ID and nonempty `text` of at most 32768 UTF-8 bytes without NUL.
Use a cryptographically random ID and preserve it until reconciliation completes.
The adapter pins the full context and exact body to this ID in a durable attempt ledger before calling the inbox owner.
`bin/fm-inbox.sh feedback` stores an explicitly untrusted text note and wakes Firstmate through its existing inbox route.
It does not call `fm-send`, inject keystrokes, or turn feedback into a keyed captain decision.
Any later action remains the supervisor's decision under its existing authority rules.

`reconcile` takes only `submission` and remains read-only even if the binding is stale or the session has ended while the service remains reachable.
A fresh authorized adapter in the same home can reconcile previous attempts after a restart.
The following statuses describe delivery, independently of a returned artifact revision:

- `queued`: the durable inbox note exists; the supervisor has not acknowledged it.
- `delivered`: the supervisor moved that note to the inbox owner's `handled/` location, meaning it consumed the feedback, not that it executed a request or produced a revision.
- `unknown_acknowledgement`: an attempt was recorded but no authoritative note/acknowledgement is currently available, or the receipt query failed.
- `known_non_delivery`: this home's ledger has no attempt for that ID.
- `duplicate_delivery`: that ID was already attempted with the same payload; no second delivery was attempted.
- `submission_mismatch`: the ID already belongs to a different payload or binding; it cannot be repurposed.

A timeout, lost response, unavailable socket, or process exit never proves non-delivery.
Check the same ID through `reconcile`; never invent another ID to bypass an unknown result.
An unknown attempt stays unknown if its evidence is lost, rather than being guessed safe to resend.
The adapter provides at-most-once enqueue attempts with durable reconciliation, not an exactly-once promise across arbitrary storage failure.
Retain the home-local `state/explorer-receipts` ledger and inbox attempt markers while any submitted ID might still be reconciled.
The inbox owner's existing acknowledgement procedure is unchanged.

## Integration check

Run `bin/fm-test-run.sh tests/fm-explorer-session.test.sh` for the executable socket, binding, receipt and security regression.
The test uses the real process-event ownership and inbox commands with an inert fixture Lavish executable; it never starts a second real review listener or a terminal session.
The service is independent of worker runtime and terminal backend because it delivers only to the supervisor inbox and reads existing identity/ownership contracts.
Explorer's isolated review host, IPC authorization and real UI handoff still require their own end-to-end checks.
