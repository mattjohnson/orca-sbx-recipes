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
# Polls SBX_LOG for a substring: backgrounded stub invocations (keepalive)
# land asynchronously, so a plain assert races on slow machines.
wait_for_log() {
  _tries="${2:-30}"
  while [ "$_tries" -gt 0 ]; do
    case "$(cat "$SBX_LOG")" in *"$1"*) return 0 ;; esac
    _tries=$((_tries - 1))
    sleep 0.1
  done
  printf 'FAIL %s: [%s] never appeared in log\n' "${3:-wait_for_log}" "$1"
  FAILURES=$((FAILURES + 1))
  return 1
}
