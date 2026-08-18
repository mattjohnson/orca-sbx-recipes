# shellcheck shell=sh
set -u
cd "$(dirname "$0")/.." || exit 1
TESTTMP="$(mktemp -d)"; trap 'rm -rf "$TESTTMP"' EXIT
export HOME="$TESTTMP/home"; mkdir -p "$HOME"
export SBX_LOG="$TESTTMP/sbx.log"; : > "$SBX_LOG"
PATH="$(pwd)/tests/stubs:$PATH"; export PATH
FAILURES=0
lifecycle_cmd() { cat scripts/lifecycle/common.sh "scripts/lifecycle/$1.sh"; }
run_lifecycle() { _n="$1"; shift; sh -c "$(lifecycle_cmd "$_n")" lifecycle "$@"; }
assert_eq() { [ "$1" = "$2" ] || { printf 'FAIL %s: expected [%s] got [%s]\n' "${3:-eq}" "$2" "$1"; FAILURES=$((FAILURES+1)); }; }
assert_contains() { case "$1" in *"$2"*) ;; *) printf 'FAIL %s: [%s] not found\n' "${3:-contains}" "$2"; FAILURES=$((FAILURES+1)); esac; }
finish() { if [ "$FAILURES" -eq 0 ]; then echo OK; else echo "$FAILURES failure(s)"; exit 1; fi; }
