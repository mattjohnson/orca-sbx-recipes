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

ensure_port_published() {
  _p="$(project_host_port "$1")"
  sbx ports "$1" 2>/dev/null | awk -v p="$_p" '$1=="127.0.0.1" && $2==p && $3==2222 { found=1 } END { exit !found }' \
    || sbx ports "$1" --publish "$_p:2222" 1>&2 \
    || fail "could not publish sandbox SSH port $_p"
  printf '%s\n' "$_p"
}

# The sbx daemon auto-stops sandboxes with no daemon-visible activity; a
# direct-TCP session through a published port is invisible to it. Hold one
# long-lived exec session per project as a keepalive.
ensure_keepalive() {
  _pidfile="$HOME/.orca-sbx/$1/keepalive.pid"
  if [ -f "$_pidfile" ] && kill -0 "$(cat "$_pidfile")" 2>/dev/null; then
    return 0
  fi
  nohup sbx exec "$1" -- sleep 2147483647 >/dev/null 2>&1 &
  printf '%s' "$!" > "$_pidfile"
}

stop_keepalive() {
  _pidfile="$HOME/.orca-sbx/$1/keepalive.pid"
  if [ -f "$_pidfile" ]; then
    kill "$(cat "$_pidfile")" 2>/dev/null || true
    rm -f "$_pidfile"
  fi
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
  printf '{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"%s/project","target":{"label":"Docker Sandbox","host":"127.0.0.1","port":%s,"username":"%s","identityFile":"%s","identitiesOnly":true}},"userData":{"sandboxName":"%s"}}\n' \
    "$_rhome" "$_port" "$_user" "$(printf '%s' "$_idfile" | json_escape)" "$_name"
}
