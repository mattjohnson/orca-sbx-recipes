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

# emit_connection_json produces the v2 direct-TCP shape (no proxy, no configHost)
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
: > "$HOME/.orca-sbx/orca-p-abc123def456/id_ed25519"
expected_port=$((30000 + 0xabc1 % 10000))
out="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456")"
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

# port collision: deterministic port taken → falls back to the next one and emits it
: > "$SBX_LOG"
export STUB_PUBLISH_FAIL_PORTS="$expected_port"
out="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456" 2>/dev/null)"
assert_contains "$(cat "$SBX_LOG")" "--publish $((expected_port + 1)):2222" "fallback port published"
printf '%s' "$out" | jq -e --argjson port "$((expected_port + 1))" '.connection.target.port == $port' >/dev/null \
  || { echo "FAIL fallback port in JSON: $out"; FAILURES=$((FAILURES+1)); }

# every candidate port taken → fails with the range tried and a remedy
fail_ports=""; i=0
while [ "$i" -lt 10 ]; do fail_ports="$fail_ports $((expected_port + i))"; i=$((i+1)); done
export STUB_PUBLISH_FAIL_PORTS="$fail_ports"
if err="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456" 2>&1 >/dev/null)"; then
  echo "FAIL exhausted ports: expected failure, got success"; FAILURES=$((FAILURES+1))
fi
assert_contains "$err" "tried 10 host ports starting at $expected_port" "exhaustion message names range"
assert_contains "$err" "sbx ports" "exhaustion message suggests remedy"
unset STUB_PUBLISH_FAIL_PORTS

# a mapping already published on a fallback port is reused, not re-published
: > "$SBX_LOG"
export STUB_PORT_PUBLISHED="$((expected_port + 3))"
out="$(sh -c "$(cat scripts/lifecycle/common.sh); emit_connection_json orca-p-abc123def456" 2>/dev/null)"
case "$(cat "$SBX_LOG")" in *"--publish"*) echo "FAIL fallback-port reuse re-published"; FAILURES=$((FAILURES+1));; esac
printf '%s' "$out" | jq -e --argjson port "$((expected_port + 3))" '.connection.target.port == $port' >/dev/null \
  || { echo "FAIL reused fallback port in JSON: $out"; FAILURES=$((FAILURES+1)); }
unset STUB_PORT_PUBLISHED

finish
