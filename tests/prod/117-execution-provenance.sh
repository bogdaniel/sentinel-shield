#!/bin/sh
# Sentinel Shield production test — execution provenance (#310).
#
# THE INVARIANT: a parseable report is NOT a completed scan.
#
# #182 shipped `execution: { completed: true, exit_code: 0 }` as a CONSTANT. The collector
# concluded the scanner had completed because it was handed a parseable report, and never
# observed the process. A scanner that exits non-zero, times out, or is killed while leaving
# syntactically valid JSON was recorded as a clean, complete execution over a report
# describing less than the full target.
#
# scripts/audits/dependency-check.sh stated the problem in its own comment:
#
#     [ "$rc" -eq 0 ] || echo "dependency-check exited $rc but produced valid JSON
#         — kept for the collector/gate to decide."
#
# It deferred the decision to the collector and then discarded the one fact needed to make it.
#
# THIS SUITE ALSO CARRIES THE DYNAMIC REGRESSION #182 LACKED. tests/prod/116 section 7 asserted
# the enforcing-mode refusal of non-production evidence by GREPPING enforce-gates.sh for the
# condition. A static assertion that the code contains a check is not proof the check fires —
# it is the same "guard that has never rejected anything" shape this programme keeps finding.
# Section B below actually RUNS enforce-gates.sh against generated summaries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$ROOT/scripts/lib/normalized-evidence.sh" ] || { fail "normalized-evidence.sh is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

