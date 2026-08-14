#!/bin/sh
# The same rejections, each with an acceptance control on the same path.
#
# The control is what makes a rejection attributable: it proves the component still accepts
# valid input, so the refusals above are about the defect and not about the component being
# broken or refusing everything.
#
# sentinel-shield-harness: declares-rejection
# sentinel-shield-harness: declares-control
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

_st=$(printf 'execution-error')
[ "$_st" = "execution-error" ] && pass "a forged record is refused" || fail "forged record accepted"
_st=$(printf 'pass')
[ "$_st" = "pass" ] && pass "CONTROL: a valid record is still accepted" || fail "CONTROL failed — the rejection above proves nothing"
