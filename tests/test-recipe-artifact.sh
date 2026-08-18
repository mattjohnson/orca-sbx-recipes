#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"
ART=recipes/sbx-project-sandbox.json

jq -e '
  .schemaVersion == 1
  and .id == "sbx-project-sandbox"
  and .name == "Docker Sandbox (project-shared)"
  and (.create | length > 0)
  and (.suspend | length > 0) and (.resume | length > 0)   # suspend/resume must be paired
  and (.destroy | length > 0)' "$ART" >/dev/null \
  || { echo "FAIL artifact shape"; FAILURES=$((FAILURES+1)); }

# each command under Orca's 32KB cap
for f in create suspend resume destroy; do
  n="$(jq -r ".$f | length" "$ART")"
  [ "$n" -lt 32768 ] || { echo "FAIL $f exceeds 32KB ($n)"; FAILURES=$((FAILURES+1)); }
done

# generated commands are exactly preamble + script (regen is deterministic)
for f in create suspend resume destroy; do
  jq -r ".$f" "$ART" > "$TESTTMP/gen-$f"
  cat scripts/lifecycle/common.sh "scripts/lifecycle/$f.sh" > "$TESTTMP/src-$f"
  cmp -s "$TESTTMP/gen-$f" "$TESTTMP/src-$f" || { echo "FAIL $f drifted from source — run scripts/build-recipe.sh"; FAILURES=$((FAILURES+1)); }
done

# plugin manifest points at the artifact
jq -e '.manifestVersion == 1 and .pluginApi == 1
  and .contributes.vmRecipes == [{"path":"recipes/sbx-project-sandbox.json"}]' orca-plugin.json >/dev/null \
  || { echo "FAIL manifest"; FAILURES=$((FAILURES+1)); }

finish
