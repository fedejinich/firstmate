#!/usr/bin/env bash
# Durable result owner for one TUI-confirmed project-registration request.
#
# This helper does not register a project. Firstmate's project-management
# procedure remains the only owner of ownership checks, authentication, cloning,
# registry edits, remote creation, initialization, and policy. A confirmed
# requester supplies the first 128 bits of the request's SHA-256 as a lowercase-
# hex request ID and the full SHA-256 digest. Firstmate calls `begin` before any
# authentication check or mutation, performs the existing procedure only when
# `begin` prints `created`, then calls `finish` with the observed result.
#
# `digest` hashes the UTF-8 bytes of compact, sorted-key JSON with these exact
# request fields and no trailing newline:
#   schema            "fm-project-registration-request.v1"
#   project           safe local project name
#   source_url        string or null
#   observed_path     absolute string or null
#   description       one-line string or null
#   posture           no-mistakes|direct-PR|local-only|no-mistakes-prod-only
#   autonomous_merge  boolean
# The requester and Firstmate must supply the same normalized field values.
# `begin` recomputes the digest and refuses a mismatch before writing anything.
#
# Records live at:
#   $FM_HOME/state/project-registration-outcomes/<request-id>.json
# or under FM_STATE_OVERRIDE for tests and specialized setups. The directory is
# an owned, non-symlink mode-0700 directory. Each record is one owned,
# non-symlink, single-link mode-0600 regular file published by atomic rename.
#
# The exact fm-project-registration-outcome.v1 record has only these fields:
#   schema          "fm-project-registration-outcome.v1"
#   request_id      the first 32 characters of request_digest
#   request_digest  64 lowercase hexadecimal characters
#   project         the safe local project name
#   outcome         pending|success|authentication-failure|rejected|indeterminate
#   reason          awaiting-firstmate                 when outcome=pending
#                   registered                         when outcome=success
#                   authentication-required            when outcome=authentication-failure
#                   destination-conflict|secondmate-owned|policy-rejected
#                                                      when outcome=rejected
#                   completion-unproven                 when outcome=indeterminate
# No request text, source URL, description, observed path, credentials, command
# output, or executable content is stored. The request digest binds those exact
# immutable details without publishing them.
#
# State machine and retry contract:
#   absent -> pending (`begin` prints `created`)
#   pending -> any non-pending outcome
#   indeterminate -> success|authentication-failure|rejected after reconciliation
#   success|authentication-failure|rejected are immutable
# A matching duplicate `begin` prints `existing <outcome>` and never authorizes
# the registration procedure to run again. Reconcile an existing pending or
# indeterminate request from disk; do not clone, overwrite, or append a registry
# row again. `finish success` independently observes the exact registry posture,
# destination repository and requested origin, and required no-mistakes doctor
# result before publishing success. Missing proof leaves the prior record intact.
#
# Retention and cleanup are Firstmate-owned. There is no automatic expiry, so a
# refresh or dead requester cannot remove the result. `retire` requires the exact
# request binding and refuses pending or indeterminate records. Firstmate may use
# it only after the captain-visible settled result no longer needs to be retained.
#
# Usage:
#   fm-project-registration-outcome.sh digest REQUEST_OPTIONS
#   fm-project-registration-outcome.sh begin --request-id ID --request-digest SHA REQUEST_OPTIONS
#   fm-project-registration-outcome.sh finish --request-id ID --request-digest SHA REQUEST_OPTIONS --outcome OUTCOME [--reason REASON]
#   fm-project-registration-outcome.sh inspect --request-id ID --request-digest SHA
#   fm-project-registration-outcome.sh retire --request-id ID --request-digest SHA
#
# REQUEST_OPTIONS:
#   --project NAME --posture POSTURE --autonomous-merge on|off
#   [--source-url URL] [--observed-path ABSOLUTE_PATH] [--description ONE_LINE]
#
# `inspect` prints the validated compact JSON record. It exits 3, silently, when
# no record exists. Every other refusal exits nonzero with a secret-free reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
OUTCOMES="$STATE/project-registration-outcomes"
REQUEST_SCHEMA='fm-project-registration-request.v1'
OUTCOME_SCHEMA='fm-project-registration-outcome.v1'

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

