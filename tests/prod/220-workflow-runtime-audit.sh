#!/bin/sh
# Sentinel Shield production test — workflow-runtime hardening gate (NN=220).
#
# Exercises scripts/audits/workflow-runtime-audit.sh, the fail-closed gate that
# asserts, across .github/workflows/*.yml AND templates/workflows/*.yml:
#   - uses-sha-pin                        every uses: is a full 40-hex SHA
#   - job-permissions                     every job runs under explicit permissions
#   - job-timeout                         every job sets timeout-minutes
#   - workflow-concurrency                the workflow sets a concurrency group
#   - upload-artifact-if-no-files-found   every upload-artifact sets if-no-files-found
#
# POSITIVE: the shipped workflows/templates must pass clean (exit 0, status=pass).
# NEGATIVE: purpose-built fixtures under tests/fixtures/workflows/ must each trip
# EXACTLY their intended check (a skip is not a pass — we assert the specific
# check id fires and the exit code is non-zero).
# SCHEMA: the emitted JSON must match schemas/workflow-runtime-audit.schema.json
# structurally (required keys, types, enum membership).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/audits/workflow-runtime-audit.sh"
FX="$ROOT/tests/fixtures/workflows"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

[ -x "$AUDIT" ] || fail "audit script not executable: $AUDIT"

# --- POSITIVE: shipped workflows pass clean ---------------------------------
OUT_POS="$WORK/positive.json"
if ( cd "$ROOT" && sh "$AUDIT" --output "$OUT_POS" >/dev/null 2>&1 ); then
	if [ "$(jq -r '.status' "$OUT_POS")" = "pass" ] \
		&& [ "$(jq '.violation_count' "$OUT_POS")" = "0" ]; then
		pass "shipped .github/workflows + templates/workflows pass clean"
	else
		fail "shipped workflows: status/violation_count not clean -> $(jq -c '{status,violation_count}' "$OUT_POS")"
	fi
else
	fail "shipped workflows: audit exited non-zero -> $(jq -c '.violations' "$OUT_POS" 2>/dev/null || echo '?')"
fi

# --- POSITIVE control fixture -----------------------------------------------
OUT_GOOD="$WORK/good.json"
if sh "$AUDIT" "$FX/good.yml" --output "$OUT_GOOD" >/dev/null 2>&1; then
	[ "$(jq '.violation_count' "$OUT_GOOD")" = "0" ] \
		&& pass "good.yml fixture: zero violations" \
		|| fail "good.yml fixture: expected zero violations, got $(jq '.violation_count' "$OUT_GOOD")"
else
	fail "good.yml fixture: audit exited non-zero (should be clean)"
fi

# --- NEGATIVE: each bad fixture trips exactly its check ----------------------
# "fixture-basename expected-check"
check_negative() {
	_fx=$1; _want=$2
	_out="$WORK/$_fx.json"
	if sh "$AUDIT" "$FX/$_fx.yml" --output "$_out" >/dev/null 2>&1; then
		fail "$_fx.yml: audit exited 0 but a violation was expected ($_want)"
		return
	fi
	# non-zero exit (fail-closed) confirmed; assert the intended check fired and
	# is the ONLY check tripped (fixtures are single-defect by construction).
	_got=$(jq -r '[.violations[].check] | unique | join(",")' "$_out")
	if [ "$_got" = "$_want" ]; then
		pass "$_fx.yml: fail-closed on '$_want'"
	else
		fail "$_fx.yml: expected only '$_want', got '[$_got]'"
	fi
}

check_negative bad-mutable-ref               uses-sha-pin
check_negative bad-missing-permissions       job-permissions
check_negative bad-missing-timeout           job-timeout
check_negative bad-missing-if-no-files-found upload-artifact-if-no-files-found
check_negative bad-missing-concurrency       workflow-concurrency

# --- SCHEMA conformance of the emitted report -------------------------------
SCHEMA="$ROOT/schemas/workflow-runtime-audit.schema.json"
if [ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1; then
	pass "schema is present and jq-valid"
else
	fail "schema missing or not jq-valid: $SCHEMA"
fi

# Structural validation of the positive report against the schema's contract:
# every required top-level key present, checks enum has all 5 ids, correct types.
if jq -e '
	(["version","generated_at","tool","files_scanned","checks","status","violation_count","violations"]
	   | all(. as $k | ($in|has($k)))) as $keys
	| $keys
	and ($in.tool == "workflow-runtime-audit")
	and (($in.checks|sort) == ["job-permissions","job-timeout","upload-artifact-if-no-files-found","uses-sha-pin","workflow-concurrency"])
	and ($in.status == "pass")
	and ($in.files_scanned|type == "number")
	and ($in.violation_count == 0)
	and ($in.violations|type == "array")
' --argjson in "$(cat "$OUT_POS")" -n >/dev/null 2>&1; then
	pass "positive report conforms to schema contract"
else
	fail "positive report does not conform to schema contract"
fi

# Also assert a failing report conforms (violation objects well-formed).
if jq -e '
	.violations|length>0 and all(
		has("file") and has("line") and has("job") and has("check") and has("ref") and has("message")
		and (.check=="uses-sha-pin") and (.ref|length>0))
' "$WORK/bad-mutable-ref.json" >/dev/null 2>&1; then
	pass "failing report (bad-mutable-ref) has well-formed violation objects with ref set"
else
	fail "failing report (bad-mutable-ref) violation objects malformed"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