sha() { { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" || shasum -a 256 "$1"; } 2>/dev/null | awk '{print $1}'; }

NATIVE='{"matches":[{"vulnerability":{"severity":"HIGH"}}]}'

# run_grype — collect over $TMP/reports/raw/grype.json, print the tool JSON.
run_grype() { ( cd "$TMP" && sh "$ROOT/scripts/collectors/grype.sh" --input reports/raw/grype.json 2>/dev/null ) || true; }
# NOT `jq -r "$2 // \"\""`. jq's `//` substitutes for null AND FALSE, so `observed: false`
# came back as the empty string and the unobserved case looked like a missing field. Same
# operator family as #285 defect 1, where `.conclusion // "pending"` swallowed an empty
# string. Distinguish null explicitly instead.
f() { printf '%s' "$1" | jq -r "[$2] | .[0] | if . == null then \"\" else tostring end" 2>/dev/null; }

# mkrec <status> <digest> <exit-code> [tool] [commit]
mkrec() {
	jq -n --arg s "$1" --arg d "$2" --arg ec "${3:-}" --arg t "${4:-grype}" --arg c "${5:-}" '{
		record: "sentinel-shield/execution-record@1",
		producer: { tool: $t },
		execution: { observed: true, status: $s, completed: ($s == "success"),
		             exit_code: (if $ec == "" then null else ($ec|tonumber) end),
		             signal: (if $s == "signalled" then 9 else null end),
		             timed_out: ($s == "timed-out"), duration_seconds: 1 },
		output: { path: "reports/raw/grype.json", sha256: $d },
		target: { repository: null, commit: (if $c == "" then null else $c end) }
	}' > "$TMP/reports/raw/grype.execution.json"
}

mkdir -p "$TMP/reports/raw"
printf '%s\n' "$NATIVE" > "$TMP/reports/raw/grype.json"
D=$(sha "$TMP/reports/raw/grype.json")

# ===========================================================================
# A. the collector-level contract
# ===========================================================================

# A1 — the control. Without it every rejection below is satisfied by a collector that
# rejects everything, including one that is simply broken.
mkrec success "$D" 0
out=$(run_grype)
if [ "$(f "$out" .tool_report.evidence.execution.completed)" = "true" ] \
	&& [ "$(f "$out" .tool_report.evidence.execution.observed)" = "true" ] \
	&& [ "$(f "$out" .status)" = "fail" ]; then
	pass "CONTROL: exit 0 + matching digest is accepted, observed and completed"
else
	fail "CONTROL: a valid execution record was not accepted (status=$(f "$out" .status) observed=$(f "$out" .tool_report.evidence.execution.observed))"
fi

# A2 — non-zero exit with a valid-looking partial report. The reported defect.
mkrec failed "$D" 3
out=$(run_grype)
if [ "$(f "$out" .status)" = "execution-error" ]; then
	pass "non-zero exit with a valid partial report is refused"
else
	fail "a scanner that exited 3 was normalized as \"$(f "$out" .status)\" — a parseable report is not a completed scan"
fi

# A3 — timeout.
mkrec timed-out "$D" ""
out=$(run_grype)
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "a timed-out scan with a valid partial report is refused" \
	|| fail "a timed-out scan was normalized as \"$(f "$out" .status)\""

# A4 — killed / OOM-equivalent.
mkrec signalled "$D" ""
out=$(run_grype)
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "a signalled (killed / OOM-equivalent) scan is refused" \
	|| fail "a signalled scan was normalized as \"$(f "$out" .status)\""

# A5 — STALE OUTPUT: a successful record whose digest describes an earlier report.
# This is the pairing the issue calls out — yesterday's success beside today's failure.
mkrec success "$D" 0
printf '%s\n' '{"matches":[]}' > "$TMP/reports/raw/grype.json"   # report changes, record does not
out=$(run_grype)
if [ "$(f "$out" .status)" = "execution-error" ]; then
	pass "a successful record paired with a CHANGED report is refused (stale output)"
else
	fail "stale output was accepted (status=$(f "$out" .status)) — the digest binding is not enforced"
fi
printf '%s\n' "$NATIVE" > "$TMP/reports/raw/grype.json"

# A6 — outright digest mismatch.
mkrec success "0000000000000000000000000000000000000000000000000000000000000000" 0
out=$(run_grype)
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "a record whose digest does not match the report is refused" \
	|| fail "a digest mismatch was accepted"

# A7 — a record for another tool.
mkrec success "$D" 0 "trivy"
out=$(run_grype)
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "an execution record naming a DIFFERENT tool is refused" \
	|| fail "a record for another tool was accepted"

# A8 — a record produced against another commit.
mkrec success "$D" 0 "grype" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
out=$( cd "$TMP" && GITHUB_REPOSITORY=a/b GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
	sh "$ROOT/scripts/collectors/grype.sh" --input reports/raw/grype.json 2>/dev/null || true )
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "an execution record from a DIFFERENT commit is refused" \
	|| fail "a record from another commit was accepted"

# A9 — no record at all: UNOBSERVED, never a confident success.
rm -f "$TMP/reports/raw/grype.execution.json"
out=$(run_grype)
if [ "$(f "$out" .tool_report.evidence.execution.observed)" = "false" ] \
	&& [ "$(f "$out" .tool_report.evidence.execution.completed)" = "" ]; then
	pass "a missing execution record yields observed=false and completed=null, not success"
else
	fail "a missing record produced observed=$(f "$out" .tool_report.evidence.execution.observed) completed=$(f "$out" .tool_report.evidence.execution.completed) — it must never default to success"
fi

# A9b — NON-ZERO EXIT WITH NO REPORT AT ALL.
#
# Required verbatim by this issue's acceptance criteria ("non-zero exit with no report") and
# missing from the original suite. I closed #310 twice partly on this gap: the second time I
# audited criterion 5 as a whole rather than item by item, and this case is the item that was
# not there. The implementation was almost certainly correct — but a criterion demanding a test
# is not satisfied by reasoning about the behaviour.
#
# The scanner failed AND left nothing behind. There is no report to normalize, so the collector
# must report unavailable/execution-error. What it must never do is reach a pass/findings
# verdict, and it must never claim a completed execution over a report that does not exist.
rm -f "$TMP/reports/raw/grype.json"
mkrec failed "" 3          # a record describing the failed run; the report it names is absent
out=$(run_grype)
_st=$(f "$out" .status)
case "$_st" in
unavailable | execution-error)
	pass "a non-zero exit that produced NO report is $_st, not a verdict"
	;;
*)
	fail "a non-zero exit with no report produced status=$_st — a scan that wrote nothing is not a result"
	;;
esac
if [ "$(f "$out" .tool_report.evidence.execution.completed)" != "true" ] \
	&& [ "$(f "$out" .status)" != "pass" ] && [ "$(f "$out" .status)" != "findings" ]; then
	pass "a non-zero exit with no report never claims completed execution or a clean/finding verdict"
else
	fail "a missing report was credited with completion or a verdict (status=$_st completed=$(f "$out" .tool_report.evidence.execution.completed))"
fi

