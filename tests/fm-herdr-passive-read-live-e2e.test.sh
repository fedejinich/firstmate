#!/usr/bin/env bash
# Live Herdr passive-read and endpoint-identity guard (live-harness-optin family).
#
# Herdr answers a `pane read --source recent --lines N` above the viewport of a
# pane holding an idle alternate-screen agent by writing mouse-wheel input into
# the pane to harvest the agent's own transcript, which visibly scrolls Claude
# Code up and back. A stub cannot show what Herdr writes into a real pty, so this
# guard runs real Claude Code behind a pty logger deliberately named `claude`
# (Herdr's agent detection keys on that name) in an isolated Herdr lab and
# requires:
#   - every routine read (fm_backend_capture and a default fm-peek, at and above
#     the viewport, plus the composer, rendered busy, and steering-inbox doorbell
#     reads) writes zero
#     wheel events and still sees Claude's idle composer, idle footer, and an
#     unsubmitted doorbell line;
#   - the explicit deep read (fm-peek --deep) beyond the viewport
#     still returns history, and does harvest, so the zero above is not vacuous;
#   - Claude's registered agent session is readable within the spawn's recording
#     budget, and a second Claude in the same pane registers a new one within it
#     and reads as foreign against the first one's session;
#   - a process whose own pane is the target is refused.
# It fails naming the Claude and Herdr versions rather than degrading quietly.
#
# Run explicitly with FM_HERDR_PASSIVE_READ_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Passive reads and endpoint identity" entry. It submits one short prompt.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_PASSIVE_READ_LIVE herdr jq claude cc

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_PASSIVE_READ_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-passive-read-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-passive-read-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
WRAPDIR="$TMP_ROOT/wrap"
WORKDIR="$TMP_ROOT/work"
PTYLOG="$TMP_ROOT/pty.log"
mkdir -p "$FAKEBIN" "$WRAPDIR" "$WORKDIR"
: > "$PTYLOG"

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# The pty logger: runs the real Claude on an inner pty and logs every byte
# written into the pane as escaped text, so a wheel event reads as \x1b[<64;...
cat > "$WRAPDIR/ptylog.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
static volatile sig_atomic_t winch = 0;
static void onwinch(int s) { (void)s; winch = 1; }
int main(int argc, char **argv) {
  const char *real = getenv("REAL_CLAUDE");
  FILE *lg = fopen(getenv("PTYLOG"), "a");
  struct winsize ws; struct termios raw, orig; char b[65536]; int m, st; pid_t child;
  (void)argc;
  if (!real || !lg) return 2;
  setvbuf(lg, 0, _IOLBF, 0);
  ioctl(0, TIOCGWINSZ, &ws);
  child = forkpty(&m, 0, 0, &ws);
  if (child == 0) { argv[0] = (char *)real; execv(real, argv); _exit(127); }
  tcgetattr(0, &orig); raw = orig; cfmakeraw(&raw); tcsetattr(0, TCSANOW, &raw);
  signal(SIGWINCH, onwinch);
  for (;;) {
    fd_set f; struct timeval tv = {0, 200000}; ssize_t n, i;
    if (winch) { winch = 0; ioctl(0, TIOCGWINSZ, &ws); ioctl(m, TIOCSWINSZ, &ws); kill(child, SIGWINCH); }
    FD_ZERO(&f); FD_SET(0, &f); FD_SET(m, &f);
    if (select(m + 1, &f, 0, 0, &tv) < 0) continue;
    if (FD_ISSET(0, &f)) {
      if ((n = read(0, b, sizeof b)) <= 0) break;
      fputs("IN ", lg);
      for (i = 0; i < n; i++) {
        unsigned char c = b[i];
        if (c >= 32 && c < 127 && c != '\\') fputc(c, lg); else fprintf(lg, "\\x%02x", c);
      }
      fputc('\n', lg);
      if (write(m, b, n) < 0) break;
    }
    if (FD_ISSET(m, &f)) {
      if ((n = read(m, b, sizeof b)) <= 0) break;
      if (write(1, b, n) < 0) break;
    }
  }
  tcsetattr(0, TCSANOW, &orig); waitpid(child, &st, 0); return 0;
}
C
LIBS=''
[ "$(uname -s)" = Darwin ] || LIBS='-lutil'
# shellcheck disable=SC2086 # LIBS is empty or one flag.
cc -O2 -o "$WRAPDIR/claude" "$WRAPDIR/ptylog.c" $LIBS \
  || fail "could not build the pty logger the guard needs"
