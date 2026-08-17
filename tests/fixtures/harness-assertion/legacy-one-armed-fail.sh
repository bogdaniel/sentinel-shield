#!/bin/sh
# FIXTURE for tests/prod/307. LEGACY SHAPE, runnable: a one-armed `&& fail` emits no verdict for passing rows.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
# PRIOR SHAPE, from 305's backend loop:
#   [ "$_b" = "$_key" ] && fail "backend is the producer key"
# Three rows, all correct. The suite prints NOTHING for them and counts nothing, so a reader
# cannot tell whether the check ran at all.
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
for _row in php-mutation:infection js-mutation:stryker php-coverage:phpunit; do
	_key=${_row%%:*}; _b=${_row##*:}
	[ "$_b" = "$_key" ] && fail "$_key: backend '$_b' is the producer key"
done
printf 'legacy: exit 0 with %d failure(s)\n' "$FAILS"
exit 0
