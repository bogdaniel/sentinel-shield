#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN: the pre-migration 305 shape — a diff substitution built
# inside a diagnostic (P2).
#
# Inputs are created with mktemp -d and removed by a trap, for the same reason as the 303 fixture.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
_d=$(mktemp -d) || exit 1
trap 'rm -rf "$_d" 2>/dev/null || :' EXIT
printf 'a\n' > "$_d/a"; printf 'b\n' > "$_d/b"
# PRIOR SHAPE:
#   fail "the rendered document and the committed document differ: $(diff "$TMP/rendered.md" "$DOC" | head -3 | tr '\n' ' ')"
assert_equal "the documents differ: $(diff "$_d/a" "$_d/b" | head -3 | tr '\n' ' ')" "" ""
assert_summary 'bad-migration-305-diff'
