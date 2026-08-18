#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123" ORCA_REPO_PATH="/tmp/whatever"
# shellcheck disable=SC2015 # intentional command-fallback idiom
NAME="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"
# same derivation as project_host_port: 30000 + first 4 hex chars of the hash part
PORT=$((30000 + 0x$(printf '%s' "${NAME#orca-p-}" | cut -c1-4) % 10000))

# fresh project: creates sandbox, installs toolchain+sshd, installs key, publishes port, clones, emits JSON
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}' STUB_HAS_CLONE=1
out="$(run_lifecycle create 2>"$TESTTMP/err")"
log="$(cat "$SBX_LOG")"
assert_contains "$log" "create --name $NAME" "sbx create called"
assert_contains "$log" "git clone -- https://example.com/repo.git /home/agent/project" "clone called"
assert_contains "$log" "command -v g++" "toolchain+sshd ensure called"
assert_contains "$log" "authorized_keys" "ssh key installed"
assert_contains "$log" "--publish $PORT:2222" "port published"
assert_contains "$log" "git config --global user.name Test User" "git identity mirrored"
printf '%s' "$out" | jq -e ".userData.sandboxName == \"$NAME\"" >/dev/null || { echo "FAIL create JSON: $out"; FAILURES=$((FAILURES+1)); }
printf '%s' "$out" | jq -e '.connection.target.host == "127.0.0.1"' >/dev/null || { echo "FAIL create JSON host: $out"; FAILURES=$((FAILURES+1)); }
[ -d "$HOME/.orca-sbx/$NAME/workspace" ] || { echo "FAIL workspace dir missing"; FAILURES=$((FAILURES+1)); }
[ -f "$HOME/.orca-sbx/$NAME/id_ed25519" ] || { echo "FAIL identity file missing"; FAILURES=$((FAILURES+1)); }
[ -f "$HOME/.orca-sbx/$NAME/hostkeys/ssh_host_ed25519_key" ] || { echo "FAIL host key not persisted"; FAILURES=$((FAILURES+1)); }
assert_contains "$(cat "$HOME/.orca-sbx/$NAME/hostkeys/ssh_host_ed25519_key" 2>/dev/null)" "FAKE-HOST-KEY" "host key content saved"
assert_contains "$log" ".local/bin" "PATH fixed up in sandbox shell profile"
wait_for_log "exec $NAME -- sleep" 30 "keepalive session started" || true
[ -f "$HOME/.orca-sbx/$NAME/keepalive.pid" ] || { echo "FAIL keepalive pidfile missing"; FAILURES=$((FAILURES+1)); }

# stdout purity: the only stdout line is the JSON object
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "single-line stdout"

# reuse: sandbox exists + clone exists + port already published → no create, no clone, no re-publish, still emits JSON
: > "$SBX_LOG"
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON="{\"sandboxes\":[{\"name\":\"$NAME\",\"status\":\"running\"}]}" STUB_HAS_CLONE=0 STUB_PORT_PUBLISHED="$PORT"
out2="$(run_lifecycle create 2>/dev/null)"
log2="$(cat "$SBX_LOG")"
case "$log2" in *"create --name"*) echo "FAIL reused path called create"; FAILURES=$((FAILURES+1));; esac
case "$log2" in *"git clone"*) echo "FAIL reused path called clone"; FAILURES=$((FAILURES+1));; esac
case "$log2" in *"--publish"*) echo "FAIL reused path re-published port"; FAILURES=$((FAILURES+1));; esac
printf '%s' "$out2" | jq -e '.connection.type == "ssh"' >/dev/null || { echo "FAIL reuse JSON: $out2"; FAILURES=$((FAILURES+1)); }

# recreate with persisted hostkeys: sandbox gone but $WORKROOT/hostkeys survives on the
# host → restore path runs (base64 -d), no re-save (no 'sudo cat /etc/ssh')
: > "$SBX_LOG"
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}' STUB_HAS_CLONE=1
out3="$(run_lifecycle create 2>/dev/null)"
log3="$(cat "$SBX_LOG")"
assert_contains "$log3" "base64 -d" "host key restored on recreate"
case "$log3" in *"sudo cat /etc/ssh"*) echo "FAIL recreate path re-saved host key"; FAILURES=$((FAILURES+1));; esac
printf '%s' "$out3" | jq -e '.connection.type == "ssh"' >/dev/null || { echo "FAIL recreate JSON: $out3"; FAILURES=$((FAILURES+1)); }

# ORCA_REPO_URL, when set, is preferred over `git remote get-url origin`
: > "$SBX_LOG"
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}' STUB_HAS_CLONE=1 ORCA_REPO_URL="https://orca-provided.example/repo-url.git"
out4="$(run_lifecycle create 2>/dev/null)"
log4="$(cat "$SBX_LOG")"
assert_contains "$log4" "git clone -- https://orca-provided.example/repo-url.git" "ORCA_REPO_URL preferred over git remote"
case "$log4" in *"example.com/repo.git"*) echo "FAIL fell back to git remote origin despite ORCA_REPO_URL set"; FAILURES=$((FAILURES+1));; esac
unset ORCA_REPO_URL
printf '%s' "$out4" | jq -e '.connection.type == "ssh"' >/dev/null || { echo "FAIL ORCA_REPO_URL JSON: $out4"; FAILURES=$((FAILURES+1)); }

finish
