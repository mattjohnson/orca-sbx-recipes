#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
export ORCA_PROJECT_ID="proj-123"
PAYLOAD='{"schemaVersion":1,"mode":"destroy","recipeResult":{"userData":{"sandboxName":"orca-p-abc123def456"}}}'
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"

# other worktrees remain (main + 2 linked) → VM kept
# shellcheck disable=SC2089 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456"}]}' STUB_WORKTREES=3
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc"; FAILURES=$((FAILURES+1)); }
case "$(cat "$SBX_LOG")" in *"rm -f"*) echo "FAIL removed VM with worktrees left"; FAILURES=$((FAILURES+1));; esac
[ -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir removed early"; FAILURES=$((FAILURES+1)); }

# last workspace (main worktree only) → VM + host dir removed; keepalive stopped
: > "$SBX_LOG"; export STUB_WORKTREES=1
# a genuine keepalive session, so destroy's liveness check recognises it as
# ours: the stub records its own pid in the hold file once it is running under
# the keepalive argv, which is what identifies the session. Bounded hold, so a
# failure here can't leave a holder behind. The subshell keeps job-control
# "Terminated: 15" noise out of this script's output.
export STUB_KEEPALIVE_HOLD="$TESTTMP/keepalive.pids" STUB_KEEPALIVE_SECS=30
(nohup sbx exec orca-p-abc123def456 -- sleep 2147483647 >/dev/null 2>&1 &) 2>/dev/null
_tries=30
while [ "$_tries" -gt 0 ] && [ ! -s "$STUB_KEEPALIVE_HOLD" ]; do sleep 0.1; _tries=$((_tries - 1)); done
KEEPALIVE_PID="$(cat "$STUB_KEEPALIVE_HOLD" 2>/dev/null)"
[ -n "$KEEPALIVE_PID" ] || { echo "FAIL keepalive fixture never started"; FAILURES=$((FAILURES+1)); }
printf '%s' "$KEEPALIVE_PID" > "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid"
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc 2"; FAILURES=$((FAILURES+1)); }
assert_contains "$(cat "$SBX_LOG")" "rm -f orca-p-abc123def456" "sbx rm called"
[ ! -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir kept"; FAILURES=$((FAILURES+1)); }
[ ! -f "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid" ] || { echo "FAIL keepalive pidfile kept"; FAILURES=$((FAILURES+1)); }
wait_pid_gone "$KEEPALIVE_PID" 30 "keepalive process stopped"

# sandbox already gone → still exit 0, and a stale/bogus keepalive pidfile is
# removed without erroring (kill on a dead pid is guarded)
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
printf '99999999' > "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid"
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}'
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy-gone rc"; FAILURES=$((FAILURES+1)); }
[ ! -f "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid" ] || { echo "FAIL bogus keepalive pidfile not removed"; FAILURES=$((FAILURES+1)); }

# query failure → fail-safe: keep VM, exit 0
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
: > "$SBX_LOG"
# shellcheck disable=SC2089,SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[{"name":"orca-p-abc123def456"}]}' STUB_WT_LIST_FAIL=1
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy-queryfail rc"; FAILURES=$((FAILURES+1)); }
case "$(cat "$SBX_LOG")" in *"rm -f"*) echo "FAIL removed VM on failed query"; FAILURES=$((FAILURES+1));; esac
[ -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir removed on failed query"; FAILURES=$((FAILURES+1)); }
unset STUB_WT_LIST_FAIL

# `sbx ls --json` itself fails (daemon down/logged out) → fail-open: keep the
# VM *and* the keypair/hostkeys, don't take the "already gone" branch, exit 0
: > "$HOME/.orca-sbx/orca-p-abc123def456/id_ed25519"
: > "$SBX_LOG"
export STUB_LS_FAIL=1
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy-lsfail rc"; FAILURES=$((FAILURES+1)); }
case "$(cat "$SBX_LOG")" in *"rm -f"*) echo "FAIL removed VM when ls --json itself failed"; FAILURES=$((FAILURES+1));; esac
[ -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir removed when ls --json itself failed"; FAILURES=$((FAILURES+1)); }
[ -f "$HOME/.orca-sbx/orca-p-abc123def456/id_ed25519" ] || { echo "FAIL keypair deleted while VM still lives"; FAILURES=$((FAILURES+1)); }
unset STUB_LS_FAIL

# sbx CLI gone from the host entirely (uninstalled between create and delete) →
# nothing to destroy, exit 0, and the host-side workroot left for the user.
# PATH is reset at the seam between preamble and script, not around the whole
# run: the preamble appends the dirs a real sbx install lives in, so pruning
# PATH from outside would not hide it (see test-common.sh's sha256sum fallback).
mkdir -p "$HOME/.orca-sbx/orca-p-abc123def456"
printf '%s' "$PAYLOAD" | sh -c "$(cat scripts/lifecycle/common.sh)
PATH=\"$(no_sbx_bin)\"
$(cat scripts/lifecycle/destroy.sh)" lifecycle 2>"$TESTTMP/err"
rc=$?
assert_eq "$rc" "0" "destroy exit code with sbx missing"
assert_contains "$(cat "$TESTTMP/err")" "sbx CLI missing" "destroy sbx-missing message"
[ -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir removed with sbx missing"; FAILURES=$((FAILURES+1)); }

finish
