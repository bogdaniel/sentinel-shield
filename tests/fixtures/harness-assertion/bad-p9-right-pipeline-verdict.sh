#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a verdict primitive in the RIGHT segment of a pipeline (P9).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a real assertion in the parent' true
printf 'x\n' | assert_true 'this FAILS in the right pipeline segment' false
assert_summary 'bad-p9-right-pipe'
