#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: zero assertions ran; the epilogue must refuse to report success (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# Nothing ran. Without the library epilogue this would exit 0 and read as success.
assert_summary 'bad-p4-zero'
