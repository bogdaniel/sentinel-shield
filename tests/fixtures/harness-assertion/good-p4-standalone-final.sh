#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: a single standalone epilogue as the final command (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a canonical top-level assertion' true
assert_summary 'good-p4-standalone'
