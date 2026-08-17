#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: a command substitution inside a diagnostic argument (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true "a detail built inline: $(printf D9-EXECUTED)" true
assert_summary 'bad-p2'
