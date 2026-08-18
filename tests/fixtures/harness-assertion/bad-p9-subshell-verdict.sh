#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a verdict primitive inside a subshell (P9). RUNNABLE: prints FAIL and exits 0.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a real assertion in the parent' true
( assert_true 'this FAILS inside a subshell' false )
assert_summary 'bad-p9-subshell'
