# orca-sbx-recipes shared preamble — inlined ahead of every lifecycle script.
# POSIX sh. stdout is reserved for the recipe result JSON; log to stderr.
# shellcheck disable=SC2329 # preamble defines shared helpers, not all used in every script
set -eu
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"

fail() { printf 'orca-sbx: %s\n' "$*" >&2; exit 1; }

require_env() {
  [ -n "${ORCA_PROJECT_ID:-}" ] || fail "ORCA_PROJECT_ID is not set; this command must be run by Orca's recipe runner"
}

require_sbx() {
  command -v sbx >/dev/null 2>&1 \
    || fail "sbx CLI not found. Install Docker Sandboxes (https://docs.docker.com/ai/sandboxes/install/), run 'sbx login', then retry."
  sbx ls --json >/dev/null 2>&1 \
    || fail "sbx is installed but not ready. Run 'sbx login' and 'sbx policy init balanced' in a terminal, then retry."
}

hash_cmd() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

# stdin: Orca lifecycle payload JSON → recorded sandbox name, or empty.
# Names match ^orca-p-[0-9a-f]{12}$ so this sed extraction is unambiguous.
payload_sandbox_name() {
  sed -n 's/.*"sandboxName"[[:space:]]*:[[:space:]]*"\(orca-p-[0-9a-f]\{12\}\)".*/\1/p' | head -n1
}

# shellcheck disable=SC2120 # used in context where argv is optional
sandbox_name() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return; fi
  printf 'orca-p-%s\n' "$(printf '%s' "$ORCA_PROJECT_ID" | hash_cmd | cut -c1-12)"
}

sandbox_exists() {
  sbx ls --json 2>/dev/null | grep -Fq "\"$1\""
}

