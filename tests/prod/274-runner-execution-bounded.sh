#!/bin/sh
# Sentinel Shield prod test — run-tool-plan.sh bounds each runner invocation.
#
# The main tool-execution path previously invoked runners unbounded (`sh "$runner" > log`),
# so one hung scanner stalled the whole stage forever while bounded-process.sh sat unused.
# This asserts (a) the wiring is present and (b) the mechanism actually terminates a hang.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RTP="$ROOT/scripts/run-tool-plan.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

[ -f "$RTP" ] || { fail "missing $RTP"; exit 1; }

# (a) wiring: bounded-process sourced, runner invoked via bp_run, NOT bare `sh "$REPO_ROOT/$_runner" >`
grep -q 'lib/bounded-process.sh' "$RTP" && pass "run-tool-plan sources bounded-process.sh" \
	|| fail "run-tool-plan does not source bounded-process.sh"
# bp_run and its `-- sh "$REPO_ROOT/$_runner"` argument may be line-wrapped, so check both.
if grep -q 'bp_run runner-exec' "$RTP" && grep -q -- '-- sh "\$REPO_ROOT/\$_runner"' "$RTP"; then
	pass "runner invoked via bp_run"
else
	fail "runner not invoked via bp_run"
fi
if grep -Eq '^[[:space:]]*sh "\$REPO_ROOT/\$_runner" >' "$RTP"; then
	fail "run-tool-plan still has an UNBOUNDED 'sh \$runner >' invocation"
else
	pass "no unbounded runner invocation remains"
fi

# (b) behavior: bp_run terminates an over-long process at the bound (as run-tool-plan calls it).
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss274)
trap 'rm -rf -- "$WORK"' EXIT INT TERM
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/bounded-process.sh
. "$ROOT/scripts/lib/bounded-process.sh"

_t0=$(date +%s 2>/dev/null || echo 0)
_rc=0
bp_run runner-exec 2 "$WORK/o" "$WORK/e" -- sh -c 'sleep 60' || _rc=$?
_t1=$(date +%s 2>/dev/null || echo 0)
_elapsed=$(( _t1 - _t0 ))

[ "${BP_STATUS:-}" = "timed-out" ] && pass "bp_run reports timed-out on a hung runner" \
	|| fail "bp_run BP_STATUS='${BP_STATUS:-}' (want timed-out)"
[ "$_rc" -ne 0 ] && pass "hung runner -> non-zero rc (classified as execution error)" \
	|| fail "hung runner returned rc 0 (would look successful)"
[ "$_elapsed" -lt 15 ] && pass "hung runner killed promptly (~${_elapsed}s, bound was 2s)" \
	|| fail "hung runner not killed near the bound (${_elapsed}s elapsed)"

[ "$FAILED" -eq 0 ] && printf '\n274-runner-execution-bounded: 0 failure(s)\nAll runner-bounding assertions passed.\n' || {
	printf '\n274-runner-execution-bounded: FAILURES above.\n'; exit 1; }