# Load the fleet's portable crash-recovering lock only for commands that write.
# Sourcing it creates STATE when absent, so digest and inspect deliberately do
# not load it.
load_lock_lib() {
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

usage() {
  cat <<'EOF'
usage:
  fm-project-registration-outcome.sh digest REQUEST_OPTIONS
  fm-project-registration-outcome.sh begin --request-id ID --request-digest SHA REQUEST_OPTIONS
  fm-project-registration-outcome.sh finish --request-id ID --request-digest SHA REQUEST_OPTIONS --outcome OUTCOME [--reason REASON]
  fm-project-registration-outcome.sh inspect --request-id ID --request-digest SHA
  fm-project-registration-outcome.sh retire --request-id ID --request-digest SHA

REQUEST_OPTIONS:
  --project NAME --posture POSTURE --autonomous-merge on|off
  [--source-url URL] [--observed-path ABSOLUTE_PATH] [--description ONE_LINE]

The script header owns the request digest, outcome schema, state machine,
idempotency, success-proof, privacy, publication, and retention contracts.
`begin` prints `created` only for a newly accepted request. `existing <outcome>`
means the caller must not repeat registration mutations.
EOF
}

die() {
  printf 'fm-project-registration-outcome: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

path_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

path_links() {
  if stat -f '%l' "$1" >/dev/null 2>&1; then
    stat -f '%l' "$1"
  else
    stat -c '%h' "$1"
  fi
}

private_dir_valid() {
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] && [ "$(path_mode "$1")" = 700 ]
}

private_file_valid() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] \
    && [ "$(path_mode "$1")" = 600 ] && [ "$(path_links "$1")" = 1 ]
}

ensure_outcomes_dir() {
  local old_umask
  if [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
    old_umask=$(umask)
    umask 077
    mkdir -p -- "$STATE" || { umask "$old_umask"; die "cannot create the state directory"; }
    umask "$old_umask"
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -O "$STATE" ] \
    || die "state directory is not an owned non-symlink directory"

  if [ ! -e "$OUTCOMES" ] && [ ! -L "$OUTCOMES" ]; then
    old_umask=$(umask)
    umask 077
    mkdir -- "$OUTCOMES" || { umask "$old_umask"; die "cannot create the outcome directory"; }
    umask "$old_umask"
  fi
  private_dir_valid "$OUTCOMES" \
    || die "outcome directory must be an owned non-symlink mode-0700 directory"
}

require_outcomes_dir() {
  if [ ! -e "$OUTCOMES" ] && [ ! -L "$OUTCOMES" ]; then
    return 3
  fi
  private_dir_valid "$OUTCOMES" \
    || die "outcome directory must be an owned non-symlink mode-0700 directory"
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    die "required SHA-256 tool not found"
  fi
}

has_control() {
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; esac
  LC_ALL=C printf '%s' "$1" | grep -q '[[:cntrl:]]'
}

