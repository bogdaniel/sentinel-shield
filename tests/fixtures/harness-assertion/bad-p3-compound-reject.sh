#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a bare assert_reject inside a command group (P3).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# A bare rejection hidden in a command group: satisfied by a component that refuses everything.
{ assert_reject 'a forged record is refused' false; }
assert_summary 'bad-p3-compound'
