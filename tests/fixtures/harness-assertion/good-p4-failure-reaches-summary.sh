#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: a top-level failure reaches the epilogue and exits non-zero (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a top-level failure' false
assert_summary 'good-p4-failure'
