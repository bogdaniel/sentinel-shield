#!/bin/sh
# Sentinel Shield runner — Pest test suite -> reports/raw/tests.json.
#
# Pest is PHPUnit-compatible, so it emits a JUnit XML report via --log-junit, which the
# shared scripts/adapters/phpunit-to-tests-json.php adapter normalizes into the canonical
# tests shape { failures, errors } at reports/raw/tests.json. Test failures are FINDINGS,
# not a runner failure — we keep going and EXIT 0; the normalized report is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (vendor/bin/pest then
# pest on PATH); no project mutation; validated normalized report; tool ABSENT or no valid
# report -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER
# write a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_PEST_BIN (default: vendor/bin/pest, then pest)
# Usage: pest.sh [--output reports/raw/tests.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/tests.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: pest.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "pest: jq is required."; exit 2; }
command_exists php || { log_warn "pest: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/phpunit-to-tests-json.php"
[ -f "$ADAPTER" ] || { log_error "pest: adapter not found: $ADAPTER"; exit 2; }

PEST_BIN="${SENTINEL_SHIELD_PEST_BIN:-}"
if [ -z "$PEST_BIN" ]; then
	if [ -x vendor/bin/pest ]; then PEST_BIN="vendor/bin/pest"
	elif command_exists pest; then PEST_BIN="pest"
	fi
fi
if [ -z "$PEST_BIN" ]; then
	log_warn "pest: not found (vendor/bin/pest or pest); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_junit="$_dir/pest.junit.xml"
_err="$_dir/pest.stderr.log"
rm -f "$_junit" 2>/dev/null || true

log_info "pest: $PEST_BIN --log-junit $_junit"
_rc=0
"$PEST_BIN" --log-junit "$_junit" >"$_dir/pest.stdout.raw" 2>"$_err" || _rc=$?

if [ ! -s "$_junit" ]; then
	log_warn "pest: produced no JUnit report (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

# Normalize JUnit XML -> canonical tests.json. The adapter exits 2 on invalid input.
if php "$ADAPTER" "$_junit" "$OUTPUT" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "pest: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_junit" "$_dir/pest.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "pest: adapter could not normalize JUnit (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_junit, $_err."
exit 0
