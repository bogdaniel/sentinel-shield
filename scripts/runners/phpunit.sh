#!/bin/sh
# Sentinel Shield runner — PHPUnit test suite -> reports/raw/tests.json.
#
# Runs PHPUnit with --log-junit to emit a JUnit XML report, which the shared
# scripts/adapters/phpunit-to-tests-json.php adapter normalizes into the canonical tests
# shape { failures, errors } at reports/raw/tests.json. Test failures are FINDINGS, not a
# runner failure — we keep going and EXIT 0; the normalized report is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (vendor/bin/phpunit then
# phpunit on PATH); no project mutation; validated normalized report; tool ABSENT or no valid
# report -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write
# a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_PHPUNIT_BIN (default: vendor/bin/phpunit, then phpunit)
# Usage: phpunit.sh [--output reports/raw/tests.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/tests.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpunit.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "phpunit: jq is required."; exit 2; }
command_exists php || { log_warn "phpunit: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/phpunit-to-tests-json.php"
[ -f "$ADAPTER" ] || { log_error "phpunit: adapter not found: $ADAPTER"; exit 2; }

PHPUNIT_BIN="${SENTINEL_SHIELD_PHPUNIT_BIN:-}"
if [ -z "$PHPUNIT_BIN" ]; then
	if [ -x vendor/bin/phpunit ]; then PHPUNIT_BIN="vendor/bin/phpunit"
	elif command_exists phpunit; then PHPUNIT_BIN="phpunit"
	fi
fi
if [ -z "$PHPUNIT_BIN" ]; then
	log_warn "phpunit: not found (vendor/bin/phpunit or phpunit); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_junit="$_dir/phpunit.junit.xml"
_err="$_dir/phpunit.stderr.log"
rm -f "$_junit" 2>/dev/null || true

# --do-not-cache-result keeps the run read-only (no .phpunit.result.cache written).
log_info "phpunit: $PHPUNIT_BIN --log-junit $_junit --do-not-cache-result"
_rc=0
"$PHPUNIT_BIN" --log-junit "$_junit" --do-not-cache-result >"$_dir/phpunit.stdout.raw" 2>"$_err" || _rc=$?

if [ ! -s "$_junit" ]; then
	log_warn "phpunit: produced no JUnit report (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

# Normalize JUnit XML -> canonical tests.json. The adapter exits 2 on invalid input.
if php "$ADAPTER" "$_junit" "$OUTPUT" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "phpunit: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_junit" "$_dir/phpunit.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "phpunit: adapter could not normalize JUnit (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_junit, $_err."
exit 0
