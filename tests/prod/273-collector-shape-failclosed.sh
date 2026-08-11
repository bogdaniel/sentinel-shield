#!/bin/sh
# Sentinel Shield prod test — collectors fail CLOSED on a valid-JSON but unrecognized report
# shape (a scanner error object), and still PASS on a well-typed clean/empty report.
#
# ss_collector_guard already rejects missing/empty input (unavailable) and invalid JSON
# (exit 2). The gap this guards: a scanner that emits VALID JSON of the wrong shape (e.g.
# `{"error":"boom"}`) must not coerce to 0 findings and silently clear a security gate.
#
# For each hardened collector: feed a malformed-but-valid-JSON fixture -> expect exit 2;
# feed a well-typed clean fixture -> expect exit 0 and status "pass".
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COLLECTORS="$ROOT/scripts/collectors"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss273)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

# Malformed-but-valid JSON that must NOT be read as a clean pass.
BAD="$WORK/bad.json"; printf '%s' '{"error":"scanner crashed"}' > "$BAD"

# collector | clean-empty fixture that MUST pass.
# (One line per hardened collector; clean fixture matches the tool's real empty output.)
run_case() {
	_c="$1"; _clean="$2"
	_script="$COLLECTORS/$_c.sh"
	[ -f "$_script" ] || { fail "$_c: collector script missing"; return; }

	# (1) malformed shape -> fail closed via status=execution-error (NOT a clean pass).
	# Emitting execution-error + exit 0 (rather than a hard exit 2) keeps the tool fail-closed
	# — a REQUIRED tool with execution-error fails the gate in enforce-gates — while letting
	# build-security-summary aggregate the rest of the run instead of aborting the whole summary.
	_st=$(sh "$_script" --input "$BAD" 2>/dev/null | jq -r '.status // "MISSING"' 2>/dev/null)
	[ "$_st" = "execution-error" ] && pass "$_c: malformed -> execution-error (fail closed)" \
		|| fail "$_c: malformed -> status '$_st' (want execution-error)"

	# (2) well-typed clean report -> pass
	_cf="$WORK/clean-$_c.json"; printf '%s' "$_clean" > "$_cf"
	_st=$(sh "$_script" --input "$_cf" 2>/dev/null | jq -r '.status // "MISSING"' 2>/dev/null)
	case "$_st" in
		pass|fail) pass "$_c: clean-empty -> $_st (not a false error)" ;;
		*) fail "$_c: clean-empty report -> status '$_st' (over-aggressive fail-closed)" ;;
	esac
}

run_case actionlint            '[]'
run_case hadolint              '[]'
run_case psalm                 '[]'
run_case phpstan               '{"totals":{"errors":0,"file_errors":0}}'
run_case dockle                '{"summary":{},"details":[]}'
run_case conftest              '[]'
run_case nuclei                '[]'
run_case zap                   '{"site":[]}'
run_case terrascan             '{"results":{"violations":[]}}'
run_case third-party-semgrep   '{"results":[],"errors":[]}'
run_case dependency-policy     '{"count":0}'

# --- the canonical summary-key boundary (#327 phantom-gate class) -----------------------
#
# ss_emit_collector merges the caller's overrides straight into the summary. A MISSPELLED
# key is therefore not a no-op: it invents a summary field no gate reads, while the real
# gating key keeps its zeroed default — so an execution-error path reports a clean count.
# The defect that motivated this shipped in a #204 PR as `diff_coverage_violations` for
# `changed_lines_coverage_violations`, and every existing test still passed.
#
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"

SCHEMA="$ROOT/schemas/security-summary.schema.json"

