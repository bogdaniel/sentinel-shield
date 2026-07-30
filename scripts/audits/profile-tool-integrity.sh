#!/bin/sh
# Sentinel Shield audit — profile tool integrity.
#
# Enforces the invariant that makes a profile recommendation MEAN something:
#
#   No profile may recommend, require, or declare a tool key unless that key resolves to
#   an implemented evidence contract — a TOOL_TABLE row, a declared report that TOOL_TABLE
#   collects, or execution by an installed workflow template.
#
# This exists because the repo shipped two classes of silent hole:
#
#   1. `grype-fs` and `trivy-image` were recommended by eight and two profiles with NO
#      TOOL_TABLE row, NO .tools entry, NO runner, NO collector and NO workflow step. They
#      named scanners that nothing anywhere could run.
#   2. Worse: `pint`, `larastan`, `php-cs-fixer`, `phpstan-symfony` and `syft` DID run and
#      DID write reports, several as `missing_behavior: fail` — but their raw filenames had
#      no TOOL_TABLE row, so build-security-summary never read them. Their presence was
#      gated and their contents were invisible. A pint.json listing violations and a
#      larastan.json with 47 errors produced an all-zero summary.
#
# Fails closed: an unresolvable key is an error, never a skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
# Failures are recorded in a FILE, not a shell variable. Every check below reads its
# input from a pipeline, and `cmd | while read ...; do FAILED=1; done` runs the loop body
# in a SUBSHELL, so the assignment is discarded the moment the loop ends. The first draft
# of this audit did exactly that: it printed FAIL lines, then exited 0 announcing "ALL
# CHECKS PASSED" — a fail-open audit, the same defect class it exists to detect.
FAILFILE=$(mktemp)
trap 'rm -f -- "$FAILFILE"' EXIT INT TERM
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; printf 'x\n' >> "$FAILFILE"; }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required\n'; exit 1; }

BUILDER="scripts/build-security-summary.sh"
[ -f "$BUILDER" ] || { printf 'FAIL: missing %s\n' "$BUILDER"; exit 1; }

# Extract TOOL_TABLE columns 1 (key) and 2 (raw filename) from the builder. The table is a
# '|'-delimited DATA string, so it is parsed, never sourced.
_tbl=$(sed -n "/^TOOL_TABLE='/,/'\$/p" "$BUILDER" | sed "s/^TOOL_TABLE='//; s/'\$//")
CANON_KEYS=$(printf '%s\n' "$_tbl" | awk -F'|' 'NF>=4 && $1!=""{print $1}' | sort -u)
CANON_RAW=$(printf '%s\n' "$_tbl" | awk -F'|' 'NF>=4 && $2!=""{print $2}' | sort -u)

if [ -z "$CANON_KEYS" ]; then
	printf 'FAIL: parsed 0 rows from TOOL_TABLE — the audit would pass vacuously\n'
	exit 1
fi
pass "TOOL_TABLE parsed ($(printf '%s\n' "$CANON_KEYS" | grep -c .) canonical keys)"

# has_line <haystack> <needle> — exact whole-line match.
has_line() { printf '%s\n' "$1" | grep -qxF "$2"; }

