# orca-sbx-recipes shared preamble — inlined ahead of every lifecycle script.
# POSIX sh. stdout is reserved for the recipe result JSON; log to stderr.
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

sandbox_name() {
  if [ -n "${1:-}" ]; then printf '%s\n' "$1"; return; fi
  printf 'orca-p-%s\n' "$(printf '%s' "$ORCA_PROJECT_ID" | hash_cmd | cut -c1-12)"
}

sandbox_exists() {
  sbx ls --json 2>/dev/null | grep -Fq "\"$1\""
}

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# $1=sandbox name, $2=ssh -G key → effective client config value
ssh_cfg() {
  ssh -G "$1.sbx" 2>/dev/null | awk -v k="$2" '$1==k { sub(/^[^ ]+ /, ""); print; exit }'
}

emit_connection_json() {
  _name="$1"
  _host="$(ssh_cfg "$_name" hostname)"; _port="$(ssh_cfg "$_name" port)"
  _user="$(ssh_cfg "$_name" user)"; _idfile="$(ssh_cfg "$_name" identityfile)"
  _proxy="$(ssh_cfg "$_name" proxycommand)"
  { [ -n "$_host" ] && [ -n "$_port" ]; } \
    || fail "could not resolve SSH config for $_name.sbx — did 'sbx setup ssh' run?"
  case "$_port" in *[!0-9]*) fail "resolved SSH port '$_port' is not numeric" ;; esac
  # Orca expands only %h/%p in proxy commands, never %n (spike finding):
  # pre-expand every token so the emitted command contains no % at all.
  _proxy="$(printf '%s' "$_proxy" | sed "s/%[nh]/$_name.sbx/g")"
  # shellcheck disable=SC2016 # $HOME must expand inside the sandbox, not locally
  _rhome="$(sbx exec "$_name" -- sh -c 'printf %s "$HOME"')"
  [ -n "$_rhome" ] || fail "could not resolve \$HOME inside sandbox $_name"
  _extra=""
  # sbx auth rides the proxy tunnel: identityfile resolves to /dev/null — omit
  # it entirely (Orca must not try to load /dev/null as a private key).
  if [ -n "$_idfile" ] && [ "$_idfile" != "/dev/null" ]; then
    # shellcheck disable=SC2088 # matching a literal leading ~/ from ssh -G output
    case "$_idfile" in "~/"*) _idfile="$HOME/${_idfile#\~/}" ;; esac
    _extra="$_extra,\"identityFile\":\"$(printf '%s' "$_idfile" | json_escape)\",\"identitiesOnly\":true"
  fi
  { [ -n "$_proxy" ] && [ "$_proxy" != "none" ]; } \
    && _extra="$_extra,\"proxyCommand\":\"$(printf '%s' "$_proxy" | json_escape)\""
  printf '{"schemaVersion":1,"connection":{"type":"ssh","projectRoot":"%s/project","target":{"label":"Docker Sandbox","configHost":"%s.sbx","host":"%s","port":%s,"username":"%s"%s}},"userData":{"sandboxName":"%s"}}\n' \
    "$_rhome" "$_name" "$_host" "$_port" "$_user" "$_extra" "$_name"
}
