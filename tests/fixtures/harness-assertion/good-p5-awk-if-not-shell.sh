#!/bin/sh
# FIXTURE for tests/prod/307. CONTROL: embedded awk/jq conditionals are excluded structurally, not by quote stripping (P5).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
# An `if` inside a multi-line single-quoted awk program. It has no `fi`, which is exactly what
# leaked frames in the legacy detector. Here it is simply not assertion logic: the line does not
# begin with a helper name, so no policy rule looks at it, and no quote state is tracked anywhere.
_count=$(printf '1\n2\n3\n' | awk '
	{
		if ($1 > 1)
			n++
	}
	END { print n + 0 }
')
assert_equal 'the awk program is data, not shell assertion logic' 2 "$_count"
_j=$(printf '{"a":1}' | jq -r 'if .a == 1 then "yes" else "no" end')
assert_equal 'a jq conditional is likewise not shell' yes "$_j"
assert_summary 'good-p5'
