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

	# (1) malformed shape -> fail closed (exit 2)
	if sh "$_script" --input "$BAD" >/dev/null 2>&1; then
		fail "$_c: malformed report did NOT fail closed (cleared the gate)"
	else
		_rc=$?
		[ "$_rc" -eq 2 ] && pass "$_c: malformed -> exit 2 (fail closed)" \
			|| fail "$_c: malformed -> exit $_rc (want 2)"
	fi

	# (2) well-typed clean report -> pass (exit 0)
	_cf="$WORK/clean-$_c.json"; printf '%s' "$_clean" > "$_cf"
	if sh "$_script" --input "$_cf" >/dev/null 2>&1; then
		pass "$_c: clean-empty -> exit 0"
	else
		fail "$_c: clean-empty report was rejected (exit $?) — over-aggressive fail-closed"
	fi
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

[ "$FAILED" -eq 0 ] && printf '\n273-collector-shape-failclosed: 0 failure(s)\nAll collector fail-closed assertions passed.\n' || {
	printf '\n273-collector-shape-failclosed: FAILURES above.\n'; exit 1; }
