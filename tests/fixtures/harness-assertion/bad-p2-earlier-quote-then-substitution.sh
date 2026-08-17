#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: an earlier safe quote precedes the substitution -- the legacy D9 bypass (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# THE RETAINED D9 BYPASS, in canonical form. An unrelated quoted expression comes FIRST, which
# is what defeated the legacy detector -- it scanned the first quoted string on the line. P2 does
# not resolve an argument boundary at all: a substitution anywhere on a helper line fails.
assert_equal 'an entirely safe label' "expected" "$(printf expected)"
assert_summary 'bad-p2-earlier'
