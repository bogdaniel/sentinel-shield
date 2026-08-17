#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a bare assert_reject where the paired form is required (P3).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# Satisfied by a component that refuses EVERYTHING, including one that is simply broken.
assert_reject 'a forged record is refused' false
assert_summary 'bad-p3'
