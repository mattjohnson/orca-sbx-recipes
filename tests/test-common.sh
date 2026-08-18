#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"

# name derivation is deterministic and matches the documented scheme
export ORCA_PROJECT_ID="proj-123"
# shellcheck disable=SC2015 # intentional command-fallback idiom
expected="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"
got="$(sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name")"
assert_eq "$got" "$expected" "derived name"

# payload name wins over derivation, and only well-formed names are accepted
got="$(printf '{"userData":{"sandboxName":"orca-p-abc123def456"}}' \
  | sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name \"\$(payload_sandbox_name)\"")"
assert_eq "$got" "orca-p-abc123def456" "payload name"
got="$(printf '{"userData":{"sandboxName":"NOT-A-NAME"}}' \
  | sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name \"\$(payload_sandbox_name)\"")"
assert_eq "$got" "$expected" "malformed payload name falls back to derivation"

# emit_connection_json produces the contract shape from stubbed ssh -G + sbx exec
out="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456")"
printf '%s' "$out" | jq -e '
  .schemaVersion == 1
  and .connection.type == "ssh"
  and (.connection.projectRoot | startswith("/"))
  and .connection.target.configHost == "orca-p-abc123def456.sbx"
  and (.connection.target.port | type == "number")
  and (.connection.target.proxyCommand | endswith("orca-p-abc123def456.sbx"))
  and (.connection.target.proxyCommand | contains("%") | not)
  and (.connection.target | has("identityFile") | not)
  and .userData.sandboxName == "orca-p-abc123def456"' >/dev/null \
  || { echo "FAIL emit_connection_json shape: $out"; FAILURES=$((FAILURES+1)); }

finish
