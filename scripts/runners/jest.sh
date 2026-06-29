#!/bin/sh
# Sentinel Shield runner — Jest test suite -> reports/raw/js-tests.json.
#
# Jest emits a JSON report via `--json --outputFile`, which the shared
# scripts/adapters/jest-to-tests-json.mjs adapter normalizes into the canonical
# tests shape { failures, errors } at reports/raw/js-tests.json (the JS `js-tests`
# one-of group; PHP tests use reports/raw/tests.json). Test failures are FINDINGS,
# not a runner failure — we keep going and EXIT 0; the normalized report is the signal.
#
# Contract (matches pest.sh): detect exe deterministically (node_modules/.bin/jest
# then jest on PATH); no project mutation; validated normalized report. The tool
# being ABSENT (node or jest not found) or producing no valid report -> leave report
# ABSENT + EXIT 0 + log_warn (the builder marks it 'unavailable'); NEVER write a fake
# clean report. EXIT 2 only on a configuration error: bad invocation, missing jq, or
# missing adapter.
#
# Env: SENTINEL_SHIELD_JEST_BIN (default: node_modules/.bin/jest, then jest)
# Usage: jest.sh [--output reports/raw/js-tests.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/js-tests.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: jest.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "jest: jq is required."; exit 2; }
command_exists node || { log_warn "jest: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/jest-to-tests-json.mjs"
[ -f "$ADAPTER" ] || { log_error "jest: adapter not found: $ADAPTER"; exit 2; }

JEST_BIN="${SENTINEL_SHIELD_JEST_BIN:-}"
if [ -z "$JEST_BIN" ]; then
	if [ -x node_modules/.bin/jest ]; then JEST_BIN="node_modules/.bin/jest"
	elif command_exists jest; then JEST_BIN="jest"
	fi
fi
if [ -z "$JEST_BIN" ]; then
	log_warn "jest: not found (node_modules/.bin/jest or jest); leaving '$OUTPUT' absent (tool unavailable). Run the lockfile install first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_json="$_dir/jest.report.json"
_err="$_dir/jest.stderr.log"
rm -f "$_json" 2>/dev/null || true

log_info "jest: $JEST_BIN --json --outputFile=$_json --passWithNoTests"
_rc=0
"$JEST_BIN" --json --outputFile="$_json" --passWithNoTests >"$_dir/jest.stdout.raw" 2>"$_err" || _rc=$?

if [ ! -s "$_json" ]; then
	log_warn "jest: produced no JSON report (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

if node "$ADAPTER" "$_json" "$OUTPUT" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "jest: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_json" "$_dir/jest.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "jest: adapter could not normalize JSON (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_json, $_err."
exit 0
