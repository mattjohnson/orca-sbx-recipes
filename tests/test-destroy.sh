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

# last workspace (main worktree only) → VM + host dir removed
: > "$SBX_LOG"; export STUB_WORKTREES=1
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy rc 2"; FAILURES=$((FAILURES+1)); }
assert_contains "$(cat "$SBX_LOG")" "rm -f orca-p-abc123def456" "sbx rm called"
[ ! -d "$HOME/.orca-sbx/orca-p-abc123def456" ] || { echo "FAIL host dir kept"; FAILURES=$((FAILURES+1)); }

# sandbox already gone → still exit 0
# shellcheck disable=SC2090 # JSON variable expansion intended at runtime
export STUB_LS_JSON='{"sandboxes":[]}'
printf '%s' "$PAYLOAD" | run_lifecycle destroy 2>/dev/null || { echo "FAIL destroy-gone rc"; FAILURES=$((FAILURES+1)); }

finish
