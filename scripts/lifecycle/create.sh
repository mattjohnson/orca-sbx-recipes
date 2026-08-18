# create: reuse-or-create the project sandbox, ensure the clone, emit connection JSON.
require_env
require_sbx
# shellcheck disable=SC2119 # sandbox_name is intentionally called without argv
NAME="$(sandbox_name)"
WORKROOT="$HOME/.orca-sbx/$NAME"
mkdir -p "$WORKROOT/workspace"
chmod 700 "$WORKROOT"

if ! sandbox_exists "$NAME"; then
  printf 'orca-sbx: creating sandbox %s\n' "$NAME" >&2
  # claude agent selects docker/sandbox-templates:claude-code (ships claude + node;
  # node is required by Orca's SSH relay). Exact syntax confirmed by the Task 1 spike.
  sbx create --name "$NAME" claude "$WORKROOT/workspace" 1>&2 \
    || fail "sandbox create failed — see output above"
fi

# Relay needs a C++ toolchain (node-pty source build); direct SSH needs sshd.
# No systemd in the VM: sshd is started by ensure_sshd, not a service.
# The sandbox launches its own background apt-get update on every boot; apt's
# built-in lock wait (apt >= 1.9.11; VM ships 3.2) rides out the collision.
sbx exec "$NAME" -- sh -c 'command -v g++ >/dev/null 2>&1 && test -x /usr/sbin/sshd || { sudo apt-get -o DPkg::Lock::Timeout=300 update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq build-essential openssh-server; }' 1>&2 \
  || fail "could not install build tools/sshd in sandbox (does the sbx network policy allow Ubuntu repos?)"

# Stable host key per project: a recreated VM reuses it, so known_hosts
# entries for 127.0.0.1:<port> never go stale. Other key types are removed
# so clients always negotiate the persisted ed25519 key.
sbx exec "$NAME" -- sudo rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub 1>&2
if [ -f "$WORKROOT/hostkeys/ssh_host_ed25519_key" ]; then
  for b in ssh_host_ed25519_key ssh_host_ed25519_key.pub; do
    base64 < "$WORKROOT/hostkeys/$b" | sbx exec -i "$NAME" -- sudo sh -c "base64 -d > /etc/ssh/$b && chmod 600 /etc/ssh/$b" 1>&2 \
      || fail "could not restore host key $b into sandbox"
  done
else
  mkdir -p "$WORKROOT/hostkeys"
  for b in ssh_host_ed25519_key ssh_host_ed25519_key.pub; do
    # touch+chmod before writing so the private key is never briefly
    # world/group-readable between file creation and the mode fix.
    : > "$WORKROOT/hostkeys/$b"
    chmod 600 "$WORKROOT/hostkeys/$b"
    sbx exec "$NAME" -- sudo cat "/etc/ssh/$b" >> "$WORKROOT/hostkeys/$b" \
      || fail "could not save host key $b from sandbox"
  done
fi

# Per-project keypair: private half stays on the host, public half authorized in the VM.
if [ ! -f "$WORKROOT/id_ed25519" ]; then
  ssh-keygen -q -t ed25519 -f "$WORKROOT/id_ed25519" -N '' </dev/null 1>&2 \
    || fail "could not generate SSH key"
fi
PUB="$(cat "$WORKROOT/id_ed25519.pub")"
sbx exec "$NAME" -- sh -c "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qF '$PUB' ~/.ssh/authorized_keys || printf '%s\n' '$PUB' >> ~/.ssh/authorized_keys; }" 1>&2 \
  || fail "could not install SSH key in sandbox"
ensure_sshd "$NAME"

# shellcheck disable=SC2016 # $HOME must expand inside the sandbox, not locally
RHOME="$(sbx exec "$NAME" -- sh -c 'printf %s "$HOME"')"
[ -n "$RHOME" ] || fail "could not resolve \$HOME inside sandbox $NAME"
if ! sbx exec "$NAME" -- test -d "$RHOME/project/.git"; then
  URL="${ORCA_REPO_URL:-}"
  if [ -z "$URL" ]; then
    URL="$(git -C "$ORCA_REPO_PATH" remote get-url origin)" \
      || fail "the source repo has no 'origin' remote and Orca provided no URL; add a remote, or clone into the sandbox manually with 'sbx exec'"
  fi
  printf 'orca-sbx: cloning %s into %s\n' "$URL" "$NAME" >&2
  sbx exec "$NAME" -- git clone -- "$URL" "$RHOME/project" 1>&2 \
    || fail "clone failed inside sandbox — check 'sbx secret set github' or SSH agent forwarding"
fi

# Orca's project flows require a git author identity on the SSH host (spike:
# create-project preflight rejects without it). Mirror the desktop's identity.
GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
if [ -n "$GIT_NAME" ]; then sbx exec "$NAME" -- git config --global user.name "$GIT_NAME" 1>&2; fi
if [ -n "$GIT_EMAIL" ]; then sbx exec "$NAME" -- git config --global user.email "$GIT_EMAIL" 1>&2; fi

# Interactive non-login shells over direct sshd miss ~/.local/bin (claude
# and friends live there); make .bashrc export it, idempotently.
# shellcheck disable=SC2016 # the PATH must expand inside the sandbox, not locally
sbx exec "$NAME" -- sh -c 'grep -qF ".local/bin" ~/.bashrc 2>/dev/null || printf '"'"'\nexport PATH="$HOME/.local/bin:$PATH"\n'"'"' >> ~/.bashrc' 1>&2 \
  || fail "could not update PATH in sandbox shell profile"
ensure_keepalive "$NAME"

emit_connection_json "$NAME"
