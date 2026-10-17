#!/usr/bin/env bash
# Print the tail of a crewmate endpoint (bounded, for cheap diagnosis).
# Usage: fm-peek.sh <target> [lines=40] [--deep]
#   <target> may be an exact task id, a legacy fm-<id> task label resolved
#   through this home's state/<id>.meta, or an explicit backend target.
# A selector whose meta records remote_host= is a remote secondmate: its pane
# lives on that host, so the capture routes over fm-on.sh to the host-local
# capture (fm-remote-secondmate-control.sh), clamped to that command's
# 100-line cap. An unreachable host or unreadable endpoint fails loudly naming
# the host; the local backend adapters are never asked to read a remote target.
# The read is the passive routine capture (fm_backend_capture), which on herdr
# returns at most the visible viewport. --deep is the one explicit opt-in to the
# history read (fm_backend_history_capture): on herdr, a line count above the
# viewport then reads history and may briefly scroll an idle agent's screen.
# A task record whose endpoint is this firstmate session's own pane, or now
# holds another agent, is refused (fm_backend_endpoint_not_task_agent).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

DEEP=
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --deep) DEEP=--deep ;;
    *) ARGS+=("$arg") ;;
  esac
done
[ "${#ARGS[@]}" -ge 1 ] && [ "${#ARGS[@]}" -le 2 ] \
  || { echo "usage: fm-peek.sh <target> [lines=40] [--deep]" >&2; exit 2; }
RAW_TARGET=${ARGS[0]}
N=${ARGS[1]:-40}

REMOTE_META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null || true)
if [ -n "$REMOTE_META" ] && [ -n "$(fm_meta_get "$REMOTE_META" remote_host)" ]; then
  REMOTE_ID=${REMOTE_META##*/}
  REMOTE_ID=${REMOTE_ID%.meta}
  REMOTE_HOST=$(fm_meta_get "$REMOTE_META" remote_host)
  case "$N" in ''|*[!0-9]*|0) N=40 ;; esac
  [ "$N" -le 100 ] || N=100
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$REMOTE_ID" \
    fm-remote-secondmate-control.sh capture "$REMOTE_ID" "$N" ${DEEP:+"$DEEP"} < /dev/null; then
    echo "error: could not read the remote pane of $REMOTE_ID on $REMOTE_HOST (host unreachable or endpoint unreadable; the mate is not thereby dead)" >&2
    exit 1
  fi
  exit 0
fi

T=$(fm_backend_resolve_selector "$RAW_TARGET" "$STATE")

BACKEND=$(fm_backend_of_selector "$RAW_TARGET" "$T" "$STATE")
EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$RAW_TARGET" "$STATE")
META=$(fm_backend_meta_for_selector "$RAW_TARGET" "$STATE" 2>/dev/null \
  || fm_backend_meta_for_window "$T" "$STATE" 2>/dev/null || true)
if [ -n "$META" ] && NOT_TASK_AGENT=$(fm_backend_endpoint_not_task_agent "$BACKEND" "$T" "$META"); then
  echo "error: ${NOT_TASK_AGENT#*$'\t'}; refusing to read it - reconcile the task record instead" >&2
  exit 1
fi

if [ -n "$DEEP" ]; then
  fm_backend_history_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
else
  fm_backend_capture "$BACKEND" "$T" "$N" "$EXPECTED_LABEL"
fi
