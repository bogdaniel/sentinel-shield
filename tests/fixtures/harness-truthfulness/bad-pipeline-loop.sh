#!/bin/sh
# The loop body runs in a SUBSHELL, so FAILS never reaches the parent.
FAILS=0
printf 'a\nb\n' | while read -r _x; do
	FAILS=$((FAILS + 1))
done
[ "$FAILS" -eq 0 ] || exit 1
