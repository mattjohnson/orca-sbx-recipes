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
# A PATH with no sbx on it, for the "sbx CLI missing" guards. Pruning the
# caller's PATH is not enough: the preamble appends /opt/homebrew/bin,
# /usr/local/bin and $HOME/.docker/bin, which is where a real install lives —
# so assign this *after* the preamble, the way test-common.sh's sha256sum
# fallback does. It carries the few externals those paths still reach for.
no_sbx_bin() {
  _dir="$TESTTMP/no-sbx"
  if [ ! -d "$_dir" ]; then
    mkdir -p "$_dir"
    for _c in sed head cat rm mkdir; do ln -s "$(command -v "$_c")" "$_dir/$_c"; done
  fi
  printf '%s\n' "$_dir"
}

# A signalled process dies asynchronously: poll rather than race the reaper.
pid_alive() { kill -0 "$1" 2>/dev/null; }
wait_pid_gone() {
  _tries="${2:-30}"
  while [ "$_tries" -gt 0 ]; do
    pid_alive "$1" || return 0
    _tries=$((_tries - 1))
    sleep 0.1
  done
  printf 'FAIL %s: pid %s still running\n' "${3:-wait_pid_gone}" "$1"
  FAILURES=$((FAILURES + 1))
  return 1
}
