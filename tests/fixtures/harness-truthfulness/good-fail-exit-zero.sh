#!/bin/sh
# Prints a failure and exits non-zero.
FAILS=0
printf 'FAIL: something did not work\n'; FAILS=1
[ "$FAILS" -eq 0 ] || exit 1
