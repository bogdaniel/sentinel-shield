#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN: the pre-migration 305 shape — printf piped through tr inside a diagnostic (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
_multi='php-coverage
js-coverage'
# PRIOR SHAPE:
#   pass "multi-backend producers are present ($(printf '%s' "$_multi" | tr '\n' ' '))"
assert_true "multi-backend producers are present ($(printf '%s' "$_multi" | tr '\n' ' '))" true
assert_summary 'bad-migration-305-printf-tr'
