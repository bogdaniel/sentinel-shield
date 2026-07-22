#!/bin/sh
# Sentinel Shield prod test — DAST guard honors a COMMITTED allowlist file.
#
# The dispatch inputs (target_url + allowed_host) are self-attested by the dispatcher. When a
# committed allowlist file is present, the target host must ALSO appear in it (a review-gated
# repo change), so dispatch rights alone cannot authorize scanning an arbitrary host.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
GUARD="$ROOT/scripts/runners/dast-guard.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
[ -f "$GUARD" ] || { fail "missing $GUARD"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss276)
trap 'cd /; rm -rf -- "$WORK"' EXIT INT TERM
mkdir -p "$WORK/.sentinel-shield"
printf 'good.example.com\n# a comment\nother.example.com\n' > "$WORK/.sentinel-shield/dast-allowlist.txt"

# rc of ss_dast_check for a (url, allowed_host) pair, run with CWD=$WORK and given env.
chk() { ( cd "$WORK" && env "$@" sh -c ". \"$GUARD\"; ss_dast_check >/dev/null 2>&1; echo \$?" ); }

_rc=$(chk SENTINEL_SHIELD_DAST_TARGET_URL=https://good.example.com/ SENTINEL_SHIELD_DAST_ALLOWED_HOST=good.example.com)
[ "$_rc" -eq 0 ] && pass "allowlisted host + matching allowed_host -> proceed" || fail "allowlisted host rc=$_rc (want 0)"

_rc=$(chk SENTINEL_SHIELD_DAST_TARGET_URL=https://evil.example.com/ SENTINEL_SHIELD_DAST_ALLOWED_HOST=evil.example.com)
[ "$_rc" -eq 3 ] && pass "self-attested host NOT in committed allowlist -> fail closed" || fail "self-attested-only rc=$_rc (want 3)"

_rc=$(chk SENTINEL_SHIELD_DAST_ALLOWLIST_FILE="$WORK/nope.txt" SENTINEL_SHIELD_DAST_TARGET_URL=https://good.example.com/ SENTINEL_SHIELD_DAST_ALLOWED_HOST=good.example.com)
[ "$_rc" -eq 3 ] && pass "configured-but-missing allowlist file -> fail closed" || fail "missing-file rc=$_rc (want 3)"

# The batch-3 userinfo-bypass fix must still hold with the allowlist in play.
_rc=$(chk SENTINEL_SHIELD_DAST_TARGET_URL='http://good.example.com:x@evil.com/' SENTINEL_SHIELD_DAST_ALLOWED_HOST=good.example.com)
[ "$_rc" -eq 3 ] && pass "userinfo-bypass URL still fails closed" || fail "userinfo bypass rc=$_rc (want 3)"

[ "$FAILED" -eq 0 ] && printf '\n276-dast-allowlist: 0 failure(s)\nAll DAST allowlist assertions passed.\n' || {
	printf '\n276-dast-allowlist: FAILURES above.\n'; exit 1; }
