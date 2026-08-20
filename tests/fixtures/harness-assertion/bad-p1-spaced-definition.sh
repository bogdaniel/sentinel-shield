#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a SPACED verdict-primitive definition (P1).
#
# `pass()` was recognised; `pass ()` was not. The suite then owns a verdict primitive, which is
# the precondition for every both-branches-pass this policy exists to make unwritable.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
pass () { printf 'PASS: %s\n' "$1"; }
. "$ROOT/tests/lib/assert.sh"
assert_true 'a genuine canonical assertion' true
assert_summary 'bad-p1-spaced-definition'
