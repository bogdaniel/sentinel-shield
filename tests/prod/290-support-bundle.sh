#!/bin/sh
# Sentinel Shield prod test — support-bundle.sh redaction + exclusion contract.
#
# support-bundle.sh produces a SHAREABLE diagnostics tarball; a redaction regression in it
# leaks secrets exactly where the user expects a safe artifact. This asserts:
#   (a) secret-shaped tokens in an included config are redacted in the bundle;
#   (b) raw scanner artifacts are EXCLUDED by default;
#   (c) with --include-raw, raw copies are still redacted;
#   (d) the bundle carries no unredacted seeded secret anywhere.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SB="$ROOT/scripts/support-bundle.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq required"; exit 1; }
command -v tar >/dev/null 2>&1 || { fail "tar required"; exit 1; }
[ -f "$SB" ] || { fail "missing $SB"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss290)
trap 'rm -rf -- "$WORK"' EXIT INT TERM
T="$WORK/target"; mkdir -p "$T/.sentinel-shield" "$T/reports/raw"

SECRET="ghp_AAAAAAAAAAAAAAAAAAAAAAAA1234secret"
AWS="AKIAABCDEFGHIJKLMNOP"
printf 'api_token: %s\nAWS_ACCESS_KEY_ID=%s\nname: demo\n' "$SECRET" "$AWS" > "$T/.sentinel-shield/profile.yaml"
printf '{"schema_version":"1","summary":{},"note":"token=%s"}\n' "$SECRET" > "$T/reports/security-summary.json"
printf '{"leak":"%s"}\n' "$SECRET" > "$T/reports/raw/semgrep.json"

extract() { d="$WORK/x$1"; rm -rf "$d"; mkdir -p "$d"; tar -xzf "$2" -C "$d"; printf '%s' "$d"; }

# --- default bundle: redacted config, raw excluded ---
OUT="$WORK/bundle.tar.gz"
sh "$SB" --target "$T" --out "$OUT" >/dev/null 2>&1 || { fail "default bundle did not write"; exit 1; }
D=$(extract 1 "$OUT")
if grep -rqF "$SECRET" "$D" 2>/dev/null || grep -rqF "$AWS" "$D" 2>/dev/null; then
	fail "default bundle LEAKS a seeded secret"; grep -rlF "$SECRET" "$D" 2>/dev/null | head
else
	pass "default bundle carries no unredacted seeded secret"
fi
[ -f "$D/support-bundle/raw-EXCLUDED.txt" ] && pass "raw artifacts excluded by default" || fail "raw not excluded by default"
[ -d "$D/support-bundle/raw" ] && fail "raw dir present without --include-raw"

# --- --include-raw: raw copies still redacted ---
OUT2="$WORK/bundle-raw.tar.gz"
sh "$SB" --target "$T" --out "$OUT2" --include-raw >/dev/null 2>&1 || { fail "--include-raw bundle did not write"; exit 1; }
D2=$(extract 2 "$OUT2")
if grep -rqF "$SECRET" "$D2" 2>/dev/null; then
	fail "--include-raw bundle LEAKS the seeded secret in a raw copy"
else
	pass "--include-raw raw copies are redacted"
fi

[ "$FAILED" -eq 0 ] && printf '\n290-support-bundle: 0 failure(s)\nAll support-bundle redaction assertions passed.\n' || {
	printf '\n290-support-bundle: FAILURES above.\n'; exit 1; }