# The CONTROL for A9b. Restore the report and a matching record: the same collector, the same
# code path, must reach a normal verdict — otherwise the two assertions above are satisfied by
# a collector that refuses everything once a file has been deleted.
printf '%s\n' "$NATIVE" > "$TMP/reports/raw/grype.json"
D=$(sha "$TMP/reports/raw/grype.json")
mkrec success "$D" 0
out=$(run_grype)
if [ "$(f "$out" .status)" = "fail" ] && [ "$(f "$out" .tool_report.evidence.execution.completed)" = "true" ]; then
	pass "A9b CONTROL: exit 0 + valid report + matching record still reaches its normal verdict"
else
	fail "A9b CONTROL: the restored valid case did not reach its normal verdict (status=$(f "$out" .status)) — the two assertions above prove nothing"
fi

# A10 — the envelope must no longer carry the #182 constant.
if grep -vE '^[[:space:]]*#' "$ROOT/scripts/lib/normalized-evidence.sh" | grep -q 'completed: true, exit_code: 0'; then
	fail "ne_envelope still hardcodes {completed:true, exit_code:0} — the #182 constant is back"
else
	pass "ne_envelope no longer hardcodes a completed execution"
fi

# ===========================================================================
# B. the DYNAMIC enforcing-mode regression (the gap in 116 section 7)
# ===========================================================================
# 116 asserted this by grepping enforce-gates.sh. A static assertion that the code contains a
# condition is not proof the condition fires. These actually run the enforcer.
if [ ! -x "$ENFORCE" ] && [ ! -f "$ENFORCE" ]; then
	fail "enforce-gates.sh not found; the dynamic regression cannot run"
else
	mkdir -p "$TMP/g"
	# gate <summary> <mode> — resolve gates for <mode>, enforce, echo the exit code.
	gate() {
		sh "$RESOLVE" --mode "$2" --output-dir "$TMP/g" --format env >/dev/null 2>&1 || true
		sh "$ENFORCE" --gates-env "$TMP/g/sentinel-shield-gates.env" --summary "$1" \
			--output-dir "$TMP/g" --format json >/dev/null 2>&1 && printf 0 || printf '%s' "$?"
	}

	# Both summaries are built by the REAL builder from a real collector report, then differ by
	# exactly one field: the non-production label. Hand-writing the JSON was tried first and was
	# the wrong call — it meant chasing schema requirements one error at a time, and a summary
	# rejected for a missing field would have looked exactly like a summary rejected for the
	# label, which is precisely what the control exists to distinguish.
	#
	# All counts are ZERO in both. If the refusal keyed on counts rather than the label, the two
	# would be indistinguishable.
	BUILD="$ROOT/scripts/build-security-summary.sh"
	FIXTURE_COMMIT=0123456789abcdef0123456789abcdef01234567
	mkdir -p "$TMP/e/raw" "$TMP/e/rep"
	printf '%s\n' '{"matches":[]}' > "$TMP/e/raw/grype.json"
	sh "$BUILD" --raw-dir "$TMP/e/raw" --output "$TMP/production-summary.json" \
		--project-name t --commit "$FIXTURE_COMMIT" >/dev/null 2>&1 || true
	if [ ! -s "$TMP/production-summary.json" ]; then
		fail "DYNAMIC: could not build a baseline summary; the dynamic regression cannot run"
	else
		# The fixture summary is the production one plus the label — one field of difference.
		jq '.tools |= with_entries(.value += {non_production: true})' \
			"$TMP/production-summary.json" > "$TMP/fixture-summary.json"

		for m in baseline strict regulated; do
			rc=$(gate "$TMP/fixture-summary.json" "$m")
			if [ "$rc" != "0" ]; then
				pass "DYNAMIC: enforce-gates --mode $m REJECTS an all-zero fixture summary (exit $rc)"
			else
				fail "DYNAMIC: enforce-gates --mode $m ACCEPTED non-production evidence — all counts were zero, so only the label could catch it"
			fi
		done

	# The control. Without it, three rejections prove nothing: an enforcer that refuses every
	# summary would satisfy them all.
		rc=$(gate "$TMP/production-summary.json" baseline)
		if [ "$rc" = "0" ]; then
			pass "DYNAMIC CONTROL: the same summary WITHOUT the non-production label is accepted"
		else
			fail "DYNAMIC CONTROL: a production summary was rejected (exit $rc) — the three rejections above are therefore meaningless"
		fi
	fi
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d execution-provenance check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nexecution-provenance: OK (parseable report != completed scan; enforcing modes proven dynamically)\n'
exit 0
