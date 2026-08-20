#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: no epilogue at all (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'this FAILS and must sink the suite' false
: "the suite simply ends"
