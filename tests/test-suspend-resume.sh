#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123"
PAYLOAD='{"schemaVersion":1,"mode":"resume","recipeResult":{"userData":{"sandboxName":"orca-p-abc123def456"}}}'
expected_port=$((30000 + 0xabc1 % 10000))

# suspend: no-op, exit 0, empty stdout
out="$(printf '%s' "$PAYLOAD" | run_lifecycle suspend 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "suspend exit code"
assert_eq "$out" "" "suspend stdout empty"

# resume: starts named sandbox from payload, re-ensures sshd, and re-emits JSON
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
: > "$HOME/.orca-sbx/orca-p-abc123def456/id_ed25519"
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456","status":"stopped"}]}'
out="$(printf '%s' "$PAYLOAD" | run_lifecycle resume 2>/dev/null)"
log="$(cat "$SBX_LOG")"
assert_contains "$log" "exec orca-p-abc123def456 -- true" "exec auto-start called"
assert_contains "$log" "pgrep -x sshd" "sshd ensure called"
wait_for_log "sleep 2147483647" 30 "keepalive started" || true
[ -f "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid" ] || { echo "FAIL keepalive pidfile missing after resume"; FAILURES=$((FAILURES+1)); }
printf '%s' "$out" | jq -e --argjson port "$expected_port" '.userData.sandboxName == "orca-p-abc123def456" and .connection.target.port == $port and .connection.target.label == "Docker Sandbox (abc123def456)"' >/dev/null \
  || { echo "FAIL resume JSON: $out"; FAILURES=$((FAILURES+1)); }

# resume: sandbox is there but will not start → hard fail, no partial result JSON
: > "$SBX_LOG"
export STUB_EXEC_TRUE_FAIL=1
if printf '%s' "$PAYLOAD" | run_lifecycle resume >"$TESTTMP/out" 2>"$TESTTMP/err"; then
  echo "FAIL resume should fail when the sandbox will not start"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "failed to start" "resume start-failure message"
assert_eq "$(cat "$TESTTMP/out")" "" "resume emits no JSON when the sandbox will not start"
case "$(cat "$SBX_LOG")" in *"pgrep -x sshd"*) echo "FAIL resume kept going past a failed start"; FAILURES=$((FAILURES+1));; esac
unset STUB_EXEC_TRUE_FAIL

# resume: sandbox gone → non-zero with actionable stderr
: > "$SBX_LOG"
# shellcheck disable=SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}'
if printf '%s' "$PAYLOAD" | run_lifecycle resume >/dev/null 2>"$TESTTMP/err"; then
  echo "FAIL resume should fail when sandbox is gone"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "no longer exists" "resume error message"

finish
