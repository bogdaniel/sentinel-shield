#!/bin/sh
# Sentinel Shield runner — Vitest test suite -> reports/raw/tests.json.
#
# Vitest emits a JSON report via `run --reporter=json --outputFile`, normalized by
# scripts/adapters/vitest-to-tests-json.mjs into the canonical tests shape
# { failures, errors } at reports/raw/tests.json. Test failures are FINDINGS, not a
# runner failure — EXIT 0; the normalized report is the signal.
#
# Contract (matches pest.sh/jest.sh): detect exe (node_modules/.bin/vitest then
# vitest on PATH); no project mutation; validated normalized report; tool ABSENT or
# no valid report -> report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable');
# NEVER write a fake clean report; EXIT 2 only on bad invocation / missing jq/node.
#
# Env: SENTINEL_SHIELD_VITEST_BIN (default: node_modules/.bin/vitest, then vitest)
# Usage: vitest.sh [--output reports/raw/tests.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/tests.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: vitest.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "vitest: jq is required."; exit 2; }
command_exists node || { log_warn "vitest: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/vitest-to-tests-json.mjs"
[ -f "$ADAPTER" ] || { log_error "vitest: adapter not found: $ADAPTER"; exit 2; }

VITEST_BIN="${SENTINEL_SHIELD_VITEST_BIN:-}"
if [ -z "$VITEST_BIN" ]; then
	if [ -x node_modules/.bin/vitest ]; then VITEST_BIN="node_modules/.bin/vitest"
	elif command_exists vitest; then VITEST_BIN="vitest"
	fi
fi
if [ -z "$VITEST_BIN" ]; then
	log_warn "vitest: not found (node_modules/.bin/vitest or vitest); leaving '$OUTPUT' absent (tool unavailable). Run the lockfile install first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_json="$_dir/vitest.report.json"
_err="$_dir/vitest.stderr.log"
rm -f "$_json" 2>/dev/null || true

log_info "vitest: $VITEST_BIN run --reporter=json --outputFile=$_json --passWithNoTests"
_rc=0
"$VITEST_BIN" run --reporter=json --outputFile="$_json" --passWithNoTests >"$_dir/vitest.stdout.raw" 2>"$_err" || _rc=$?

if [ ! -s "$_json" ]; then
	log_warn "vitest: produced no JSON report (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

if node "$ADAPTER" "$_json" "$OUTPUT" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "vitest: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_json" "$_dir/vitest.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "vitest: adapter could not normalize JSON (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_json, $_err."
exit 0
