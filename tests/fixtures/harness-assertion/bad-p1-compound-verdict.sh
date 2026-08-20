#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a verdict reached inside a command group (P1).
#
# The command position was line start or `; && || then`, so a verdict inside `{ ... }` was never
# examined. The primitive is supplied by the library here, NOT redefined, so the only fault is
# where the call sits -- a rejection is attributable to the command group and to nothing else.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a genuine canonical assertion' true
{ pass "a verdict nothing could see"; }
assert_summary 'bad-p1-compound-verdict'
