#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: a quoted occurrence plus a real final epilogue is accepted (P4).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
assert_true 'a canonical assertion' true
printf '%s\n' 'the words assert_summary appear here as data' > /dev/null
assert_summary 'good-p4-harmless-quote'
