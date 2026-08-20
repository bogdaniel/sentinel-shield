#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a command substitution on a continuation line of a helper call (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# The substitution is on the CONTINUATION line, which does not begin with a helper name. P2
# tracks the continuation, so it is still inside the call.
assert_true "a continued call" \
	test "$(printf D9-EXECUTED)" = "D9-EXECUTED"
assert_summary 'bad-p2-continued'
