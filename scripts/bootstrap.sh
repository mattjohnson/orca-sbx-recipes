#!/bin/sh
# Non-destructive prerequisite checker for orca-sbx-recipes.
set -u
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin"
BAD=0
ok()  { printf '  \342\234\223 %s\n' "$1"; }
bad() { BAD=1; printf '  \342\234\227 %s\n      fix: %s\n' "$1" "$2"; }

echo "orca-sbx-recipes prerequisites:"

if command -v sbx >/dev/null 2>&1; then
  ok "sbx CLI installed"
else
  bad "sbx CLI installed" "brew trust docker/tap && brew install docker/tap/sbx  (see https://docs.docker.com/ai/sandboxes/install/)"
fi

if command -v sbx >/dev/null 2>&1 && sbx ls --json >/dev/null 2>&1; then
  ok "sbx logged in"
else
  bad "sbx logged in" "sbx login   # then: sbx policy init balanced"
fi

# Version floor: the release this pack was validated against (see
# docs/spike/2026-08-17-findings.md; reconcile if the spike recorded newer).
MIN_MAJOR=0 MIN_MINOR=38
VER="$(sbx version 2>/dev/null | sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.[0-9][0-9]*.*/\1.\2/p' | head -n1)"
MAJOR="${VER%%.*}"; MINOR="${VER#*.}"
if [ -n "$VER" ] && { [ "$MAJOR" -gt "$MIN_MAJOR" ] || { [ "$MAJOR" -eq "$MIN_MAJOR" ] && [ "$MINOR" -ge "$MIN_MINOR" ]; }; }; then
  ok "sbx version >= $MIN_MAJOR.$MIN_MINOR (found $VER)"
else
  bad "sbx version >= $MIN_MAJOR.$MIN_MINOR" "brew upgrade sbx   # this pack is validated against sbx >= $MIN_MAJOR.$MIN_MINOR"
fi

SECRETS="$(sbx secret ls 2>/dev/null || true)"
case "$SECRETS" in
  *github*) ok "github secret configured" ;;
  *) bad "github secret configured" "gh auth token | sbx secret set github" ;;
esac
case "$SECRETS" in
  *anthropic*) ok "anthropic secret configured" ;;
  *) bad "anthropic secret configured" "sbx secret set anthropic   # or run /login inside the sandboxed claude once" ;;
esac

if [ "$BAD" -eq 0 ]; then
  echo "All prerequisites satisfied."
else
  echo "Fix the items above, then re-run: sh scripts/bootstrap.sh"
fi
exit "$BAD"
