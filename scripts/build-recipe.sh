#!/usr/bin/env bash
# Dev tool (bash + jq): inlines lifecycle scripts into the plugin recipe artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
body() { cat scripts/lifecycle/common.sh "scripts/lifecycle/$1"; }
mkdir -p recipes
# Capture bodies into variables first — assignment exit status DOES propagate under set -e.
create_body="$(body create.sh)"
suspend_body="$(body suspend.sh)"
resume_body="$(body resume.sh)"
destroy_body="$(body destroy.sh)"
jq -n \
  --arg create "$create_body" \
  --arg suspend "$suspend_body" \
  --arg resume "$resume_body" \
  --arg destroy "$destroy_body" '
{
  schemaVersion: 1,
  id: "sbx-project-sandbox",
  name: "Docker Sandbox (project-shared)",
  description: "One Docker Sandboxes (sbx) microVM per project; all worktrees share it. Agents run inside the VM; credentials stay host-side via the sbx proxy.",
  create: $create,
  suspend: $suspend,
  resume: $resume,
  destroy: $destroy
}' > recipes/sbx-project-sandbox.json
echo "wrote recipes/sbx-project-sandbox.json" >&2
