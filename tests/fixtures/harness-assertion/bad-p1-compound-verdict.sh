#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a spaced pass() definition and a verdict inside a command group (P1).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
pass () { printf 'PASS: %s\n' "$1"; }
. "$ROOT/tests/lib/assert.sh"
assert_true 'a genuine canonical assertion' true
# TWO bypasses in one line: a SPACED function definition, and a verdict reached inside a command
# group. Neither was at a recognised command position, so P1 looked straight past both and the
# D3 class was available again inside a "canonical" suite.
{ pass "both arms would pass, and nothing could see it"; }
assert_summary 'bad-p1-compound'
