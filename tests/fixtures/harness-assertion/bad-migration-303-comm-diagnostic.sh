#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN: the pre-migration 303 shape — two comm substitutions in
# one diagnostic (P2).
#
# The inputs live in a mktemp -d directory with a cleanup trap. They used to be fixed names under
# ${TMPDIR:-/tmp}: a write there follows a pre-existing symlink, and two concurrent runs share
# one file.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
_d=$(mktemp -d) || exit 1
trap 'rm -rf "$_d" 2>/dev/null || :' EXIT
printf 'x\n' > "$_d/doc"; printf 'y\n' > "$_d/inv"
# PRIOR SHAPE:
#   fail "the published table and the inventory disagree: only-in-doc=[$(comm -23 ...)] only-in-inventory=[$(comm -13 ...)]"
assert_true "the table and the inventory disagree: only-in-doc=[$(comm -23 "$_d/doc" "$_d/inv" | tr '\n' ' ')] only-in-inventory=[$(comm -13 "$_d/doc" "$_d/inv" | tr '\n' ' ')]" true
assert_summary 'bad-migration-303-comm'
