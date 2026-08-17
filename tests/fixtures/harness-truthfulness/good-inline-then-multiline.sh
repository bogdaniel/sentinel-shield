#!/bin/sh
# VALID: a self-contained inline conditional followed by an ordinary multiline one.
# Proves no stale frame survives the inline form.
pass() { printf "PASS: %s\n" "$1"; }
fail() { printf "FAIL: %s\n" "$1"; exit 1; }
if [ -f /dev/null ]; then pass "inline ok"; else fail "inline bad"; fi
if [ -d /tmp ]; then
	pass "multiline ok"
else
	fail "multiline bad"
fi
