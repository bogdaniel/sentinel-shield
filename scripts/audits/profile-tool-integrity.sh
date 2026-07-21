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

# Tools executed by an installed workflow template rather than a profile .tools entry
# (e.g. scorecard and trufflehog run as scheduled GitHub Actions). These are legitimately
# recommendable: the generated CI really does run them.
workflow_runs() {
	grep -rql -- "$1" templates/workflows/ 2>/dev/null
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
	#    the installed workflow template actually runs.
	jq -r '((.recommended_pr_fast_tools // []) + (.recommended_main_gate_tools // []) + (.recommended_scheduled_tools // []))[]' "$f" \
	| sort -u | while read -r key; do
		[ -n "$key" ] || continue
		has_line "$CANON_KEYS" "$key" && continue
		jq -e --arg k "$key" '(.tools // {}) | has($k)' "$f" >/dev/null 2>&1 && continue
		workflow_runs "$key" >/dev/null 2>&1 && continue
		fail "$prof: recommends '$key', which resolves to no TOOL_TABLE row, no declared tool, and no workflow step"
	done
done

# 3. Every TOOL_TABLE row must name a collector that exists on disk.
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
