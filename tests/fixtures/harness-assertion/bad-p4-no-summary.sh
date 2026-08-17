#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: no assert_summary, so the suite cannot report a verdict (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'an assertion with no epilogue' true
