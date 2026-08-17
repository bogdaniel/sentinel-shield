#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: the rejection carries its acceptance control in the same call (P3).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# The control is an ARGUMENT, not a neighbouring line, so a rejection without one cannot be
# expressed. This is the shape #310's enforcement gate shipped without.
assert_rejection_with_control 'a forged record is refused, and a valid one is still accepted' \
	-- false -- true
assert_summary 'good-p3'
