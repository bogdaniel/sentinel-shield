#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: verdicts only at parent-shell positions; non-verdict subshells and pipelines allowed (P9).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# CONTROLS, all four in one file so the accepted shapes are visible together.
# 1. an equivalent failure AT TOP LEVEL must reach the parent verdict.
assert_true 'a top-level failure is counted by the parent' false
# 2. a NON-VERDICT subshell is legitimate and stays allowed.
_v=$( (printf 'sub\n') )
assert_equal 'a non-verdict subshell is allowed' 'sub' "$_v"
# 3. a NON-VERDICT pipeline is legitimate and stays allowed.
_w=$(printf 'a\nb\n' | wc -l | tr -d ' ')
assert_equal 'a non-verdict pipeline is allowed' '2' "$_w"
# 4. a canonical top-level assertion is accepted.
assert_true 'a canonical top-level assertion' true
assert_summary 'good-p9-parent'