# (A) The in-shell list and the schema must be the SAME set — the list is duplicated for
# runtime independence, so drift in either direction has to be a CI failure, not a surprise.
if [ -f "$SCHEMA" ]; then
	printf '%s' "$SS_SUMMARY_KEYS" | tr ' ' '\n' | grep . | sort > "$WORK/keys-lib.txt"
	jq -r '.properties.summary.properties | keys[]' "$SCHEMA" | sort > "$WORK/keys-schema.txt"
	if cmp -s "$WORK/keys-lib.txt" "$WORK/keys-schema.txt"; then
		pass "SS_SUMMARY_KEYS is exactly the schema's summary key set ($(grep -c . "$WORK/keys-lib.txt") keys)"
	else
		fail "SS_SUMMARY_KEYS differs from the schema: only-in-lib=[$(comm -23 "$WORK/keys-lib.txt" "$WORK/keys-schema.txt" | tr '\n' ' ')] only-in-schema=[$(comm -13 "$WORK/keys-lib.txt" "$WORK/keys-schema.txt" | tr '\n' ' ')]"
	fi
	# The schema must keep refusing unknown summary fields; without that, the list above is
	# guarding a door that the schema leaves open.
	[ "$(jq -r '.properties.summary.additionalProperties' "$SCHEMA")" = "false" ] \
		&& pass "schema summary still declares additionalProperties:false" \
		|| fail "schema summary no longer declares additionalProperties:false"
else
	fail "security-summary schema not found at $SCHEMA"
fi

# (B) An unknown override key is a HARD failure, not a silently-merged phantom field.
_out=$(ss_emit_collector probe pass '{}' '{"diff_coverage_violations":1}' 2>/dev/null) && _rc=0 || _rc=$?
if [ "$_rc" -ne 0 ] && [ -z "$_out" ]; then
	pass "unknown summary override key is rejected (rc=$_rc, no object emitted)"
else
	fail "unknown summary override key was accepted (rc=$_rc, output='$_out') — phantom gate"
fi

# (C) CONTROL: the correctly-spelled key on the SAME call site is accepted and lands in the
# summary. Without this, (B) could be passing because the emitter is broken outright.
_out=$(ss_emit_collector probe pass '{}' '{"changed_lines_coverage_violations":1}' 2>/dev/null) && _rc=0 || _rc=$?
if [ "$_rc" -eq 0 ] && [ "$(printf '%s' "$_out" | jq -r '.summary.changed_lines_coverage_violations')" = "1" ]; then
	pass "CONTROL: the canonical key is accepted and reaches .summary"
else
	fail "CONTROL: the canonical key was not accepted (rc=$_rc) — (B) is unattributable"
fi

# (D) CONTROL: no overrides at all still emits a well-formed collector object.
_out=$(ss_emit_collector probe pass '{}' '{}' 2>/dev/null) && _rc=0 || _rc=$?
[ "$_rc" -eq 0 ] && [ "$(printf '%s' "$_out" | jq -r '.tool')" = "probe" ] \
	&& pass "CONTROL: empty overrides still emit a collector object" \
	|| fail "CONTROL: empty overrides broke the emitter (rc=$_rc)"

# (E) A non-object override is rejected rather than crashing jq or merging as an array.
_out=$(ss_emit_collector probe pass '{}' '[]' 2>/dev/null) && _rc=0 || _rc=$?
[ "$_rc" -ne 0 ] && [ -z "$_out" ] \
	&& pass "non-object summary overrides are rejected" \
	|| fail "non-object summary overrides were accepted (rc=$_rc)"

# (F) End-to-end: every collector's real emitted summary contains ONLY canonical keys. This
# is the check that would have caught #327 — (B) proves the boundary rejects, (F) proves no
# shipped collector is relying on a non-canonical key.
_nc=0
for _s in "$COLLECTORS"/*.sh; do
	_n=$(basename "$_s" .sh)
	_o=$(sh "$_s" --input "$WORK/nonexistent-$_n.json" 2>/dev/null) || continue
	printf '%s' "$_o" | jq -e 'type == "object" and has("summary")' >/dev/null 2>&1 || continue
	_bad=$(printf '%s' "$_o" | jq -r --arg c "$SS_SUMMARY_KEYS" \
		'.summary | keys - ($c | split(" ") | map(select(length > 0))) | .[]' 2>/dev/null)
	[ -n "$_bad" ] && { fail "$_n: emits non-canonical summary key(s): $(printf '%s' "$_bad" | tr '\n' ' ')"; _nc=1; }
done
[ "$_nc" -eq 0 ] && pass "no collector emits a non-canonical summary key on its unavailable path"

[ "$FAILED" -eq 0 ] && printf '\n273-collector-shape-failclosed: 0 failure(s)\nAll collector fail-closed assertions passed.\n' || {
	printf '\n273-collector-shape-failclosed: FAILURES above.\n'; exit 1; }
