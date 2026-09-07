#!/usr/bin/env bash
# tests/fm-project-registration-outcome.test.sh - durable, request-bound project
# registration outcomes for read-only consumers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-project-registration-outcome.sh"
FIXTURE="$ROOT/tests/fixtures/project-registration-outcome.v1.json"
TMP_ROOT=$(fm_test_tmproot fm-project-registration-outcome)

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

make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/projects"
}

digest() {
  "$SCRIPT" digest "$@"
}

request_id() {
  printf '%.32s\n' "$1"
}

run_begin() {
  local home=$1 id=$2 request_digest=$3
  shift 3
  FM_HOME="$home" "$SCRIPT" begin \
    --request-id "$id" --request-digest "$request_digest" "$@"
}

run_finish() {
  local home=$1 id=$2 request_digest=$3
  shift 3
  FM_HOME="$home" "$SCRIPT" finish \
    --request-id "$id" --request-digest "$request_digest" "$@"
}

run_inspect() {
  FM_HOME="$1" "$SCRIPT" inspect --request-id "$2" --request-digest "$3"
}

expect_failure() {
  local label=$1
  shift
  "$@" > "$TMP_ROOT/failure.out" 2> "$TMP_ROOT/failure.err"
  local rc=$?
  [ "$rc" -ne 0 ] || fail "$label succeeded"
}

FIXTURE_ARGS=(
  --project monobox
  --source-url git@github.com:example/monobox.git
  --observed-path /Users/example/firstmate/projects/monobox
  --description 'A small toolbox.'
  --posture no-mistakes-prod-only
  --autonomous-merge off
)
FIXTURE_DIGEST=$(digest "${FIXTURE_ARGS[@]}") \
  || fail "could not compute the fixture request digest"
[ "$FIXTURE_DIGEST" = 6bd49c90b0d7f4f0d0e5118659337df69323bbbf85a9838b6f9811c37d6fdae7 ] \
  || fail "the public request digest changed without a schema version change"
FIXTURE_ID=$(request_id "$FIXTURE_DIGEST")
[ "$FIXTURE_ID" = 6bd49c90b0d7f4f0d0e5118659337df6 ] \
  || fail "request identity is not the first 128 bits of the request digest"
CHANGED_DESCRIPTION_ARGS=(
  --project monobox
  --source-url git@github.com:example/monobox.git
  --observed-path /Users/example/firstmate/projects/monobox
  --description 'A different toolbox.'
  --posture no-mistakes-prod-only
  --autonomous-merge off
)
CHANGED_DESCRIPTION_DIGEST=$(digest "${CHANGED_DESCRIPTION_ARGS[@]}") \
  || fail "changed-description digest failed"
[ "$CHANGED_DESCRIPTION_DIGEST" != "$FIXTURE_DIGEST" ] \
  || fail "description was omitted from the immutable request binding"
[ "$(request_id "$CHANGED_DESCRIPTION_DIGEST")" != "$FIXTURE_ID" ] \
  || fail "description change did not change the request identity"

inert_home="$TMP_ROOT/inert-home"
mkdir "$inert_home"
FM_HOME="$inert_home" "$SCRIPT" digest "${FIXTURE_ARGS[@]}" >/dev/null \
  || fail "digest failed in an otherwise unused home"
FM_HOME="$inert_home" "$SCRIPT" inspect \
  --request-id "$FIXTURE_ID" --request-digest "$FIXTURE_DIGEST" >/dev/null 2>&1
rc=$?
expect_code 3 "$rc" "absent outcome inspect"
assert_absent "$inert_home/state" "read-only commands initialized an unused home"
pass "homes remain untouched until a confirmed request begins"

fixture_home="$TMP_ROOT/fixture-home"
make_home "$fixture_home"
out=$(run_begin "$fixture_home" "$FIXTURE_ID" "$FIXTURE_DIGEST" "${FIXTURE_ARGS[@]}") \
  || fail "fixture request begin failed"
[ "$out" = created ] || fail "new fixture request did not report created: $out"
run_finish "$fixture_home" "$FIXTURE_ID" "$FIXTURE_DIGEST" \
  "${FIXTURE_ARGS[@]}" --outcome authentication-failure >/dev/null \
  || fail "fixture authentication outcome failed"
record="$fixture_home/state/project-registration-outcomes/$FIXTURE_ID.json"
jq -S . "$record" > "$TMP_ROOT/fixture.actual"
jq -S . "$FIXTURE" > "$TMP_ROOT/fixture.expected"
cmp -s "$TMP_ROOT/fixture.actual" "$TMP_ROOT/fixture.expected" \
  || fail "published record does not match the consumer fixture"