# Serialize lifecycle runs per project: every guard here is check-then-act
# (sandbox_exists→create, keepalive pidfile, hostkey persistence), so two
# concurrent runs race each other. mkdir is the portable atomic primitive
# (macOS ships no flock). Held for the rest of the run; released on exit.
acquire_project_lock() {
  _lock="$HOME/.orca-sbx/$1.lock"
  mkdir -p "$HOME/.orca-sbx"
  _lock_waited=0
  until mkdir "$_lock" 2>/dev/null; do
    _holder="$(cat "$_lock/pid" 2>/dev/null || true)"
    if [ -n "$_holder" ] && ! kill -0 "$_holder" 2>/dev/null; then
      # Holder crashed without cleanup. Steal under a mutex: two waiters can
      # both observe the dead holder, and an unserialized removal could take
      # out a successor's fresh lock instead of this abandoned one. Re-verify
      # under the mutex — a fresh lock carries a different pid (or none yet).
      if mkdir "$_lock.steal" 2>/dev/null; then
        if [ "$(cat "$_lock/pid" 2>/dev/null || true)" = "$_holder" ]; then
          printf 'orca-sbx: clearing stale lock left by pid %s (process gone)\n' "$_holder" >&2
          rm -rf "$_lock"
        fi
        rm -rf "$_lock.steal"
        continue
      fi
      # another waiter is mid-steal; fall through and retry after a beat
    fi
    if [ "$_lock_waited" -eq 0 ]; then
      printf 'orca-sbx: another lifecycle operation for this project is in progress (pid %s); waiting for it to finish\n' "${_holder:-unknown}" >&2
    fi
    if [ "$_lock_waited" -ge "${ORCA_SBX_LOCK_TIMEOUT:-600}" ]; then
      fail "timed out after ${ORCA_SBX_LOCK_TIMEOUT:-600}s waiting for the concurrent operation (pid ${_holder:-unknown}) — if it is stuck, kill that process (or remove $_lock) and retry"
    fi
    sleep 1
    _lock_waited=$((_lock_waited + 1))
  done
  # Trap before the pid write: if the write fails (set -e exits), the lock must
  # still be released, or the project wedges until the timeout with no pid to
  # steal by. Single-quoted so $_lock expands at exit time; nothing reassigns it.
  trap 'rm -rf "$_lock"' EXIT
  # dash skips EXIT traps on unhandled TERM; route signals through exit.
  trap 'exit 1' INT TERM HUP
  printf '%s' "$$" > "$_lock/pid"
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# Deterministic per-project host port (30000-39999): fixed specs survive VM
# restarts with the same number; ephemeral ones re-bind (spike-validated).
project_host_port() {
  printf '%d\n' $((30000 + 0x$(printf '%s' "$1" | sed 's/^orca-p-//' | cut -c1-4) % 10000))
}

# No systemd in the sbx VM: start sshd directly, idempotently, per lifecycle run.
ensure_sshd() {
  # shellcheck disable=SC2016 # the guard must run inside the sandbox, not locally
  sbx exec "$1" -- sudo sh -c 'pgrep -x sshd >/dev/null 2>&1 || { mkdir -p /run/sshd; /usr/sbin/sshd -p 2222; }' 1>&2 \
    || fail "could not start sshd inside sandbox $1"
}

# Reuses any existing 2222 mapping (a prior run may have landed on a fallback
# port); otherwise publishes the deterministic port, walking forward through
# the 30000-39999 range when a port is taken by a colliding project or an
# unrelated process.
ensure_port_published() {
  _p="$(sbx ports "$1" 2>/dev/null | awk '$1=="127.0.0.1" && $3==2222 { print $2; exit }')"
  if [ -n "$_p" ]; then printf '%s\n' "$_p"; return 0; fi
  _base="$(project_host_port "$1")"
  _try=0
  while [ "$_try" -lt 10 ]; do
    _p=$((30000 + (_base - 30000 + _try) % 10000))
    if sbx ports "$1" --publish "$_p:2222" 1>&2; then
      printf '%s\n' "$_p"
      return 0
    fi
    printf 'orca-sbx: could not publish host port %s for %s\n' "$_p" "$1" >&2
    _try=$((_try + 1))
  done
  fail "could not publish an SSH port for sandbox $1: tried 10 host ports starting at $_base — check what holds them ('sbx ports $1', 'lsof -iTCP -sTCP:LISTEN'), free one, then retry"
}

# The sbx daemon auto-stops sandboxes with no daemon-visible activity; a
# direct-TCP session through a published port is invisible to it. Hold one
# long-lived exec session per project as a keepalive.
KEEPALIVE_SLEEP_SECONDS=2147483647

# A pidfile records only a number, and after a crash or a reboot the OS may have
# recycled that number onto an unrelated process. Print the recorded PID only
# while it still looks like this sandbox's keepalive: a bare `kill -0` would both
# skip a needed respawn and aim stop_keepalive at somebody else's process. An
# unreadable pidfile, a missing `ps`, or an argv we don't recognise all mean "not
# ours" — respawn rather than trust it, and never signal what we can't identify.
keepalive_pid() {
  _kp="$(cat "$HOME/.orca-sbx/$1/keepalive.pid" 2>/dev/null)" || return 1
  case "$_kp" in '' | *[!0-9]*) return 1 ;; esac
  case "$(ps -p "$_kp" -o args= 2>/dev/null)" in
    *"$1"*"sleep $KEEPALIVE_SLEEP_SECONDS"*) printf '%s\n' "$_kp" ;;
    *) return 1 ;;
  esac
}

ensure_keepalive() {
  mkdir -p "$HOME/.orca-sbx/$1"
  keepalive_pid "$1" >/dev/null && return 0
  nohup sbx exec "$1" -- sleep "$KEEPALIVE_SLEEP_SECONDS" >/dev/null 2>&1 &
  printf '%s' "$!" > "$HOME/.orca-sbx/$1/keepalive.pid"
}

stop_keepalive() {
  _kp_stop="$(keepalive_pid "$1")" && kill "$_kp_stop" 2>/dev/null
  rm -f "$HOME/.orca-sbx/$1/keepalive.pid"
}

emit_connection_json() {
  _name="$1"
  _port="$(ensure_port_published "$_name")"
  # shellcheck disable=SC2016 # $HOME must expand inside the sandbox, not locally
  _rhome="$(sbx exec "$_name" -- sh -c 'printf %s "$HOME"')"
  [ -n "$_rhome" ] || fail "could not resolve \$HOME inside sandbox $_name"
  _user="$(sbx exec "$_name" -- whoami)"
  [ -n "$_user" ] || fail "could not resolve user inside sandbox $_name"
  _idfile="$HOME/.orca-sbx/$_name/id_ed25519"
  [ -f "$_idfile" ] || fail "missing SSH key $_idfile — delete and recreate the workspace"
  printf '{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"%s/project","target":{"label":"Docker Sandbox (%s)","host":"127.0.0.1","port":%s,"username":"%s","identityFile":"%s","identitiesOnly":true}},"userData":{"sandboxName":"%s"}}\n' \
    "$_rhome" "${_name#orca-p-}" "$_port" "$_user" "$(printf '%s' "$_idfile" | json_escape)" "$_name"
}
