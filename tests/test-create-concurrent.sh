#!/bin/sh
# Concurrent create.sh runs for the same project (issue #4): the per-project
# lock must serialize them — the loser waits with an explanation, reuses the
# winner's sandbox, and never dies on sbx's name-uniqueness error or clobbers
# the keepalive pidfile.
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123" ORCA_REPO_PATH="/tmp/whatever"
# shellcheck disable=SC2015 # intentional command-fallback idiom
NAME="orca-p-$(printf '%s' "proj-123" | { command -v shasum >/dev/null 2>&1 && shasum -a 256 || sha256sum; } | cut -c1-12)"

# Held keepalive sleeps must die with the test, whatever the outcome.
export STUB_KEEPALIVE_HOLD="$TESTTMP/keepalive.pids"
cleanup_keepalives() {
  if [ -f "$STUB_KEEPALIVE_HOLD" ]; then
    while IFS= read -r _p; do kill "$_p" 2>/dev/null || true; done < "$STUB_KEEPALIVE_HOLD"
  fi
  return 0
}
trap 'cleanup_keepalives; rm -rf "$TESTTMP"' EXIT

# two overlapping creates: stateful stub mirrors the daemon's name uniqueness;
# the 1s create delay guarantees both are in flight at once
export STUB_STATE="$TESTTMP/sbx.state" STUB_CREATE_DELAY=1
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}' STUB_HAS_CLONE=1
run_lifecycle create >"$TESTTMP/a.out" 2>"$TESTTMP/a.err" &
A=$!
# launch B only once A holds the lock, so B provably arrives mid-create
# (A then sits in the 1s STUB_CREATE_DELAY) rather than trusting sleep math
_tries=50
while [ "$_tries" -gt 0 ] && [ ! -d "$HOME/.orca-sbx/$NAME.lock" ]; do sleep 0.1; _tries=$((_tries - 1)); done
run_lifecycle create >"$TESTTMP/b.out" 2>"$TESTTMP/b.err" &
B=$!
wait "$A"; a_rc=$?
wait "$B"; b_rc=$?
err_all="$(cat "$TESTTMP/a.err" "$TESTTMP/b.err")"

assert_eq "$a_rc" "0" "first create exits 0"
assert_eq "$b_rc" "0" "second create exits 0"
for o in a.out b.out; do
  jq -e ".userData.sandboxName == \"$NAME\"" < "$TESTTMP/$o" >/dev/null 2>&1 \
    || { printf 'FAIL %s JSON: [%s]\n' "$o" "$(cat "$TESTTMP/$o")"; FAILURES=$((FAILURES+1)); }
done
assert_eq "$(grep -c "create --name $NAME" "$SBX_LOG")" "1" "sandbox created exactly once"
assert_contains "$err_all" "waiting" "loser explains it is waiting on the concurrent operation"
case "$err_all" in *"sandbox create failed"*)
  echo "FAIL loser died on raw sbx create failure"; FAILURES=$((FAILURES+1));; esac

# keepalive: exactly one session, tracked by a pidfile that points at it
_tries=30
while [ "$_tries" -gt 0 ] && [ ! -s "$STUB_KEEPALIVE_HOLD" ]; do sleep 0.1; _tries=$((_tries - 1)); done
sleep 0.3 # settle: a straggler second keepalive must land before the count
assert_eq "$(wc -l < "$STUB_KEEPALIVE_HOLD" | tr -d ' ')" "1" "exactly one keepalive session"
assert_eq "$(cat "$HOME/.orca-sbx/$NAME/keepalive.pid" 2>/dev/null)" "$(cat "$STUB_KEEPALIVE_HOLD")" "pidfile tracks the surviving keepalive"

# stale lock from a crashed run (holder pid gone): broken automatically, with a message
: > "$SBX_LOG"
unset STUB_STATE STUB_CREATE_DELAY
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON="{\"sandboxes\":[{\"name\":\"$NAME\",\"status\":\"running\"}]}" STUB_HAS_CLONE=0
mkdir -p "$HOME/.orca-sbx/$NAME.lock"
printf '%s' "99999999" > "$HOME/.orca-sbx/$NAME.lock/pid"
out_stale="$(run_lifecycle create 2>"$TESTTMP/stale.err")"
stale_rc=$?
assert_eq "$stale_rc" "0" "create succeeds after breaking the stale lock"
assert_contains "$(cat "$TESTTMP/stale.err")" "stale" "stale lock break explains itself"
printf '%s' "$out_stale" | jq -e '.connection.type == "ssh"' >/dev/null 2>&1 \
  || { echo "FAIL stale-lock JSON: [$out_stale]"; FAILURES=$((FAILURES+1)); }

# lock held by a live process: waiter announces the wait, then times out with guidance
: > "$SBX_LOG"
mkdir -p "$HOME/.orca-sbx/$NAME.lock"
printf '%s' "$$" > "$HOME/.orca-sbx/$NAME.lock/pid"
(export ORCA_SBX_LOCK_TIMEOUT=2; run_lifecycle create >"$TESTTMP/to.out" 2>"$TESTTMP/to.err")
to_rc=$?
to_err="$(cat "$TESTTMP/to.err")"
assert_eq "$to_rc" "1" "create fails when the lock stays held"
assert_contains "$to_err" "waiting" "waiter announces the wait"
assert_contains "$to_err" "timed out" "waiter explains the timeout"
rm -rf "$HOME/.orca-sbx/$NAME.lock"

finish
