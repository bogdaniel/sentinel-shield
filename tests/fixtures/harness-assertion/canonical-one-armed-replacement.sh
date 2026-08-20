#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: the canonical replacement emits one verdict per row (the finding-3 repair).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# CANONICAL REPLACEMENT: the same three rows, each stating its own verdict. Passing rows are now
# visible in the output and counted by the library, which is the property the prior shape lost.
for _row in php-mutation:infection js-mutation:stryker php-coverage:phpunit; do
	_key=${_row%%:*}; _b=${_row##*:}
	assert_false "$_key: backend '$_b' is not the producer key" test "$_b" = "$_key"
done
assert_summary 'canonical-one-armed'
