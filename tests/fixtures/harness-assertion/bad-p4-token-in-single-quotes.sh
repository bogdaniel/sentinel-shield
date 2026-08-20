#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: the only assert_summary token sits inside SINGLE-quoted data (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'this FAILS and must sink the suite' false
printf '%s\n' 'x; assert_summary fake'
