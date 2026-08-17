#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN: the pre-migration 303 shape — two comm substitutions in one diagnostic (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
printf 'x\n' > "${TMPDIR:-/tmp}/ss-mig-doc"; printf 'y\n' > "${TMPDIR:-/tmp}/ss-mig-inv"
# PRIOR SHAPE:
#   fail "the published table and the inventory disagree: only-in-doc=[$(comm -23 ...)] only-in-inventory=[$(comm -13 ...)]"
assert_true "the table and the inventory disagree: only-in-doc=[$(comm -23 "${TMPDIR:-/tmp}/ss-mig-doc" "${TMPDIR:-/tmp}/ss-mig-inv" | tr '\n' ' ')] only-in-inventory=[$(comm -13 "${TMPDIR:-/tmp}/ss-mig-doc" "${TMPDIR:-/tmp}/ss-mig-inv" | tr '\n' ' ')]" true
assert_summary 'bad-migration-303-comm'
