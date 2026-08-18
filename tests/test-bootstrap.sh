#!/bin/sh
# shellcheck disable=SC1091 # harness path is runtime-relative
. "$(dirname "$0")/harness.sh"

# all prereqs green
export STUB_LS_JSON='{"sandboxes":[]}' STUB_SECRETS='github
anthropic'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "bootstrap rc all-green"
assert_contains "$out" "sbx CLI" "reports CLI check"

# missing secrets → advisory only: still exit 0, but prints the fix commands
export STUB_SECRETS=''
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "bootstrap rc missing secrets"
assert_contains "$out" "sbx secret set github" "github fix hint"
assert_contains "$out" "sbx secret set anthropic" "anthropic fix hint"

# sbx older than the tested floor → exit 1 with upgrade hint
export STUB_SECRETS='github
anthropic' STUB_VERSION='sbx version 0.30.1'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "1" "bootstrap rc old sbx"
assert_contains "$out" "0.38" "version floor mentioned"

finish
