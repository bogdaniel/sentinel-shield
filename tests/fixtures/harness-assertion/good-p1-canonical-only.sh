#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: verdicts come only from helpers; an inline conditional selects an assertion (P1, P7).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'the same property, stated through a helper' test "$ROOT" = "$ROOT"
# An inline conditional is still allowed -- it chooses WHICH assertion applies. It cannot reach
# a verdict, because no verdict primitive is in scope.
if [ -d "$ROOT" ]; then
	assert_true 'the root directory is readable' test -r "$ROOT"
fi
assert_summary 'good-p1'
