#!/bin/sh
# Sentinel Shield production test — the quality-evidence contract (#204, first PR).
#
# THE DEFECT
#
#     $ echo '{}' > reports/raw/mutation.json
#     $ sh scripts/collectors/mutation.sh --input reports/raw/mutation.json
#     {"status":"pass","violations":null}
#
# An EMPTY OBJECT was a clean quality gate. The collectors read `.violations // 0` and treated
# ABSENCE as a measured zero — as the issue puts it, *a missing count is not equivalent to
# measured zero*.
#
# This is a different shape from #182. There the bare-count object was a shortcut accepted
# ALONGSIDE a native shape, and the fix was to delete the alternative branch. Here there was no
# shape gate at all, so the contract had to be added rather than removed.
#
# TWO CONTRACTS, NOT ONE
#
#   1. a missing count is never a measured zero, and
#   2. CONTRADICTORY EVIDENCE IS INVALID EVIDENCE.
#
# (2) is the subtler half. The collectors read a raw producer `status`, accepted it, and then
# RECOMPUTED the verdict from counts — so a producer could report `pass` while carrying 7
# violations and the contradiction was silently resolved in whichever direction the code
# happened to prefer. That is exploitable: a broken or hostile producer chooses which field
# Sentinel privileges. A contradiction is neither clean evidence nor finding evidence.
#
# LOAD-BEARING PROVENANCE
#
# `scope` and `configuration` are not annotations. Section C proves that changing either
# causes previously-valid evidence to be REJECTED — otherwise they would be decoration, and
# evidence carrying an unchecked config hash is no better than evidence carrying none.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

sha() { { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" || shasum -a 256 "$1"; } 2>/dev/null | awk '{print $1}'; }
# NOT `jq -r '.x // ""'` — `//` substitutes for false as well as null. See #320.
f() { printf '%s' "$1" | jq -r "[$2] | .[0] | if . == null then \"\" else tostring end" 2>/dev/null; }

# All six engineering-quality producers. coverage and diff-coverage joined in #204 PR B;
# before that they were the visible remainder of a partial migration.
TOOLS="mutation complexity duplication dead-code coverage diff-coverage"
mkdir -p "$TMP/reports/raw"

run() { ( cd "$TMP" && sh "$ROOT/scripts/collectors/$1.sh" --input "reports/raw/$1.json" 2>/dev/null ) || true; }
put() { printf '%s\n' "$2" > "$TMP/reports/raw/$1.json"; }

# ===========================================================================
# A. a missing count is never a measured zero
# ===========================================================================
for t in $TOOLS; do
	put "$t" '{}'
	out=$(run "$t")
	if [ "$(f "$out" .status)" = "execution-error" ]; then
		pass "$t: {} is refused — a missing count is not a measured zero"
	else
		fail "$t: {} produced status=$(f "$out" .status) — the #204 defect is back"
	fi
done

# THE CONTROL. Without it, every rejection above is satisfied by a collector that rejects
# everything, including one that is simply broken.
for t in $TOOLS; do
	case "$t" in
	dead-code) put "$t" '{"status":"pass","violations":0,"dead_code_count":0}' ;;
	*) put "$t" '{"status":"pass","violations":0}' ;;
	esac
	out=$(run "$t")
	[ "$(f "$out" .status)" = "pass" ] \
		&& pass "$t: CONTROL — a real report declaring violations:0 still passes" \
		|| fail "$t: CONTROL failed (status=$(f "$out" .status)); the rejections above prove nothing"
done

# ===========================================================================
# B. contradictory evidence is INVALID evidence
# ===========================================================================
# Every case below has all counts present and a producer that completed. Only the
# DISAGREEMENT between the declared status and the derived count distinguishes them.
contra() { # contra <label> <json> <expect-status>
	put mutation "$2"
	out=$(run mutation)
	if [ "$(f "$out" .status)" = "$3" ]; then
		pass "consistency: $1"
	else
		fail "consistency: $1 — expected $3, got $(f "$out" .status)"
	fi
}
contra "violations>0 + raw=findings is valid findings" '{"status":"findings","violations":3}' findings
contra "violations=0 + raw=pass is valid clean"        '{"status":"pass","violations":0}'      pass
contra "violations>0 + raw=PASS is INVALID"            '{"status":"pass","violations":3}'      execution-error
contra "violations=0 + raw=FINDINGS is INVALID"        '{"status":"findings","violations":0}'  execution-error

