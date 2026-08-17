#!/bin/sh
# VALID CONTROL: a harmless pipeline-fed loop that mutates NO parent verdict state.
# It only prints, so the subshell is irrelevant to the outcome.
printf "a\nb\n" | while read -r _x; do
	printf "saw %s\n" "$_x"
done
