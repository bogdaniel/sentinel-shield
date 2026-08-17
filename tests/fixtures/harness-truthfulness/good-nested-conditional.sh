#!/bin/sh
# VALID: a nested conditional — an inline child inside a multiline parent. The child is
# self-contained and must not disturb the parent frame.
pass() { printf "PASS: %s\n" "$1"; }
fail() { printf "FAIL: %s\n" "$1"; exit 1; }
if [ -f /dev/null ]; then
	if grep -q x /dev/null; then pass "inner present"; else fail "inner absent"; fi
	pass "outer"
else
	fail "outer missing"
fi
