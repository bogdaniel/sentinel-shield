#!/bin/sh
# tests/prod/190-hygiene.sh — WS19 repo hygiene / fixture policy gate.
#
# Asserts the TRACKED git tree carries no junk or secret material that a
# production tool repo must never ship:
#   - no tracked vendor/ , node_modules/ , reports/raw/ (installed deps / raw scans)
#   - no tracked .env / .env.<x> secrets (ALLOW *.example / .env.example naming)
#   - no tracked private key material (*.key/*.p12/*.pfx/*.pem)
#   - no tracked .sentinel-shield-tools/ provisioned-tool checkout
#   - no committed .claude/ harness dir
#
# Fixture realism: e2e/example trees legitimately commit vendor binaries, sample
# raw scanner reports, and example certs. Paths whose segments are clearly
# test/fixture/example material are whitelisted for the dir-junk and cert checks
# (mirrors the cert allowance). A vendor/ or *.pem OUTSIDE such a path is a real
# violation and FAILS. Secret .env files, the tool checkout, and .claude/ are
# never whitelisted.
#
# Self-contained, no network. Operates on the live tree via `git ls-files`.
# Each violation prints FAIL with the offending path; exit 1 if any, else 0.
# Run via: sh tests/prod/190-hygiene.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

# POSITIVE CONTROL. Every check below is `git ls-files | grep ... || true`, where the
# `|| true` covers the WHOLE pipeline — so outside a work tree, or with git missing,
# `git ls-files` exits 128, the output is empty, and all seven hygiene checks print PASS
# having inspected nothing. A suite that cannot see the repository must fail loudly, not
# certify it clean.
if ! command -v git >/dev/null 2>&1; then
	bad "git is not available — the hygiene checks cannot inspect the tree"
	exit 1
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	bad "not inside a git work tree — the hygiene checks would pass vacuously"
	exit 1
fi
_ctl=$(git ls-files | grep -c . 2>/dev/null || printf '')
case "$_ctl" in
	'' | 0)
		bad "git ls-files returned no tracked files — the hygiene checks would pass vacuously"
		exit 1 ;;
esac
ok "positive control: git ls-files sees $_ctl tracked file(s)"

# A path segment that marks deliberate test/fixture/example material.
FIXTURE_RE='(^|/)(tests?|fixtures?|examples?)(/|$)'

# tracked PAT [ALLOW_RE] -> echoes offending tracked paths (allow-filtered),
# one per line; empty output means clean. Robust to empty grep under set -e.
tracked() {
	_pat=$1
	_allow=${2:-}
	_hits=$(git ls-files | grep -E "$_pat" || true)
	[ -n "$_allow" ] && _hits=$(printf '%s\n' "$_hits" | grep -vE "$_allow" || true)
	printf '%s\n' "$_hits" | grep -v '^[[:space:]]*$' || true
}

# desc PAT [ALLOW_RE]: PASS when no offending tracked path remains, else one
# FAIL per offending path.
check() {
	_desc=$1
	_hits=$(tracked "$2" "${3:-}")
	if [ -z "$_hits" ]; then
		ok "no tracked $_desc"
	else
		printf '%s\n' "$_hits" | while IFS= read -r _p; do
			[ -n "$_p" ] && printf 'FAIL: tracked %s: %s\n' "$_desc" "$_p"
		done
		FAILED=1
	fi
}

# Installed-dependency / raw-scan dirs (fixture trees whitelisted).
check 'vendor/'        '(^|/)vendor/'        "$FIXTURE_RE"
check 'node_modules/'  '(^|/)node_modules/'  "$FIXTURE_RE"
check 'reports/raw/'   '(^|/)reports/raw/'   "$FIXTURE_RE"

# Secret env files: .env / .env.<x>; ALLOW clearly-named *.example / .env.example.
check '.env secret'    '(^|/)\.env(\.[^/]*)?$'  '\.example$'

# Private key material; ALLOW clearly-named example/fixture/test certs.
check 'private key material'  '\.(key|p12|pfx|pem)$'  "$FIXTURE_RE"

# Provisioned-tool checkout — never committed.
check '.sentinel-shield-tools/ checkout'  '(^|/)\.sentinel-shield-tools/'

# Harness config — never committed.
check '.claude/'  '(^|/)\.claude/'

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
