#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123" ORCA_REPO_PATH="/tmp/whatever"
# shellcheck disable=SC2015 # intentional command-fallback idiom
NAME="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"

# fresh project: creates sandbox, sets up ssh, clones, emits JSON
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}' STUB_HAS_CLONE=1
out="$(run_lifecycle create 2>"$TESTTMP/err")"
log="$(cat "$SBX_LOG")"
assert_contains "$log" "create --name $NAME" "sbx create called"
assert_contains "$log" "setup ssh" "ssh setup called"
assert_contains "$log" "git clone https://example.com/repo.git /home/agent/project" "clone called"
assert_contains "$log" "command -v g++" "toolchain ensure called"
assert_contains "$log" "git config --global user.name Test User" "git identity mirrored"
printf '%s' "$out" | jq -e ".userData.sandboxName == \"$NAME\"" >/dev/null || { echo "FAIL create JSON: $out"; FAILURES=$((FAILURES+1)); }
[ -d "$HOME/.orca-sbx/$NAME/workspace" ] || { echo "FAIL workspace dir missing"; FAILURES=$((FAILURES+1)); }

# stdout purity: the only stdout line is the JSON object
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "single-line stdout"

# reuse: sandbox exists + clone exists → no create, no clone, still emits JSON
: > "$SBX_LOG"
# shellcheck disable=SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON="{\"sandboxes\":[{\"name\":\"$NAME\",\"status\":\"running\"}]}" STUB_HAS_CLONE=0
out2="$(run_lifecycle create 2>/dev/null)"
log2="$(cat "$SBX_LOG")"
case "$log2" in *"create --name"*) echo "FAIL reused path called create"; FAILURES=$((FAILURES+1));; esac
case "$log2" in *"git clone"*) echo "FAIL reused path called clone"; FAILURES=$((FAILURES+1));; esac
printf '%s' "$out2" | jq -e '.connection.type == "ssh"' >/dev/null || { echo "FAIL reuse JSON: $out2"; FAILURES=$((FAILURES+1)); }

finish
