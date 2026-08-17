#!/bin/sh
# A detector that PASSES when it discovers nothing. If its target set becomes empty — a
# renamed directory, a changed glob — it reports success over an empty universe.
n=0
for _f in /nonexistent-directory-xyz/*.sh; do
	[ -e "$_f" ] || continue
	n=$((n + 1))
done
printf "PASS: checked %s target(s)\n" "$n"
exit 0
