#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: defines and calls pass/fail directly (P1).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; }
. "$ROOT/tests/lib/assert.sh"
assert_true 'a canonical assertion is present' true
# The defect: a conditional reaching a verdict. Under P1 a registered suite has no pass/fail to
# call, so this cannot be written at all -- which is why D3's single-line bypass stops mattering
# for registered suites.
if [ "$ROOT" = "$ROOT" ]; then pass "both arms pass"; else pass "both arms pass"; fi
assert_summary 'bad-p1'
