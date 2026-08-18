#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a command substitution on a helper line inside a command group (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# The helper sits inside a command group, so the line did not begin with a helper name and P2
# never inspected it. The substitution runs.
{ assert_true "detail built inside a group: $(printf D9-EXECUTED)" true; }
assert_summary 'bad-p2-compound'
