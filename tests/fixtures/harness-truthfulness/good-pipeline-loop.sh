#!/bin/sh
# Same loop, fed from a file: the body runs in this shell and FAILS propagates.
FAILS=0
_t=$(mktemp); printf 'a\nb\n' > "$_t"
while read -r _x; do
	FAILS=$((FAILS + 1))
done < "$_t"
rm -f "$_t"
[ "$FAILS" -eq 0 ] || exit 1
