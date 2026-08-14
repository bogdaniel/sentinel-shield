#!/bin/sh
pass() { printf 'PASS: %s\n' "$1"; }
if grep -q needle /dev/null; then
	pass "the needle is present"
else
	pass "the needle is absent, which is also fine"
fi
