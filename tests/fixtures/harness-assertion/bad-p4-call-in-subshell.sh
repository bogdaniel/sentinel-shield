#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: the epilogue runs in a subshell, so it cannot decide the parent status (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'this FAILS and must sink the suite' false
( assert_summary 'in a subshell' )
