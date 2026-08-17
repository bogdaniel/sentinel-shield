#!/bin/sh
# FIXTURE for tests/prod/307. BROKEN: the pre-migration 305 shape — a diff substitution built inside a diagnostic (P2).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
printf 'a\n' > "${TMPDIR:-/tmp}/ss-mig-a"; printf 'b\n' > "${TMPDIR:-/tmp}/ss-mig-b"
# PRIOR SHAPE, reproduced verbatim in structure:
#   fail "the rendered document and the committed document differ: $(diff "$TMP/rendered.md" "$DOC" | head -3 | tr '\n' ' ')"
assert_equal "the documents differ: $(diff "${TMPDIR:-/tmp}/ss-mig-a" "${TMPDIR:-/tmp}/ss-mig-b" | head -3 | tr '\n' ' ')" "" ""
assert_summary 'bad-migration-305-diff'
