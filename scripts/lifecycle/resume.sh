# resume: ensure the shared sandbox is running, then re-emit connection JSON
# (the recipe contract requires a fresh result on every resume).
PAYLOAD_NAME="$(payload_sandbox_name)"
require_env
require_sbx
NAME="$(sandbox_name "$PAYLOAD_NAME")"
sandbox_exists "$NAME" \
  || fail "sandbox $NAME no longer exists (removed manually?); delete this workspace and create a new one"
# v0.38 has no `sbx start`; `sbx exec` auto-starts a stopped sandbox (~2s, spike).
sbx exec "$NAME" -- true 1>&2 || fail "sandbox $NAME failed to start"
emit_connection_json "$NAME"