inspected=$(run_inspect "$fixture_home" "$FIXTURE_ID" "$FIXTURE_DIGEST") \
  || fail "public inspect rejected the consumer fixture"
printf '%s' "$inspected" | jq -e '
  .schema == "fm-project-registration-outcome.v1"
  and .outcome == "authentication-failure"
  and .reason == "authentication-required"
' >/dev/null || fail "consumer fixture fields are not readable through inspect"
pass "request digest and published record match the executable consumer fixture"

pending_home="$TMP_ROOT/pending-home"
make_home "$pending_home"
PENDING_ARGS=(
  --project scratch
  --observed-path /Users/example/firstmate/projects/scratch
  --description 'Local scratch project.'
  --posture local-only
  --autonomous-merge off
)
PENDING_DIGEST=$(digest "${PENDING_ARGS[@]}") || fail "pending digest failed"
PENDING_ID=$(request_id "$PENDING_DIGEST")
out=$(run_begin "$pending_home" "$PENDING_ID" "$PENDING_DIGEST" "${PENDING_ARGS[@]}") \
  || fail "pending begin failed"
[ "$out" = created ] || fail "pending begin did not create the record"
pending_record="$pending_home/state/project-registration-outcomes/$PENDING_ID.json"
[ "$(path_mode "$pending_home/state/project-registration-outcomes")" = 700 ] \
  || fail "outcome directory is not mode 0700"
[ "$(path_mode "$pending_record")" = 600 ] || fail "outcome record is not mode 0600"
[ "$(path_links "$pending_record")" = 1 ] || fail "outcome record is not single-link"
jq -e '.outcome == "pending" and .reason == "awaiting-firstmate"' "$pending_record" \
  >/dev/null || fail "new request is not honestly pending"
before=$(shasum -a 256 "$pending_record" | awk '{print $1}')
out=$(run_begin "$pending_home" "$PENDING_ID" "$PENDING_DIGEST" "${PENDING_ARGS[@]}") \
  || fail "matching duplicate begin failed"
[ "$out" = 'existing pending' ] \
  || fail "matching duplicate did not withhold mutation authority: $out"
