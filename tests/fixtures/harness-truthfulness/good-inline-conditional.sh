#!/bin/sh
# VALID: a single-line conditional with a real failure path.
pass() { printf "PASS: %s\n" "$1"; }
fail() { printf "FAIL: %s\n" "$1"; exit 1; }
if grep -q needle /dev/null; then pass "present"; else fail "absent"; fi
