#!/bin/sh
# Sentinel Shield production test — release lifecycle validator (NN=265). Exercises
# scripts/validate-release-lifecycle.sh, the GENERATOR for the upgrade-validation and
# rollback-validation reports consumed by release authorization (GATE 8 / GATE 9).
#
# Proves: the generator drives the REAL install/sync/recover paths (no network), emits a
# ra_gate_ok-shaped report, returns result=pass with exit 0 when every real check holds, and
# fails closed (exit 2) on an invalid invocation. A green report can only come from a real
# passing run — the generator never fabricates result=pass.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib"
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$LIB/release-authz.sh"

command_exists jq || { printf 'FAIL: jq required\n' >&2; exit 1; }

GEN="$ROOT/scripts/validate-release-lifecycle.sh"
[ -f "$GEN" ] || { printf 'FAIL: generator not found: %s\n' "$GEN" >&2; exit 1; }
SC="0123456789abcdef0123456789abcdef01234567"   # a valid 40-hex source commit for the record

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sslcv)
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

# --- POSITIVE: upgrade + rollback each produce a real, green, gate-shaped report ----------
for kind in upgrade rollback; do
	_out="$WORK/$kind.json"; _rc=0
	sh "$GEN" --kind "$kind" --source-commit "$SC" --from 2.0.0-beta.1 --to 2.0.0-rc.1 --output "$_out" >/dev/null 2>&1 || _rc=$?
	if [ "$_rc" = 0 ]; then pass "$kind: generator exits 0"; else fail "$kind: generator exited $_rc"; fi
	if [ -s "$_out" ]; then
		[ "$(jq -r '.result' "$_out" 2>/dev/null)" = "pass" ] && pass "$kind: result=pass" || fail "$kind: result != pass"
		[ "$(jq -r '.report' "$_out" 2>/dev/null)" = "$kind-validation" ] && pass "$kind: report=$kind-validation" || fail "$kind: wrong report name"
		[ "$(jq -r '.source_commit' "$_out" 2>/dev/null)" = "$SC" ] && pass "$kind: source_commit bound" || fail "$kind: source_commit not bound"
		[ "$(jq -r '[.checks[]?]|length' "$_out" 2>/dev/null)" -ge 4 ] && pass "$kind: records real checks" || fail "$kind: too few checks"
		if ra_gate_ok "$_out"; then pass "$kind: report satisfies ra_gate_ok"; else fail "$kind: report fails ra_gate_ok"; fi
	else
		fail "$kind: no report emitted"
	fi
done

# --- NEGATIVE: invalid invocations fail closed (exit 2) -----------------------------------
_rc=0; sh "$GEN" --kind bogus --source-commit "$SC" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] && pass "invalid --kind -> exit 2 (fail closed)" || fail "invalid --kind expected 2, got $_rc"

_rc=0; sh "$GEN" --kind upgrade --source-commit "not-40-hex" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] && pass "non-hex --source-commit -> exit 2 (fail closed)" || fail "bad source-commit expected 2, got $_rc"

_rc=0; sh "$GEN" --source-commit "$SC" >/dev/null 2>&1 || _rc=$?
[ "$_rc" = 2 ] && pass "missing --kind -> exit 2 (fail closed)" || fail "missing --kind expected 2, got $_rc"

if [ "$FAILS" -gt 0 ]; then printf '\n265-lifecycle-validation: %d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
printf '\n265-lifecycle-validation: 0 failure(s)\nAll lifecycle-validation assertions passed.\n'
exit 0
