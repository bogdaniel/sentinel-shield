#!/bin/sh
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }
if grep -q needle /dev/null; then
	pass "the needle is present"
else
	fail "the needle is absent"
fi
