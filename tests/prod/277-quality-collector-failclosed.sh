#!/bin/sh
# Sentinel Shield prod test — quality collectors fail CLOSED on a shapeless report.
#
# The quality collectors (complexity/coverage/dead-code/debug-code/diff-coverage/duplication/
# focused-tests/mutation/source-size) derive status from numeric metric keys when `.status` is
# absent. A valid-JSON object that carries NEITHER a status NOR any recognized metric key (e.g.
# a scanner error object) must not derive a clean `pass`. This asserts:
#   (a) an error object -> emitted status "execution-error" (not pass);
#   (b) a metrics-only report (no status) still derives "pass";
#   (c) an explicit {"status":"pass"} still passes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
COLLECTORS="$ROOT/scripts/collectors"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
command -v jq >/dev/null 2>&1 || { fail "jq required"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss277)
trap 'rm -rf -- "$WORK"' EXIT INT TERM
BAD="$WORK/bad.json"; printf '%s' '{"error":"scanner crashed"}' > "$BAD"

# emitted .status for a collector fed a fixture.
emit_status() { sh "$COLLECTORS/$1.sh" --input "$2" 2>/dev/null | jq -r '.status // "MISSING"'; }

# collector | a metrics-only clean fixture (no status key) that must derive pass.
run_case() {
	_c="$1"; _clean="$2"
	[ -f "$COLLECTORS/$_c.sh" ] || { fail "$_c: collector missing"; return; }

	_s=$(emit_status "$_c" "$BAD")
	[ "$_s" = "execution-error" ] && pass "$_c: shapeless error object -> execution-error" \
		|| fail "$_c: shapeless error object -> '$_s' (want execution-error)"

	_cf="$WORK/clean-$_c.json"; printf '%s' "$_clean" > "$_cf"
	_s=$(emit_status "$_c" "$_cf")
	[ "$_s" = "pass" ] && pass "$_c: metrics-only clean report -> pass" \
		|| fail "$_c: metrics-only clean report -> '$_s' (want pass)"

	_ef="$WORK/expl-$_c.json"; printf '%s' '{"status":"pass"}' > "$_ef"
	_s=$(emit_status "$_c" "$_ef")
	[ "$_s" = "pass" ] && pass "$_c: explicit status:pass -> pass" \
		|| fail "$_c: explicit status:pass -> '$_s' (want pass)"
}

# NOTE: only focused-tests and source-size are covered here. The other seven quality
# collectors (complexity/coverage/dead-code/debug-code/diff-coverage/duplication/mutation)
# are owned by open PR #56 (malformed-count coercion); the shapeless-error-object guard is
# added to them in a follow-up ON TOP of #56 to avoid a conflicting re-fix.
run_case focused-tests  '{"focused_test_violations":0,"skipped_test_marker_violations":0}'
run_case source-size    '{"large_file_violations":0,"large_function_violations":0}'

[ "$FAILED" -eq 0 ] && printf '\n277-quality-collector-failclosed: 0 failure(s)\nAll quality-collector fail-closed assertions passed.\n' || {
	printf '\n277-quality-collector-failclosed: FAILURES above.\n'; exit 1; }
