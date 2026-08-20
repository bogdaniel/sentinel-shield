#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN, SINGLE FAULT: two standalone epilogues make the execution semantics ambiguous (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a passing assertion' true
assert_summary 'first'
assert_summary 'second'
