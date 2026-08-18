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
# subshell keeps the backgrounded sleep out of this script's own job table,
# so its later kill doesn't print job-control "Terminated: 15 sleep 30" noise
(sleep 30 & echo $! > "$TESTTMP/keepalive.pid") 2>/dev/null
KEEPALIVE_PID="$(cat "$TESTTMP/keepalive.pid")"
printf '%s' "$KEEPALIVE_PID" > "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid"
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc 2"; FAILURES=$((FAILURES+1)); }
assert_contains "$(cat "$SBX_LOG")" "rm -f orca-p-abc123def456" "sbx rm called"
[ ! -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir kept"; FAILURES=$((FAILURES+1)); }
[ ! -f "$HOME/.orca-sbx/orca-p-abc123def456/keepalive.pid" ] || { echo "FAIL keepalive pidfile kept"; FAILURES=$((FAILURES+1)); }
if kill -0 "$KEEPALIVE_PID" 2>/dev/null; then echo "FAIL keepalive process not stopped"; FAILURES=$((FAILURES+1)); fi

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

finish
