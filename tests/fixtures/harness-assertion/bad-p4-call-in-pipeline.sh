#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: the epilogue is a pipeline segment, so its status is the pipeline's last command (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'this FAILS and must sink the suite' false
assert_summary 'piped away' | cat
