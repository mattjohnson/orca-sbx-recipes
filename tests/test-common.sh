#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"

# name derivation is deterministic and matches the documented scheme
export ORCA_PROJECT_ID="proj-123"
# shellcheck disable=SC2015 # intentional command-fallback idiom
expected="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"
got="$(sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name")"
assert_eq "$got" "$expected" "derived name"

# hash_cmd's sha256sum fallback never runs on CI: both runners ship shasum.
# Force it with a PATH that has no shasum on it, plus a recording sha256sum
# shim (macOS ships no sha256sum of its own, so the shim delegates to shasum).
fallback_bin="$TESTTMP/no-shasum"; mkdir -p "$fallback_bin"
fallback_marker="$TESTTMP/sha256sum.called"
ln -s "$(command -v cut)" "$fallback_bin/cut" # sandbox_name's only other external
if command -v sha256sum >/dev/null 2>&1; then
  fallback_impl="$(command -v sha256sum)"
else
  fallback_impl="$(command -v shasum) -a 256"
fi
cat > "$fallback_bin/sha256sum" <<EOF
#!/bin/sh
: > "$fallback_marker"
exec $fallback_impl "\$@"
EOF
chmod +x "$fallback_bin/sha256sum"
# /bin/sh by absolute path: the pruned PATH is also what finds the shell itself.
got="$(env PATH="$fallback_bin" /bin/sh -c "$(cat scripts/lifecycle/common.sh); sandbox_name")"
assert_eq "$got" "$expected" "sha256sum fallback derives the same name"
[ -f "$fallback_marker" ] \
  || { echo "FAIL sha256sum fallback: shasum still reachable (preamble appends /opt/homebrew/bin:/usr/local/bin)"; FAILURES=$((FAILURES+1)); }

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

finish