REAL_CLAUDE=$(PATH="$ORIGINAL_PATH" command -v claude)
REAL_CLAUDE=$(cd "$(dirname "$REAL_CLAUDE")" && pwd -P)/$(basename "$REAL_CLAUDE")
while [ -L "$REAL_CLAUDE" ]; do
  link=$(readlink "$REAL_CLAUDE")
  case "$link" in /*) REAL_CLAUDE=$link ;; *) REAL_CLAUDE=$(dirname "$REAL_CLAUDE")/$link ;; esac
done

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "could not load the herdr adapter"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$WORKDIR" --label fm-passiveread --no-focus) \
  || fail "could not create the isolated passive-read workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
WHO="Claude Code ($VERSION) on $HERDR_VER"

wheel_events() { grep -o '\\x1b\[<6[45];' "$PTYLOG" 2>/dev/null | wc -l | tr -d '[:space:]'; }
agent_status() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

launch_claude() {
  lab pane run "$PANE" "env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 PTYLOG='$PTYLOG' REAL_CLAUDE='$REAL_CLAUDE' '$WRAPDIR/claude' --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
    || fail "could not launch $WHO in the isolated Herdr pane"
}

wait_idle_composer() {
  local i=0 trusted=0 screen
  while [ "$i" -lt 90 ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        case "$(agent_status)" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$PANE" down enter >/dev/null || fail "could not accept Claude's folder-trust prompt"
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  fail "$WHO never rendered an idle composer in the lab pane; its screen was:"$'\n'"$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -12)"
}

# --- 1. a transcript taller than the viewport, then an idle agent ------------
# The lab directory is fresh, so Claude first asks to trust it; fm-spawn
# pre-trusts a worker's copy, so the session budget below is timed from there.
launch_claude
wait_idle_composer
FIRST_SESSION=$(fm_backend_herdr_wait_agent_session "$TARGET" 15) \
  || fail "$WHO registered no readable agent session within fm-spawn's 15s recording budget"
lab pane send-text "$PANE" "Print the integers 1 to 150, one per line, as plain text. No tools, no commentary." >/dev/null \
  || fail "could not type the transcript prompt"
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit the transcript prompt"
i=0
while [ "$i" -lt 120 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  # The last integer on a row of its own (the prompt line also contains 150),
  # with the turn's busy footer gone.
  if printf '%s\n' "$screen" | grep -Eq '^[^A-Za-z0-9]*150[[:space:]]*$' \
    && ! printf '%s\n' "$screen" | grep -Fq 'esc to interrupt'; then
    case "$(agent_status)" in idle|done) break ;; esac
  fi
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 120 ] || fail "$WHO never finished printing a transcript taller than the viewport"
sleep 2
ROWS=$(fm_backend_herdr_viewport_rows "$SESSION" "$PANE") || fail "could not read the lab pane's viewport height"
CHECKED=0
# An operator's fm-peek of the pane, through a task record in a scratch home.
PEEK_HOME="$TMP_ROOT/home"
mkdir -p "$PEEK_HOME/state"
printf 'window=%s\nbackend=herdr\nherdr_agent_session=%s\n' "$TARGET" "$FIRST_SESSION" > "$PEEK_HOME/state/peeklab.meta"
peek() { FM_HOME="$PEEK_HOME" FM_STATE_OVERRIDE="$PEEK_HOME/state" "$ROOT/bin/fm-peek.sh" peeklab "$@" 2>/dev/null; }

# --- 2. routine reads write nothing into the pane ----------------------------
before=$(wheel_events)
small=$(fm_backend_capture herdr "$TARGET" 40) || fail "$WHO: a routine 40-line capture failed"
large=$(fm_backend_capture herdr "$TARGET" 500) || fail "$WHO: a routine capture larger than the viewport failed"
peeked=$(peek 120) || fail "$WHO: a default fm-peek beyond the viewport failed"
[ "$(printf '%s\n' "$peeked" | wc -l | tr -d '[:space:]')" -le "$ROWS" ] \
  || fail "$WHO: a default fm-peek returned more rows than the ${ROWS}-row viewport, so it read history"
composer=$(fm_backend_composer_state herdr "$TARGET")
footer=$(fm_backend_herdr_rendered_busy_state "$TARGET" claude)
sleep 2
after=$(wheel_events)
[ "$after" = "$before" ] \
  || fail "$WHO: routine reads wrote $((after - before)) mouse-wheel events into an idle Claude pane"
[ -n "$small" ] || fail "$WHO: a routine capture of an idle Claude pane came back empty"
[ "$(printf '%s\n' "$large" | wc -l | tr -d '[:space:]')" -le "$ROWS" ] \
  || fail "$WHO: a routine capture returned more rows than the ${ROWS}-row viewport, so it read history"
[ "$composer" = empty ] || fail "$WHO: the composer read on a visible capture said '$composer', not empty"
# The steering-inbox doorbell check reads the composer through the same routine
# capture: an unsubmitted doorbell line must be seen there, then cleared.
DOORBELL="Firstmate instruction waiting: read the fm-passiveread inbox"
lab pane send-text "$PANE" "$DOORBELL" >/dev/null || fail "could not type the doorbell line"
sleep 1
before=$(wheel_events)
held=0
fm_task_inbox_composer_holds herdr "$TARGET" "$DOORBELL" && held=1
sleep 1
after=$(wheel_events)
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "could not clear the doorbell line"
[ "$held" = 1 ] || fail "$WHO: the steering-inbox doorbell check did not see an unsubmitted doorbell on a visible capture"
[ "$after" = "$before" ] || fail "$WHO: the doorbell check wrote $((after - before)) mouse-wheel events into the pane"
[ "$footer" = idle ] \
  || fail "$WHO: the rendered busy read on a visible capture said '$footer', not idle; its rows were:"$'\n'"$(printf '%s\n' "$small" | grep -v '^[[:space:]]*$' | tail -12)"
CHECKED=1
pass "live Herdr passive reads: $WHO receives zero wheel events from routine reads, which still see its idle composer, idle footer, and an unsubmitted doorbell"

# --- 3. the explicit deep read still returns history -------------------------
before=$(wheel_events)
deep=$(peek 200 --deep) || fail "$WHO: the fm-peek --deep history read failed"
sleep 2
after=$(wheel_events)
deep_rows=$(printf '%s\n' "$deep" | wc -l | tr -d '[:space:]')
[ "$deep_rows" -gt "$ROWS" ] \
  || fail "$WHO: the deep read returned $deep_rows rows, not more than the ${ROWS}-row viewport"
[ "$after" -gt "$before" ] \
  || fail "$WHO: the deep read wrote no wheel events, so the zero above proves nothing on this Herdr"
pass "live Herdr deep read: fm-peek --deep of $WHO returns $deep_rows rows of history beyond its ${ROWS}-row viewport, and Herdr wrote $((after - before)) wheel events harvesting them"

# --- 4. the caller's own pane is refused ------------------------------------
own=$(FM_BACKEND_HERDR_SELF_PANE=$PANE FM_BACKEND_HERDR_SELF_SESSION=$SESSION fm_backend_capture herdr "$TARGET" 40 2>&1) \
  && fail "$WHO: a capture of the caller's own pane was not refused: $own"
[ "$(FM_BACKEND_HERDR_SELF_PANE=$PANE FM_BACKEND_HERDR_SELF_SESSION=$SESSION fm_backend_herdr_endpoint_identity "$TARGET" "$FIRST_SESSION")" = self ] \
  || fail "$WHO: the caller's own pane did not read as self"
pass "live Herdr self guard: a read of the caller's own pane is refused"

# --- 5. a second agent in the same pane is foreign ---------------------------
[ "$(fm_backend_herdr_endpoint_identity "$TARGET" "$FIRST_SESSION")" = own ] \
  || fail "$WHO: the running agent did not read as its own recorded session"
lab pane send-text "$PANE" "/exit" >/dev/null || fail "could not type /exit"
sleep 1
lab pane send-keys "$PANE" enter >/dev/null || fail "could not submit /exit"
i=0
while [ "$i" -lt 30 ]; do
  case "$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE")" in no-agent|stale-agent|dead) break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 30 ] || fail "$WHO did not exit from the lab pane"
# The pane still reports the first agent's session until the second one's
# registration replaces it, which is why fm-spawn waits past the stale value.
launch_start=$(date +%s)
launch_claude
SECOND_SESSION=$(fm_backend_herdr_wait_agent_session "$TARGET" 15 "$FIRST_SESSION") \
  || fail "$WHO: a second Claude in the same pane registered no session distinct from the first within 15s"
session_secs=$(( $(date +%s) - launch_start ))
[ "$(fm_backend_herdr_endpoint_identity "$TARGET" "$FIRST_SESSION")" = "foreign"$'\t'"$SECOND_SESSION" ] \
  || fail "$WHO: a second Claude in the pane did not read as foreign against the first one's recorded session"
pass "live Herdr endpoint identity: a second $WHO in the same pane registers a new session within ${session_secs}s and reads as foreign"

[ "$CHECKED" = 1 ] || fail "the live passive-read guard checked nothing"
