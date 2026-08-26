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

# major >= 10 must not be misread as its last digit (greedy-capture regression)
export STUB_VERSION='sbx version 10.2.3'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "bootstrap rc two-digit major"
assert_contains "$out" "found 10.2" "two-digit major parsed whole"

# real-world format: leading v and a trailing commit sha
export STUB_VERSION='sbx version: v0.38.0 c022b14634c4bea846ca12870d1d5e97d5868b54'
out="$(sh scripts/bootstrap.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "bootstrap rc v-prefixed with sha"
assert_contains "$out" "found 0.38" "v-prefixed version parsed"

finish