# workflow_runs <key> <manifest>
# True when the profile's OWN installed workflow templates invoke <key> as a tool.
#
# The first version was `grep -rql -- "$key" templates/workflows/`, which was wrong twice
# over: it scanned EVERY template (so a profile passed because some other profile's
# workflow mentioned the key) and it matched any SUBSTRING (so the bogus keys `gryp`,
# `scorecar` and `tes` all resolved against grype/scorecard/tests and the audit reported
# a clean repo). A permissive resolver in a fail-closed audit is a false negative factory.
#
# Now: read the workflow sources from the manifest being checked, and require the key to
# appear as an actual invocation token — a runner/collector script name, a raw report
# filename, or a whole-word occurrence — not an arbitrary substring.
workflow_runs() {
	_wr_key=$1
	_wr_manifest=$2
	_wr_srcs=$(jq -r '[(.workflows // [])[] | .source] | .[]?' "$_wr_manifest" 2>/dev/null)
	[ -n "$_wr_srcs" ] || return 1
	for _wr_s in $_wr_srcs; do
		_wr_f="templates/$_wr_s"
		[ -f "$_wr_f" ] || _wr_f="$_wr_s"
		[ -f "$_wr_f" ] || continue
		# An invocation looks like `runners/<key>.sh`, `collectors/<key>.sh`,
		# `<key>.json`, or the key as a standalone word (e.g. a `tool: <key>` input).
		if grep -qE "(runners/${_wr_key}\.sh|collectors/${_wr_key}\.sh|[/\"' ]${_wr_key}\.json|[[:<:]]${_wr_key}[[:>:]])" "$_wr_f" 2>/dev/null; then
			return 0
		fi
		# BSD/GNU word-boundary syntax differs; retry with the GNU spelling.
		if grep -qE "(runners/${_wr_key}\.sh|collectors/${_wr_key}\.sh|[/\"' ]${_wr_key}\.json|\\b${_wr_key}\\b)" "$_wr_f" 2>/dev/null; then
			return 0
		fi
	done
	return 1
}