valid_request_id() {
  [ "${#1}" -eq 32 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

valid_digest() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

validate_request() {
  [ -n "$PROJECT" ] || die "--project is required"
  [ "${#PROJECT}" -le 128 ] || die "project name is too long"
  case "$PROJECT" in
    .*|-*|*[!A-Za-z0-9._-]*) die "unsafe project name" ;;
  esac
  case "$POSTURE" in
    no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
    *) die "invalid project posture" ;;
  esac
  case "$AUTONOMOUS_MERGE" in on|off) ;; *) die "invalid autonomous-merge value" ;; esac

  if [ "$SOURCE_SET" -eq 1 ]; then
    [ "${#SOURCE_URL}" -le 4096 ] || die "source URL is too long"
    fm_project_origin_safe "$SOURCE_URL" || die "unsafe project source URL"
  elif [ "$POSTURE" != local-only ]; then
    die "remote-backed posture requires --source-url"
  fi

  if [ "$OBSERVED_SET" -eq 1 ]; then
    [ "${#OBSERVED_PATH}" -le 4096 ] || die "observed path is too long"
    case "$OBSERVED_PATH" in /*) ;; *) die "observed path must be absolute" ;; esac
    has_control "$OBSERVED_PATH" && die "observed path contains a control character"
  fi

  if [ "$DESCRIPTION_SET" -eq 1 ]; then
    [ "${#DESCRIPTION}" -le 4096 ] || die "description is too long"
    has_control "$DESCRIPTION" && die "description must be one line without control characters"
  fi
  return 0
}

request_json() {
  jq -cnS \
    --arg schema "$REQUEST_SCHEMA" \
    --arg project "$PROJECT" \
    --arg source "$SOURCE_URL" \
    --argjson source_set "$SOURCE_SET" \
    --arg observed "$OBSERVED_PATH" \
    --argjson observed_set "$OBSERVED_SET" \
    --arg description "$DESCRIPTION" \
    --argjson description_set "$DESCRIPTION_SET" \
    --arg posture "$POSTURE" \
    --argjson autonomous_merge "$([ "$AUTONOMOUS_MERGE" = on ] && printf true || printf false)" \
    '{schema:$schema, project:$project,
      source_url:(if $source_set == 1 then $source else null end),
      observed_path:(if $observed_set == 1 then $observed else null end),
      description:(if $description_set == 1 then $description else null end),
      posture:$posture, autonomous_merge:$autonomous_merge}'
}

compute_digest() {
  local payload
  payload=$(request_json) || die "cannot encode the registration request"
  printf '%s' "$payload" | sha256_stdin
}

reason_pair_valid() {
  case "$1:$2" in
    pending:awaiting-firstmate|success:registered|authentication-failure:authentication-required|\
    rejected:destination-conflict|rejected:secondmate-owned|rejected:policy-rejected|\
    indeterminate:completion-unproven) return 0 ;;
    *) return 1 ;;
  esac
}

record_valid() {
  local path=$1
  private_file_valid "$path" || return 1
  jq -e --arg schema "$OUTCOME_SCHEMA" '
    type == "object"
    and (keys == ["outcome", "project", "reason", "request_digest", "request_id", "schema"])
    and .schema == $schema
    and (.request_id | type == "string" and test("^[0-9a-f]{32}$"))
    and (.request_digest | type == "string" and test("^[0-9a-f]{64}$"))
    and (.project | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
    and (.outcome | type == "string")
    and (.reason | type == "string")
    and (
      (.outcome == "pending" and .reason == "awaiting-firstmate")
      or (.outcome == "success" and .reason == "registered")
      or (.outcome == "authentication-failure" and .reason == "authentication-required")
      or (.outcome == "rejected" and (.reason == "destination-conflict" or .reason == "secondmate-owned" or .reason == "policy-rejected"))
      or (.outcome == "indeterminate" and .reason == "completion-unproven")
    )
  ' "$path" >/dev/null 2>&1
}

record_binding_matches() {
  jq -e \
    --arg request_id "$REQUEST_ID" \
    --arg request_digest "$REQUEST_DIGEST" \
    --arg project "$PROJECT" \
    '.request_id == $request_id and .request_digest == $request_digest and .project == $project' \
    "$1" >/dev/null 2>&1
}

inspect_binding_matches() {
  jq -e \
    --arg request_id "$REQUEST_ID" \
    --arg request_digest "$REQUEST_DIGEST" \
    '.request_id == $request_id and .request_digest == $request_digest' \
    "$1" >/dev/null 2>&1
}

publish_record() {
  local outcome=$1 reason=$2 record=$3 tmp
  reason_pair_valid "$outcome" "$reason" || die "invalid outcome and reason combination"
  tmp=$(mktemp "$OUTCOMES/.${REQUEST_ID}.tmp.XXXXXX") \
    || die "cannot stage the outcome record"
  TEMP_RECORD=$tmp
  if ! jq -n \
      --arg schema "$OUTCOME_SCHEMA" \
      --arg request_id "$REQUEST_ID" \
      --arg request_digest "$REQUEST_DIGEST" \
      --arg project "$PROJECT" \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      '{schema:$schema, request_id:$request_id, request_digest:$request_digest,
        project:$project, outcome:$outcome, reason:$reason}' > "$tmp" \
      || ! chmod 600 "$tmp" \
      || ! record_valid "$tmp" \
      || ! mv -f -- "$tmp" "$record"; then
    die "could not publish the outcome record atomically"
  fi
  TEMP_RECORD=
  record_valid "$record" || die "published outcome record failed validation"
}

registry_line() {
  awk -v n="$PROJECT" '$1 == "-" && $2 == n { print; count++ } END { if (count != 1) exit 1 }' \
    "$DATA/projects.md" 2>/dev/null
}

verify_success() {
  local record_line mode_line wanted_yolo destination destination_top destination_abs origin rest description

  [ -f "$DATA/projects.md" ] && [ ! -L "$DATA/projects.md" ] \
    || die "success is unproven: the project registry is unavailable"
  record_line=$(registry_line) \
    || die "success is unproven: the registry does not contain exactly one matching project"

  wanted_yolo=$AUTONOMOUS_MERGE
  mode_line=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
    "$FM_ROOT/bin/fm-project-mode.sh" --raw "$PROJECT" 2>/dev/null) \
    || die "success is unproven: the registered posture cannot be read"
  [ "$mode_line" = "$POSTURE $wanted_yolo" ] \
    || die "success is unproven: the registered posture does not match the request"

  if [ "$DESCRIPTION_SET" -eq 1 ]; then
    rest=${record_line#* - }
    case "$rest" in
      *' (added '????-??-??')') description=${rest% (added ????-??-??)} ;;
      *) die "success is unproven: the registry description cannot be read" ;;
    esac
    [ "$description" = "$DESCRIPTION" ] \
      || die "success is unproven: the registry description does not match the request"
  fi

  destination="$PROJECTS/$PROJECT"
  [ -d "$destination" ] && [ ! -L "$destination" ] \
    || die "success is unproven: the project destination is unavailable"
  destination_top=$(git -C "$destination" rev-parse --show-toplevel 2>/dev/null) \
    || die "success is unproven: the project destination is not a git repository"
  destination_abs=$(cd "$destination" && pwd -P) \
    || die "success is unproven: the project destination cannot be resolved"
  [ "$destination_top" = "$destination_abs" ] \
    || die "success is unproven: the project destination is not a repository root"

  if [ "$SOURCE_SET" -eq 1 ]; then
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null) \
      || die "success is unproven: the requested origin is not configured"
    [ "$origin" = "$SOURCE_URL" ] \
      || die "success is unproven: the configured origin does not match the request"
  fi

  case "$POSTURE" in
    no-mistakes|no-mistakes-prod-only)
      (cd "$destination" && no-mistakes doctor >/dev/null 2>&1) \
        || die "success is unproven: no-mistakes initialization is not healthy"
      ;;
  esac
}

COMMAND=${1:-}
case "$COMMAND" in
  -h|--help) usage; exit 0 ;;
  digest|begin|finish|inspect|retire) shift ;;
  *) usage >&2; exit 1 ;;
esac

REQUEST_ID=
REQUEST_DIGEST=
PROJECT=
SOURCE_URL=
SOURCE_SET=0
OBSERVED_PATH=
OBSERVED_SET=0
DESCRIPTION=
DESCRIPTION_SET=0
POSTURE=
AUTONOMOUS_MERGE=
OUTCOME=
REASON=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-id) [ "$#" -ge 2 ] || die "missing --request-id value"; REQUEST_ID=$2; shift 2 ;;
    --request-digest) [ "$#" -ge 2 ] || die "missing --request-digest value"; REQUEST_DIGEST=$2; shift 2 ;;
    --project) [ "$#" -ge 2 ] || die "missing --project value"; PROJECT=$2; shift 2 ;;
    --source-url) [ "$#" -ge 2 ] || die "missing --source-url value"; SOURCE_URL=$2; SOURCE_SET=1; shift 2 ;;
    --observed-path) [ "$#" -ge 2 ] || die "missing --observed-path value"; OBSERVED_PATH=$2; OBSERVED_SET=1; shift 2 ;;
    --description) [ "$#" -ge 2 ] || die "missing --description value"; DESCRIPTION=$2; DESCRIPTION_SET=1; shift 2 ;;
    --posture) [ "$#" -ge 2 ] || die "missing --posture value"; POSTURE=$2; shift 2 ;;
    --autonomous-merge) [ "$#" -ge 2 ] || die "missing --autonomous-merge value"; AUTONOMOUS_MERGE=$2; shift 2 ;;
    --outcome) [ "$#" -ge 2 ] || die "missing --outcome value"; OUTCOME=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || die "missing --reason value"; REASON=$2; shift 2 ;;
    *) die "unknown argument" ;;
  esac
done

need jq
TEMP_RECORD=
LOCK_PATH=
cleanup() {
  local status=$?
  [ -z "$TEMP_RECORD" ] || rm -f -- "$TEMP_RECORD"
  [ -z "$LOCK_PATH" ] || fm_lock_release "$LOCK_PATH"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$COMMAND" in
  digest)
    [ -z "$REQUEST_ID$REQUEST_DIGEST$OUTCOME$REASON" ] \
      || die "digest accepts request options only"
    validate_request
    compute_digest
    ;;

  begin|finish)
    valid_request_id "$REQUEST_ID" || die "request ID must be 32 lowercase hexadecimal characters"
    valid_digest "$REQUEST_DIGEST" || die "request digest must be 64 lowercase hexadecimal characters"
    validate_request
    ACTUAL_DIGEST=$(compute_digest)
    [ "$ACTUAL_DIGEST" = "$REQUEST_DIGEST" ] \
      || die "request digest does not match the supplied registration"
    [ "$REQUEST_ID" = "${REQUEST_DIGEST:0:32}" ] \
      || die "request ID must be the first 128 bits of the request digest"

    if [ "$COMMAND" = begin ]; then
      [ -z "$OUTCOME$REASON" ] || die "begin does not accept an outcome"
    else
      [ -n "$OUTCOME" ] || die "finish requires --outcome"
      case "$OUTCOME" in
        success) [ -z "$REASON" ] || die "success does not accept --reason"; REASON=registered ;;
        authentication-failure)
          [ -z "$REASON" ] || die "authentication-failure does not accept --reason"
          REASON=authentication-required
          ;;
        rejected)
          case "$REASON" in destination-conflict|secondmate-owned|policy-rejected) ;;
            *) die "rejected requires --reason destination-conflict, secondmate-owned, or policy-rejected" ;;
          esac
          ;;
        indeterminate)
          [ -z "$REASON" ] || die "indeterminate does not accept --reason"
          REASON=completion-unproven
          ;;
        *) die "finish outcome must be success, authentication-failure, rejected, or indeterminate" ;;
      esac
    fi

    ensure_outcomes_dir
    load_lock_lib
    RECORD="$OUTCOMES/$REQUEST_ID.json"
    LOCK_PATH="$OUTCOMES/.lock-$REQUEST_ID"
    fm_lock_acquire_wait "$LOCK_PATH" || die "cannot lock the request outcome"

    if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
      record_valid "$RECORD" || die "existing outcome record is unsafe or malformed"
      record_binding_matches "$RECORD" || die "request ID is already bound to another registration"
      EXISTING_OUTCOME=$(jq -r '.outcome' "$RECORD")
      EXISTING_REASON=$(jq -r '.reason' "$RECORD")
      if [ "$COMMAND" = begin ]; then
        printf 'existing %s\n' "$EXISTING_OUTCOME"
        exit 0
      fi
      if [ "$EXISTING_OUTCOME" = "$OUTCOME" ] && [ "$EXISTING_REASON" = "$REASON" ]; then
        printf 'existing %s\n' "$EXISTING_OUTCOME"
        exit 0
      fi
      case "$EXISTING_OUTCOME" in
        success|authentication-failure|rejected)
          die "settled outcome is immutable"
          ;;
        pending|indeterminate) ;;
        *) die "existing outcome record is malformed" ;;
      esac
    elif [ "$COMMAND" = finish ]; then
      die "cannot finish a request that has no pending record"
    fi

    if [ "$COMMAND" = begin ]; then
      publish_record pending awaiting-firstmate "$RECORD"
      printf 'created\n'
    else
      [ "$OUTCOME" != success ] || verify_success
      publish_record "$OUTCOME" "$REASON" "$RECORD"
      printf 'recorded %s\n' "$OUTCOME"
    fi
    ;;

  inspect|retire)
    valid_request_id "$REQUEST_ID" || die "request ID must be 32 lowercase hexadecimal characters"
    valid_digest "$REQUEST_DIGEST" || die "request digest must be 64 lowercase hexadecimal characters"
    [ "$REQUEST_ID" = "${REQUEST_DIGEST:0:32}" ] \
      || die "request ID must be the first 128 bits of the request digest"
    [ -z "$PROJECT$SOURCE_URL$OBSERVED_PATH$DESCRIPTION$POSTURE$AUTONOMOUS_MERGE$OUTCOME$REASON" ] \
      && [ "$SOURCE_SET" -eq 0 ] && [ "$OBSERVED_SET" -eq 0 ] \
      && [ "$DESCRIPTION_SET" -eq 0 ] \
      || die "$COMMAND accepts request identity only"
    require_outcomes_dir || {
      status=$?
      [ "$status" -eq 3 ] && exit 3
      exit "$status"
    }
    RECORD="$OUTCOMES/$REQUEST_ID.json"
    if [ "$COMMAND" = inspect ]; then
      [ -e "$RECORD" ] || [ -L "$RECORD" ] || exit 3
      record_valid "$RECORD" || die "outcome record is unsafe or malformed"
      inspect_binding_matches "$RECORD" || die "outcome record does not match the requested identity"
      jq -c . "$RECORD"
      exit 0
    fi

    load_lock_lib
    LOCK_PATH="$OUTCOMES/.lock-$REQUEST_ID"
    fm_lock_acquire_wait "$LOCK_PATH" || die "cannot lock the request outcome"
    [ -e "$RECORD" ] || [ -L "$RECORD" ] || { printf 'absent\n'; exit 0; }
    record_valid "$RECORD" || die "outcome record is unsafe or malformed"
    inspect_binding_matches "$RECORD" || die "outcome record does not match the requested identity"
    EXISTING_OUTCOME=$(jq -r '.outcome' "$RECORD")
    case "$EXISTING_OUTCOME" in
      pending|indeterminate) die "unsettled outcome cannot be retired" ;;
      success|authentication-failure|rejected) ;;
      *) die "outcome record is malformed" ;;
    esac
    rm -f -- "$RECORD" || die "could not retire the outcome record"
    [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die "outcome record retirement is unproven"
    printf 'retired\n'
    ;;
esac
