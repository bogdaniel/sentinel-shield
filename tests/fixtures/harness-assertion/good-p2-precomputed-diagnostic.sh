#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: the detail is computed into a variable, so the helper line carries no substitution (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# The canonical form: compute the detail, then pass it as data.
_detail=$(printf 'computed safely')
assert_true "a detail computed first: $_detail" true
assert_equal 'variables expand, commands do not run' "expected" "expected"
assert_summary 'good-p2'