# EVERY producer, not just mutation. A mutation that bypassed the consistency matrix in
# coverage.sh was caught by tests/prod/269 and MISSED here, because this section only drove
# one collector — the same "the untested path is the one that breaks" shape that let the #310
# observed-execution gate ship dead. Each producer gets both contradiction directions and a
# control.
for _t in $TOOLS; do
	put "$_t" '{"status":"pass","violations":3}'
	[ "$(f "$(run "$_t")" .status)" = "execution-error" ] \
		&& pass "$_t: raw=pass with violations>0 is INVALID" \
		|| fail "$_t: a pass/violations>0 contradiction was resolved into a verdict"
	put "$_t" '{"status":"findings","violations":0}'
	[ "$(f "$(run "$_t")" .status)" = "execution-error" ] \
		&& pass "$_t: raw=findings with zero violations is INVALID" \
		|| fail "$_t: a findings/zero contradiction was resolved into a verdict"
	put "$_t" '{"status":"findings","violations":2}'
	[ "$(f "$(run "$_t")" .status)" = "findings" ] \
		&& pass "$_t: CONTROL — an AGREEING findings report is still findings" \
		|| fail "$_t: CONTROL failed; the two rejections above prove nothing"
done

put mutation '{"status":"pass","violations":3}'
out=$(run mutation)
if [ "$(f "$out" .tool_report.health)" = "inconsistent-evidence" ]; then
	pass "a contradiction is reported as inconsistent-evidence, not resolved into a verdict"
else
	fail "a contradiction was normalized into a result (health=$(f "$out" .tool_report.health))"
fi

# `warn` is deliberately UNMAPPED. No fixture in the repository uses it for these producers, so
# equating it to `findings` would be inventing semantics they have never been shown to hold.
put mutation '{"status":"warn","violations":0}'
out=$(run mutation)
case "$(f "$out" .tool_report.reason)" in
*warn-semantics-undefined*) pass "warn is refused as undefined for this producer, not silently mapped to findings" ;;
*) fail "warn was given a meaning (reason=$(f "$out" .tool_report.reason)) — it must stay unmapped pending the producer inventory" ;;
esac

# ===========================================================================
# C. scope and configuration are LOAD-BEARING, not decoration
# ===========================================================================
put mutation '{"status":"pass","violations":0}'
RPT=$(sha "$TMP/reports/raw/mutation.json")
printf 'threshold: 80\n' > "$TMP/mutation.config.yml"
CFG=$(sha "$TMP/mutation.config.yml")
SCOPE=$(printf 'src/a.php\nsrc/b.php\n' | sort | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')

mkrec() { # mkrec <report-digest> <config-path> <config-digest> <scope-json> <commit>
	jq -n --arg d "$1" --arg cfg "$2" --arg cs "$3" --argjson sc "$4" --arg c "${5:-}" '{
		record: "sentinel-shield/execution-record@1",
		producer: { tool: "mutation" },
		execution: { observed: true, status: "success", completed: true, exit_code: 0,
		             signal: null, timed_out: false, duration_seconds: 2 },
		output: { path: "reports/raw/mutation.json", sha256: $d },
		target: { repository: null, commit: (if $c == "" then null else $c end) },
		scope: $sc,
		configuration: { path: $cfg, sha256: $cs }
	}' > "$TMP/reports/raw/mutation.execution.json"
}
GOODSCOPE=$(jq -n --arg s "$SCOPE" '{paths:["src/a.php","src/b.php"], sha256:$s}')

