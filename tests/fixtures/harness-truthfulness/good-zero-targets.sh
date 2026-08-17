#!/bin/sh
# The same detector, refusing to report success over an empty target set.
n=0
for _f in /nonexistent-directory-xyz/*.sh; do
	[ -e "$_f" ] || continue
	n=$((n + 1))
done
if [ "$n" -eq 0 ]; then
	printf "FAIL: zero targets discovered — this detector would pass vacuously\n"
	exit 1
fi
printf "PASS: checked %s target(s)\n" "$n"
