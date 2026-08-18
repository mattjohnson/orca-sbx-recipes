# destroy: refcount — remove the shared sandbox only when this was the last
# workspace (no linked worktrees remain). Idempotent when already gone.
PAYLOAD_NAME="$(payload_sandbox_name)"
require_env
NAME="$(sandbox_name "$PAYLOAD_NAME")"
if ! command -v sbx >/dev/null 2>&1; then
  printf 'orca-sbx: sbx CLI missing; nothing to destroy\n' >&2
  exit 0
fi
if ! sandbox_exists "$NAME"; then
  printf 'orca-sbx: sandbox %s already gone\n' "$NAME" >&2
  rm -rf "$HOME/.orca-sbx/$NAME"
  exit 0
fi
# shellcheck disable=SC2016 # $HOME must expand inside the sandbox, not locally
RHOME="$(sbx exec "$NAME" -- sh -c 'printf %s "$HOME"')"
sbx exec "$NAME" -- git -C "$RHOME/project" worktree prune 1>&2 || true
WT_LIST="$(sbx exec "$NAME" -- git -C "$RHOME/project" worktree list --porcelain 2>/dev/null)" || {
  printf 'orca-sbx: could not query worktrees in %s; keeping sandbox (retry the delete later, or clean up manually with: sbx rm %s)\n' "$NAME" "$NAME" >&2
  exit 0
}
LINKED="$(printf '%s\n' "$WT_LIST" | grep -c '^worktree ' || true)"
if [ "${LINKED:-0}" -le 1 ]; then
  printf 'orca-sbx: removing sandbox %s (last workspace)\n' "$NAME" >&2
  sbx rm -f "$NAME" 1>&2
  rm -rf "$HOME/.orca-sbx/$NAME"
else
  printf 'orca-sbx: keeping sandbox %s (%s other worktree(s) remain)\n' "$NAME" "$((LINKED - 1))" >&2
fi
exit 0