mkrec "$RPT" "mutation.config.yml" "$CFG" "$GOODSCOPE"
out=$(run mutation)
if [ "$(f "$out" .status)" = "pass" ] && [ -n "$(f "$out" .tool_report.evidence.configuration.sha256)" ]; then
	pass "CONTROL: matching report digest, scope and configuration is accepted and carried in the envelope"
else
	fail "CONTROL: a fully valid quality record was rejected (status=$(f "$out" .status)) — every rejection below would be meaningless"
fi

mkrec "$RPT" "mutation.config.yml" "0000000000000000000000000000000000000000000000000000000000000000" "$GOODSCOPE"
[ "$(f "$(run mutation)" .status)" = "execution-error" ] \
	&& pass "binding: a wrong configuration digest is rejected" \
	|| fail "binding: a wrong configuration digest was accepted — the config hash is decoration"

# The strongest one: the digest is RECOMPUTED from the file, so changing thresholds after the
# run invalidates evidence produced under the old ones.
mkrec "$RPT" "mutation.config.yml" "$CFG" "$GOODSCOPE"
printf 'threshold: 50\n' > "$TMP/mutation.config.yml"
[ "$(f "$(run mutation)" .status)" = "execution-error" ] \
	&& pass "binding: changing the configuration FILE after the run invalidates the evidence" \
	|| fail "binding: a threshold change did not invalidate prior evidence"
printf 'threshold: 80\n' > "$TMP/mutation.config.yml"

mkrec "0000000000000000000000000000000000000000000000000000000000000000" "mutation.config.yml" "$CFG" "$GOODSCOPE"
[ "$(f "$(run mutation)" .status)" = "execution-error" ] \
	&& pass "binding: a stale execution record (report digest mismatch) is rejected" \
	|| fail "binding: stale output was accepted"

mkrec "$RPT" "mutation.config.yml" "$CFG" '{"paths":[],"sha256":""}'
[ "$(f "$(run mutation)" .status)" = "execution-error" ] \
	&& pass "binding: an empty analyzed scope is rejected — analyzing nothing is not measuring zero" \
	|| fail "binding: an empty scope was accepted"

mkrec "$RPT" "mutation.config.yml" "$CFG" "$GOODSCOPE" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
out=$( cd "$TMP" && GITHUB_REPOSITORY=a/b GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
	sh "$ROOT/scripts/collectors/mutation.sh" --input reports/raw/mutation.json 2>/dev/null || true )
[ "$(f "$out" .status)" = "execution-error" ] \
	&& pass "binding: a record produced for a different commit is rejected" \
	|| fail "binding: a record from another commit was accepted"

mkrec "$RPT" "mutation.config.yml" "$CFG" "$GOODSCOPE"
out=$(run mutation)
if [ "$(f "$out" .status)" = "pass" ]; then
	pass "CONTROL: restoring the valid record makes it pass again (the rejections are attributable)"
else
	fail "CONTROL: the valid record no longer passes after the binding tests"
fi

# ===========================================================================
# D. the envelope is EXTENDED, not forked
# ===========================================================================
out=$(run mutation)
if [ "$(f "$out" .tool_report.evidence.envelope)" = "sentinel-shield/normalized-evidence@1" ]; then
	pass "quality evidence uses the SHARED envelope contract, not a second one"
else
	fail "quality evidence declares envelope='$(f "$out" .tool_report.evidence.envelope)' — #204 must extend the #182/#310 core, not fork it"
fi
for k in producer source target execution trust; do
	if [ -n "$(f "$out" ".tool_report.evidence.$k")" ]; then
		pass "envelope carries the shared core field '$k'"
	else
		fail "envelope is missing the shared core field '$k'"
	fi
done
if [ -n "$(f "$out" .tool_report.evidence.quality.violations)" ]; then
	pass "envelope carries the quality payload above the core"
else
	fail "envelope carries no quality payload"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d quality-evidence check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nquality-evidence: OK (missing count != measured zero; contradictions are invalid; scope and config are load-bearing)\n'
exit 0
