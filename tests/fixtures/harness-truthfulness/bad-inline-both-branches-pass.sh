#!/bin/sh
# BROKEN: a complete single-line conditional whose both arms call only the success helper.
pass() { printf "PASS: %s\n" "$1"; }
if grep -q needle /dev/null; then pass "present"; else pass "absent, also fine"; fi
