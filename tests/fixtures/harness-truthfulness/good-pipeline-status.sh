#!/bin/sh
# The command's own status is captured before anything downstream runs.
out=$(git push origin some-branch 2>&1); rc=$?
printf '%s\n' "$out" | tail -2
[ "$rc" -eq 0 ] || exit 1