for f in profiles/*/profile.manifest.json profiles/combinations/*.manifest.json; do
	[ -f "$f" ] || continue
	prof=$(jq -r '.profile // "?"' "$f")

	# 1. Every DECLARED tool's report must be collected by TOOL_TABLE. This is the check
	#    that catches evidence written and never read.
	jq -r '(.tools // {}) | to_entries[] | select(.value.report) | "\(.key)\t\(.value.report)\t\(.value.missing_behavior // "-")"' "$f" \
	| while IFS="$(printf '\t')" read -r key report mb; do
		base=${report##*/}
		if has_line "$CANON_RAW" "$base"; then
			continue
		fi
		fail "$prof: tool '$key' writes '$base' (missing_behavior=$mb) but no TOOL_TABLE row collects it — its contents can never reach the summary"
	done

	# 2. Every RECOMMENDED key must resolve: canonical key, or a declared tool, or a tool
	#    the profile's own installed workflow actually runs.
	jq -r '((.recommended_pr_fast_tools // []) + (.recommended_main_gate_tools // []) + (.recommended_scheduled_tools // []))[]' "$f" \
	| sort -u | while read -r key; do
		[ -n "$key" ] || continue
		has_line "$CANON_KEYS" "$key" && continue
		jq -e --arg k "$key" '(.tools // {}) | has($k)' "$f" >/dev/null 2>&1 && continue
		workflow_runs "$key" "$f" && continue
		fail "$prof: recommends '$key', which resolves to no TOOL_TABLE row, no declared tool, and no workflow step"
	done

	# 2b. A recommendation is stage-scoped, so it must agree with the stage it names.
	#     `dependency-check` declared `execution.main: false` — with a note saying it is a
	#     SCHEDULED-stage tool because requiring it at main made a fresh install exit 3 for a
	#     missing producer — while every profile still listed it under
	#     recommended_main_gate_tools. A consumer following that advice wires a main-gate
	#     producer the plan never invokes there, and reads the result as main-gate coverage.
	#
	#     The tool must therefore either be SELECTED at that stage, or actually be RUN by a
	#     workflow for that stage. ponytail: the stage's workflow is identified by the stage
	#     token in its filename, plus the combined template that serves every stage. If the
	#     shipped template names ever stop carrying the stage token, tighten this to the
	#     canonical map in verify-producer-coverage.sh rather than loosening the rule.
	for _stage in pr main scheduled; do
		case "$_stage" in
			pr) _rkey=recommended_pr_fast_tools; _tok=pr-fast ;;
			main) _rkey=recommended_main_gate_tools; _tok=main ;;
			scheduled) _rkey=recommended_scheduled_tools; _tok=scheduled ;;
		esac
		for _rt in $(jq -r --arg k "$_rkey" '(.[$k] // [])[]' "$f" 2>/dev/null); do
			[ -n "$_rt" ] || continue
			# Selected at this stage by the profile itself: nothing to reconcile.
			_sel=$(jq -r --arg t "$_rt" --arg s "$_stage" '
				if ((.tools // {}) | has($t) | not) then "undeclared"
				elif ((.tools[$t].execution // {}) | has($s) | not) then "unset"
				else (.tools[$t].execution[$s] | tostring) end' "$f" 2>/dev/null)
			[ "$_sel" = "false" ] || continue
			# Not selected — then some workflow for THIS stage must run it.
			_ran=0
			for _wsrc in $(jq -r '[(.workflows // [])[] | .source] | .[]?' "$f" 2>/dev/null); do
				case "$_wsrc" in *"$_tok"* | */sentinel-shield.yml) ;; *) continue ;; esac
				_wf="templates/$_wsrc"; [ -f "$_wf" ] || _wf="$_wsrc"; [ -f "$_wf" ] || continue
				if grep -qE "(runners/${_rt}\.sh|collectors/${_rt}\.sh|audits/${_rt}\.sh|[/\"' ]${_rt}\.json)" "$_wf" 2>/dev/null; then
					_ran=1; break
				fi
			done
			[ "$_ran" -eq 1 ] || fail "$prof: $_rkey recommends '$_rt', but the profile sets execution.$_stage=false for it and no $_stage workflow runs it — following that advice wires a producer the plan never invokes at $_stage"
		done
	done

	# 3. Every DECLARED key must resolve too — including entries with no `report`.
	#    Check 1 only inspects report-bearing tools, so a declared key with no report was
	#    validated by nothing at all: a bogus `.tools` entry passed the whole audit. A
	#    declared tool is a stronger claim than a recommendation and must resolve at least
	#    as strictly. Producers legitimately have no report of their own (they write into
	#    another tool's, e.g. pest -> tests.json), so a declared `report`, an `alternatives`
	#    group, or a runner on disk all count as resolution.
	#
	#    PRECONDITION tools are the other legitimate reportless case: `deps-install` is
	#    `category: setup` and declares `executable: [npm, pnpm, yarn]`. Its contract is
	#    "this executable exists", verified by run-tool-plan.sh, and build-security-summary
	#    handles it explicitly as a "Precondition tool (no report declared)". Demanding
	#    evidence from it would reject a tool that is working as designed.
	jq -r '(.tools // {}) | keys[]' "$f" 2>/dev/null | while read -r key; do
		[ -n "$key" ] || continue
		has_line "$CANON_KEYS" "$key" && continue
		jq -e --arg k "$key" '((.tools[$k].report // "") != "") or (((.tools[$k].alternatives // []) | length) > 0)' "$f" >/dev/null 2>&1 && continue
		jq -e --arg k "$key" '((.tools[$k].category // "") == "setup") and (((.tools[$k].executable // []) | length) > 0)' "$f" >/dev/null 2>&1 && continue
		[ -f "scripts/runners/$key.sh" ] && continue
		[ -f "scripts/collectors/$key.sh" ] && continue
		workflow_runs "$key" "$f" && continue
		fail "$prof: declares tool '$key', which has no TOOL_TABLE row, no report, no alternatives, no runner, no collector and no workflow step"
	done
done

# 4. Every TOOL_TABLE row must name a collector that exists on disk.
printf '%s\n' "$_tbl" | awk -F'|' 'NF>=4{print $1"\t"$3}' | while IFS="$(printf '\t')" read -r key coll; do
	[ -n "$coll" ] || continue
	[ -f "scripts/collectors/$coll" ] && continue
	fail "TOOL_TABLE row '$key' names collector '$coll', which does not exist"
done

# NOT `grep -c . "$FAILFILE" || printf 0`: on an EMPTY file grep prints "0" *and* exits 1,
# so the `||` fires and appends a second "0". The result is "0\n0", which is not numeric,
# which trips the guard below and reports a failure on a clean repo. `wc -l` has no such
# dual behaviour.
FAILED=$(wc -l < "$FAILFILE" 2>/dev/null | tr -d ' ')
case "$FAILED" in '' | *[!0-9]*) FAILED=1 ;; esac

if [ "$FAILED" -eq 0 ]; then
	printf '\nprofile-tool-integrity: ALL CHECKS PASSED\n'
else
	printf '\nprofile-tool-integrity: %s FAILURE(S) PRESENT\n' "$FAILED"
fi
[ "$FAILED" -eq 0 ] || exit 1
