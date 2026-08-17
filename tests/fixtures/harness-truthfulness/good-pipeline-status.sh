#!/bin/sh
# VALID CONTROL: the command's own status is captured before anything downstream runs.
#
# INERT BY CONSTRUCTION, same as the broken fixture.
git() { printf "simulated failure\n" >&2; return 1; }
out=$(git push origin some-branch 2>&1); rc=$?
printf "%s\n" "$out" | tail -2
[ "$rc" -eq 0 ] || exit 1
