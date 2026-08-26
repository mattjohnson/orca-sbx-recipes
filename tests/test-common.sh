#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"

# Helpers are exercised the way the recipe runs them: the shared preamble
# inlined ahead of the call, in a fresh `sh`.
COMMON="$(cat scripts/lifecycle/common.sh)"
run_common() { sh -c "$COMMON
$1" common; }

export ORCA_PROJECT_ID="proj-123"

# fail: prefixed message on stderr, stdout untouched (it carries the result JSON), exit 1
out="$(run_common 'fail "boom happened"' 2>"$TESTTMP/err")"; rc=$?
assert_eq "$rc" "1" "fail exit code"
assert_eq "$out" "" "fail leaves stdout clean"
assert_eq "$(cat "$TESTTMP/err")" "orca-sbx: boom happened" "fail stderr message"

# require_env: ORCA_PROJECT_ID must be set and non-empty
run_common 'require_env' || { echo "FAIL require_env rejected a set ORCA_PROJECT_ID"; FAILURES=$((FAILURES+1)); }
unset ORCA_PROJECT_ID
if run_common 'require_env' 2>"$TESTTMP/err"; then
  echo "FAIL require_env should fail when ORCA_PROJECT_ID is unset"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "ORCA_PROJECT_ID is not set" "require_env names the variable"
export ORCA_PROJECT_ID=""
if run_common 'require_env' 2>/dev/null; then
  echo "FAIL require_env should fail when ORCA_PROJECT_ID is empty"; FAILURES=$((FAILURES+1))
fi
export ORCA_PROJECT_ID="proj-123"

# require_sbx: green when sbx answers `ls --json`
run_common 'require_sbx' || { echo "FAIL require_sbx rejected a working sbx"; FAILURES=$((FAILURES+1)); }

# require_sbx: installed but not ready (daemon down, or logged out) → login hint
export STUB_LS_FAIL=1
if run_common 'require_sbx' 2>"$TESTTMP/err"; then
  echo "FAIL require_sbx should fail when 'sbx ls --json' fails"; FAILURES=$((FAILURES+1))
fi
assert_contains "$(cat "$TESTTMP/err")" "sbx login" "require_sbx not-ready hint"
unset STUB_LS_FAIL

# require_sbx: no sbx on PATH at all → install hint
if can_hide_sbx; then
  (PATH="$NO_SBX_PATH"; export PATH; run_common 'require_sbx') 2>"$TESTTMP/err"
  rc=$?
  assert_eq "$rc" "1" "require_sbx exit code with no sbx on PATH"
  assert_contains "$(cat "$TESTTMP/err")" "sbx CLI not found" "require_sbx missing-CLI hint"
else
  skip "require_sbx missing-CLI: a real sbx on this host shadows the test PATH"
fi

# name derivation is deterministic and matches the documented scheme
# shellcheck disable=SC2015 # intentional command-fallback idiom
expected="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"
got="$(run_common 'sandbox_name')"
assert_eq "$got" "$expected" "derived name"

# payload name wins over derivation, and only well-formed names are accepted
# shellcheck disable=SC2016 # the snippet is expanded by the inner sh, not here
got="$(printf '{"userData":{"sandboxName":"orca-p-abc123def456"}}' \
  | run_common 'sandbox_name "$(payload_sandbox_name)"')"
assert_eq "$got" "orca-p-abc123def456" "payload name"
# shellcheck disable=SC2016 # the snippet is expanded by the inner sh, not here
got="$(printf '{"userData":{"sandboxName":"NOT-A-NAME"}}' \
  | run_common 'sandbox_name "$(payload_sandbox_name)"')"
assert_eq "$got" "$expected" "malformed payload name falls back to derivation"

# sandbox_exists: exact name match against the `sbx ls --json` listing
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456"}]}'
run_common 'sandbox_exists orca-p-abc123def456' \
  || { echo "FAIL sandbox_exists missed a listed sandbox"; FAILURES=$((FAILURES+1)); }
if run_common 'sandbox_exists orca-p-000000000000'; then
  echo "FAIL sandbox_exists matched an unlisted sandbox"; FAILURES=$((FAILURES+1))
fi
# a longer name we are a prefix of is a different sandbox, not a match
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def4567"}]}'
if run_common 'sandbox_exists orca-p-abc123def456'; then
  echo "FAIL sandbox_exists matched a longer name it only prefixes"; FAILURES=$((FAILURES+1))
fi
# an unusable sbx is not evidence the sandbox exists (destroy relies on this:
# it checks `ls --json` separately and keeps the VM rather than assuming gone)
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456"}]}' STUB_LS_FAIL=1
if run_common 'sandbox_exists orca-p-abc123def456'; then
  echo "FAIL sandbox_exists reported existence when 'sbx ls --json' failed"; FAILURES=$((FAILURES+1))
fi
unset STUB_LS_FAIL

# json_escape: backslashes before quotes, so the result survives as a JSON string
assert_eq "$(printf '%s' 'a\b"c' | run_common 'json_escape')" 'a\\b\"c' "json_escape backslash and quote"
assert_eq "$(printf '%s' '/home/agent/.orca-sbx/id_ed25519' | run_common 'json_escape')" \
  '/home/agent/.orca-sbx/id_ed25519' "json_escape leaves ordinary paths alone"
assert_eq "$(printf '{"k":"%s"}' "$(printf '%s' 'a\b"c' | run_common 'json_escape')" | jq -r .k)" \
  'a\b"c' "json_escape round-trips through a JSON parser"

# emit_connection_json produces the v2 direct-TCP shape (no proxy, no configHost)
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
: > "$HOME/.orca-sbx/orca-p-abc123def456/id_ed25519"
expected_port=$((30000 + 0xabc1 % 10000))
out="$(run_common 'emit_connection_json orca-p-abc123def456')"
printf '%s' "$out" | jq -e --argjson port "$expected_port" '
  .schemaVersion == 1
  and .connection.type == "ssh"
  and (.connection.projectRoot | startswith("/"))
  and .connection.target.host == "127.0.0.1"
  and .connection.target.port == $port
  and .connection.target.username == "agent"
  and (.connection.target.identityFile | endswith("id_ed25519"))
  and .connection.target.identitiesOnly == true
  and (.connection.target | has("proxyCommand") | not)
  and (.connection.target | has("configHost") | not)
  and .userData.sandboxName == "orca-p-abc123def456"' >/dev/null \
  || { echo "FAIL emit_connection_json shape: $out"; FAILURES=$((FAILURES+1)); }

finish
