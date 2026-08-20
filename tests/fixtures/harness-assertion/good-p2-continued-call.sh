#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: a multi-line canonical call carrying no substitution (P2 continuation).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# A canonical call MAY span lines. P2 follows the continuation, so a substitution on the second
# physical line belongs to the same logical call and is caught -- proven by the mutation beside
# this control.
_detail=$(printf 'computed before the call')
assert_true "a continued call whose detail is data: $_detail" \
	test 1 -eq 1
assert_summary 'good-p2-continued'
