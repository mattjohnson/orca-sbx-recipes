#!/usr/bin/env bash
# Dev tool (bash + jq): inlines lifecycle scripts into the plugin recipe artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
body() { cat scripts/lifecycle/common.sh "scripts/lifecycle/$1"; }
mkdir -p recipes
jq -n \
  --arg create "$(body create.sh)" \
  --arg suspend "$(body suspend.sh)" \
  --arg resume "$(body resume.sh)" \
  --arg destroy "$(body destroy.sh)" '
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
