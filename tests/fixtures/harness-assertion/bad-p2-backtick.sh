#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a backtick substitution on a helper line (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true "a detail built with a backtick: `printf D9-EXECUTED`" true
assert_summary 'bad-p2-backtick'
