#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a real epilogue followed by a significant command, so its status is discarded (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'this FAILS and must sink the suite' false
assert_summary 'a real call, but not last'
printf 'and then something else\n'
