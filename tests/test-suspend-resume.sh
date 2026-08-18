#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123"
PAYLOAD='{"schemaVersion":1,"mode":"resume","recipeResult":{"userData":{"sandboxName":"orca-p-abc123def456"}}}'

# suspend: no-op, exit 0, empty stdout
out="$(printf '%s' "$PAYLOAD" | run_lifecycle suspend 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "suspend exit code"
assert_eq "$out" "" "suspend stdout empty"

# resume: starts named sandbox from payload and re-emits JSON
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456","status":"stopped"}]}'
out="$(printf '%s' "$PAYLOAD" | run_lifecycle resume 2>/dev/null)"
assert_contains "$(cat "$SBX_LOG")" "exec orca-p-abc123def456 -- true" "exec auto-start called"
printf '%s' "$out" | jq -e '.userData.sandboxName == "orca-p-abc123def456"' >/dev/null \
  || { echo "FAIL resume JSON: $out"; FAILURES=$((FAILURES+1)); }

# resume: sandbox gone → non-zero with actionable stderr
: > "$SBX_LOG"
# shellcheck disable=SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}'
if printf '%s' "$PAYLOAD" | run_lifecycle resume >/dev/null 2>"$TESTTMP/err"; then
  echo "FAIL resume should fail when sandbox is gone"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "no longer exists" "resume error message"

finish
