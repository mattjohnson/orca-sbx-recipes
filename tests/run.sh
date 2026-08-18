#!/bin/sh
set -u
cd "$(dirname "$0")/.." || exit 1
rc=0
for t in tests/test-*.sh; do
  echo "== $t"; sh "$t" || rc=1
done
exit $rc
