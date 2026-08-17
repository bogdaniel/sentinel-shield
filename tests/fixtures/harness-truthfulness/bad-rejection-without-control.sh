#!/bin/sh
# A rejection assertion with NO neighbouring acceptance control.
#
# Every assertion here is satisfied by a collector that refuses EVERYTHING, including one that
# is simply broken. That is how the #310 enforcement gate shipped dead.
#
# sentinel-shield-harness: declares-rejection
# sentinel-shield-harness: no-control
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

_st=$(printf 'execution-error')
[ "$_st" = "execution-error" ] && pass "a forged record is refused" || fail "forged record accepted"
_st=$(printf 'execution-error')
[ "$_st" = "execution-error" ] && pass "a stale record is refused" || fail "stale record accepted"