after=$(shasum -a 256 "$pending_record" | awk '{print $1}')
[ "$before" = "$after" ] || fail "matching duplicate rewrote the pending record"
[ "$(find "$pending_home/state/project-registration-outcomes" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] \
  || fail "matching duplicate created another record"
pass "pending publication is private and a matching retry does not authorize duplicate work"

# A reused request ID must not observe or replace another request's outcome.
STALE_ARGS=(--project other --posture local-only --autonomous-merge off)
STALE_DIGEST=$(digest "${STALE_ARGS[@]}") || fail "stale digest failed"
expect_failure "stale request ID reuse" run_begin \
  "$pending_home" "$PENDING_ID" "$STALE_DIGEST" "${STALE_ARGS[@]}"
expect_failure "stale digest inspect" run_inspect \
  "$pending_home" "$PENDING_ID" "$STALE_DIGEST"
[ "$(shasum -a 256 "$pending_record" | awk '{print $1}')" = "$before" ] \
  || fail "stale request changed the original record"
pass "request identity and digest reject stale or replaced requests"

# The record stores only bounded identifiers and enum values, even when the
# transient request contains credential-shaped and secret-shaped text.
secret_home="$TMP_ROOT/secret-home"
make_home "$secret_home"
SECRET_ARGS=(
  --project private-app
  --source-url 'https://user:ghp_supersecret@example.com/private-app.git'
  --observed-path /Users/example/firstmate/projects/private-app
  --description 'token=sk-secret-description'
  --posture no-mistakes-prod-only
  --autonomous-merge off
)
SECRET_DIGEST=$(digest "${SECRET_ARGS[@]}") || fail "secret-bearing digest failed"
SECRET_ID=$(request_id "$SECRET_DIGEST")
run_begin "$secret_home" "$SECRET_ID" "$SECRET_DIGEST" "${SECRET_ARGS[@]}" >/dev/null \
  || fail "secret-bearing begin failed"
secret_record="$secret_home/state/project-registration-outcomes/$SECRET_ID.json"
assert_no_grep 'ghp_supersecret' "$secret_record" "record leaked a credential"
assert_no_grep 'sk-secret-description' "$secret_record" "record leaked request text"
assert_no_grep 'example.com/private-app' "$secret_record" "record leaked the source URL"
pass "durable records exclude credentials, request prose, source URLs, and command output"

# A failed rename must leave the old complete record in place.
atomic_home="$TMP_ROOT/atomic-home"
make_home "$atomic_home"
ATOMIC_ARGS=(--project atomic --posture local-only --autonomous-merge off)
ATOMIC_DIGEST=$(digest "${ATOMIC_ARGS[@]}") || fail "atomic digest failed"
ATOMIC_ID=$(request_id "$ATOMIC_DIGEST")
run_begin "$atomic_home" "$ATOMIC_ID" "$ATOMIC_DIGEST" "${ATOMIC_ARGS[@]}" >/dev/null \
  || fail "atomic begin failed"
atomic_record="$atomic_home/state/project-registration-outcomes/$ATOMIC_ID.json"
atomic_before=$(shasum -a 256 "$atomic_record" | awk '{print $1}')
atomic_fake=$(fm_fakebin "$TMP_ROOT/atomic")
cat > "$atomic_fake/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$atomic_fake/mv"
expect_failure "failed atomic replacement" env PATH="$atomic_fake:$PATH" FM_HOME="$atomic_home" \
  "$SCRIPT" finish --request-id "$ATOMIC_ID" --request-digest "$ATOMIC_DIGEST" \
  "${ATOMIC_ARGS[@]}" --outcome authentication-failure
[ "$(shasum -a 256 "$atomic_record" | awk '{print $1}')" = "$atomic_before" ] \
  || fail "failed replacement damaged the pending record"
run_inspect "$atomic_home" "$ATOMIC_ID" "$ATOMIC_DIGEST" | jq -e '.outcome == "pending"' \
  >/dev/null || fail "failed replacement exposed a partial record"
pass "atomic replacement failure preserves the previous complete record"

# Success is the only outcome the helper proves itself. Each missing operation
# leaves the pending record untouched until the full registration is observable.
success_home="$TMP_ROOT/success-home"
make_home "$success_home"
fm_git_init_commit "$TMP_ROOT/right-source"
git clone --quiet --bare "$TMP_ROOT/right-source" "$TMP_ROOT/right-source.git"
fm_git_init_commit "$TMP_ROOT/wrong-source"
git clone --quiet --bare "$TMP_ROOT/wrong-source" "$TMP_ROOT/wrong-source.git"
SUCCESS_ARGS=(
  --project app
  --source-url "$TMP_ROOT/right-source.git"
  --description 'The app project.'
  --posture no-mistakes-prod-only
  --autonomous-merge off
)
SUCCESS_DIGEST=$(digest "${SUCCESS_ARGS[@]}") || fail "success digest failed"
SUCCESS_ID=$(request_id "$SUCCESS_DIGEST")
run_begin "$success_home" "$SUCCESS_ID" "$SUCCESS_DIGEST" "${SUCCESS_ARGS[@]}" >/dev/null \
  || fail "success begin failed"
success_record="$success_home/state/project-registration-outcomes/$SUCCESS_ID.json"
expect_failure "success without registration" run_finish \
  "$success_home" "$SUCCESS_ID" "$SUCCESS_DIGEST" "${SUCCESS_ARGS[@]}" --outcome success
jq -e '.outcome == "pending"' "$success_record" >/dev/null \
  || fail "unproved success changed the pending record"

printf '%s\n' '- app [no-mistakes-prod-only] - The app project. (added 2026-09-06)' \
  > "$success_home/data/projects.md"
git clone --quiet "$TMP_ROOT/wrong-source.git" "$success_home/projects/app"
doctor_fake=$(fm_fakebin "$TMP_ROOT/doctor")
cat > "$doctor_fake/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit "${FM_TEST_DOCTOR_RC:-0}"
SH
chmod +x "$doctor_fake/no-mistakes"
expect_failure "success with wrong origin" env PATH="$doctor_fake:$PATH" FM_HOME="$success_home" \
  "$SCRIPT" finish --request-id "$SUCCESS_ID" --request-digest "$SUCCESS_DIGEST" \
  "${SUCCESS_ARGS[@]}" --outcome success
rm -rf "$success_home/projects/app"
git clone --quiet "$TMP_ROOT/right-source.git" "$success_home/projects/app"
printf '%s\n' '- app [direct-PR] - The app project. (added 2026-09-06)' \
  > "$success_home/data/projects.md"
expect_failure "success with wrong posture" env PATH="$doctor_fake:$PATH" FM_HOME="$success_home" \
  "$SCRIPT" finish --request-id "$SUCCESS_ID" --request-digest "$SUCCESS_DIGEST" \
  "${SUCCESS_ARGS[@]}" --outcome success
printf '%s\n' '- app [no-mistakes-prod-only] - The app project. (added 2026-09-06)' \
  > "$success_home/data/projects.md"
expect_failure "success with unhealthy initialization" env PATH="$doctor_fake:$PATH" FM_TEST_DOCTOR_RC=1 \
  FM_HOME="$success_home" "$SCRIPT" finish \
  --request-id "$SUCCESS_ID" --request-digest "$SUCCESS_DIGEST" \
  "${SUCCESS_ARGS[@]}" --outcome success
out=$(PATH="$doctor_fake:$PATH" FM_HOME="$success_home" "$SCRIPT" finish \
  --request-id "$SUCCESS_ID" --request-digest "$SUCCESS_DIGEST" \
  "${SUCCESS_ARGS[@]}" --outcome success) || fail "fully observed success was refused"
[ "$out" = 'recorded success' ] || fail "success did not report its publication: $out"
jq -e '.outcome == "success" and .reason == "registered"' "$success_record" \
  >/dev/null || fail "fully observed registration was not recorded as success"
out=$(run_begin "$success_home" "$SUCCESS_ID" "$SUCCESS_DIGEST" "${SUCCESS_ARGS[@]}") \
  || fail "settled duplicate begin failed"
[ "$out" = 'existing success' ] || fail "settled duplicate did not stop replay: $out"
pass "success requires the exact registry, clone, origin, posture, and healthy initialization"

# Known failures and an unknown completion remain distinct, and settled verdicts
# cannot be rewritten by a retry.
outcome_home="$TMP_ROOT/outcome-home"
make_home "$outcome_home"
AUTH_ARGS=(--project auth-outcome --posture local-only --autonomous-merge off)
AUTH_DIGEST=$(digest "${AUTH_ARGS[@]}") || fail "auth outcome digest failed"
AUTH_ID=$(request_id "$AUTH_DIGEST")
run_begin "$outcome_home" "$AUTH_ID" "$AUTH_DIGEST" "${AUTH_ARGS[@]}" >/dev/null \
  || fail "auth begin failed"
run_finish "$outcome_home" "$AUTH_ID" "$AUTH_DIGEST" "${AUTH_ARGS[@]}" \
  --outcome authentication-failure >/dev/null || fail "auth finish failed"
run_inspect "$outcome_home" "$AUTH_ID" "$AUTH_DIGEST" | jq -e \
  '.outcome == "authentication-failure" and .reason == "authentication-required"' \
  >/dev/null || fail "authentication failure was not distinct"
expect_failure "settled authentication rewrite" run_finish \
  "$outcome_home" "$AUTH_ID" "$AUTH_DIGEST" "${AUTH_ARGS[@]}" \
  --outcome rejected --reason policy-rejected

CONFLICT_ARGS=(--project conflict-outcome --posture local-only --autonomous-merge off)
CONFLICT_DIGEST=$(digest "${CONFLICT_ARGS[@]}") || fail "conflict outcome digest failed"
CONFLICT_ID=$(request_id "$CONFLICT_DIGEST")
run_begin "$outcome_home" "$CONFLICT_ID" "$CONFLICT_DIGEST" "${CONFLICT_ARGS[@]}" >/dev/null \
  || fail "conflict begin failed"
run_finish "$outcome_home" "$CONFLICT_ID" "$CONFLICT_DIGEST" "${CONFLICT_ARGS[@]}" \
  --outcome rejected --reason destination-conflict >/dev/null || fail "conflict finish failed"
run_inspect "$outcome_home" "$CONFLICT_ID" "$CONFLICT_DIGEST" | jq -e \
  '.outcome == "rejected" and .reason == "destination-conflict"' \
  >/dev/null || fail "destination conflict was not distinct"

POLICY_ARGS=(--project routed-outcome --posture local-only --autonomous-merge off)
POLICY_DIGEST=$(digest "${POLICY_ARGS[@]}") || fail "routed outcome digest failed"
POLICY_ID=$(request_id "$POLICY_DIGEST")
run_begin "$outcome_home" "$POLICY_ID" "$POLICY_DIGEST" "${POLICY_ARGS[@]}" >/dev/null \
  || fail "policy begin failed"
run_finish "$outcome_home" "$POLICY_ID" "$POLICY_DIGEST" "${POLICY_ARGS[@]}" \
  --outcome rejected --reason secondmate-owned >/dev/null || fail "secondmate rejection failed"
run_inspect "$outcome_home" "$POLICY_ID" "$POLICY_DIGEST" | jq -e \
  '.outcome == "rejected" and .reason == "secondmate-owned"' \
  >/dev/null || fail "secondmate routing rejection was not distinct"

UNKNOWN_ARGS=(--project unknown-outcome --posture local-only --autonomous-merge off)
UNKNOWN_DIGEST=$(digest "${UNKNOWN_ARGS[@]}") || fail "unknown outcome digest failed"
UNKNOWN_ID=$(request_id "$UNKNOWN_DIGEST")
run_begin "$outcome_home" "$UNKNOWN_ID" "$UNKNOWN_DIGEST" "${UNKNOWN_ARGS[@]}" >/dev/null \
  || fail "unknown begin failed"
run_finish "$outcome_home" "$UNKNOWN_ID" "$UNKNOWN_DIGEST" "${UNKNOWN_ARGS[@]}" \
  --outcome indeterminate >/dev/null || fail "indeterminate finish failed"
run_inspect "$outcome_home" "$UNKNOWN_ID" "$UNKNOWN_DIGEST" | jq -e \
  '.outcome == "indeterminate" and .reason == "completion-unproven"' \
  >/dev/null || fail "indeterminate completion was not preserved"
expect_failure "indeterminate retirement" env FM_HOME="$outcome_home" "$SCRIPT" retire \
  --request-id "$UNKNOWN_ID" --request-digest "$UNKNOWN_DIGEST"
pass "authentication, conflict, routing rejection, and indeterminate outcomes remain distinct"

# Explicit Firstmate cleanup is binding-aware and only accepts a settled record.
out=$(FM_HOME="$outcome_home" "$SCRIPT" retire \
  --request-id "$CONFLICT_ID" --request-digest "$CONFLICT_DIGEST") \
  || fail "settled outcome retirement failed"
[ "$out" = retired ] || fail "settled retirement did not report completion: $out"
FM_HOME="$outcome_home" "$SCRIPT" inspect \
  --request-id "$CONFLICT_ID" --request-digest "$CONFLICT_DIGEST" >/dev/null 2>&1
rc=$?
expect_code 3 "$rc" "retired outcome inspect"
pass "only an explicitly bound settled outcome can be retired"

# Malformed options, unsafe paths, and malformed existing records all stop
# before replacing trusted state.
expect_failure "short request ID" run_begin "$pending_home" short "$PENDING_DIGEST" "${PENDING_ARGS[@]}"
expect_failure "uppercase request digest" run_begin "$pending_home" \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "${PENDING_DIGEST^^}" "${PENDING_ARGS[@]}"
expect_failure "traversing project name" digest \
  --project ../escape --posture local-only --autonomous-merge off
expect_failure "relative observed path" digest \
  --project safe --observed-path relative/path --posture local-only --autonomous-merge off
expect_failure "remote posture without source" digest \
  --project safe --posture direct-PR --autonomous-merge off
expect_failure "multi-line description" digest \
  --project safe --description $'one\ntwo' --posture local-only --autonomous-merge off

malformed_home="$TMP_ROOT/malformed-home"
make_home "$malformed_home"
BASE_ARGS=(--project outcomes --posture local-only --autonomous-merge off)
BASE_DIGEST=$(digest "${BASE_ARGS[@]}") || fail "base outcome digest failed"
MALFORMED_ID=$(request_id "$BASE_DIGEST")
run_begin "$malformed_home" "$MALFORMED_ID" "$BASE_DIGEST" "${BASE_ARGS[@]}" >/dev/null \
  || fail "malformed fixture begin failed"
malformed_record="$malformed_home/state/project-registration-outcomes/$MALFORMED_ID.json"
printf '%s\n' '{"schema":"wrong"}' > "$malformed_record"
chmod 600 "$malformed_record"
expect_failure "malformed record inspect" run_inspect \
  "$malformed_home" "$MALFORMED_ID" "$BASE_DIGEST"

symlink_home="$TMP_ROOT/symlink-home"
make_home "$symlink_home"
mkdir "$TMP_ROOT/external-outcomes"
chmod 700 "$TMP_ROOT/external-outcomes"
ln -s "$TMP_ROOT/external-outcomes" "$symlink_home/state/project-registration-outcomes"
SYMLINK_ID=$(request_id "$BASE_DIGEST")
expect_failure "symlink outcome directory" run_begin \
  "$symlink_home" "$SYMLINK_ID" "$BASE_DIGEST" "${BASE_ARGS[@]}"
[ -z "$(find "$TMP_ROOT/external-outcomes" -mindepth 1 -maxdepth 1 -print)" ] \
  || fail "symlink outcome directory received a record"
pass "malformed input, records, and outcome paths are refused without side effects"

echo "ALL TESTS PASSED"
