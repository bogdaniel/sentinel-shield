#!/bin/sh
# Sentinel Shield runner — PHP coverage (Pest/PHPUnit Clover) -> reports/raw/php-coverage.json.
#
# Detects vendor/bin/pest then vendor/bin/phpunit, runs the suite with Clover coverage
# output, and normalizes it via scripts/adapters/clover-to-coverage-json.php using the
# thresholds/baseline from .sentinel-shield/quality-policy.yaml.
#
# Contract (matches pest.sh): detect exe deterministically; no project mutation beyond
# reports/; tool ABSENT, coverage driver (Xdebug/PCOV) ABSENT, or no valid Clover -> leave
# report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write a fake clean
# report; EXIT 2 only on bad invocation / missing jq.
#
# Coverage driver: Pest/PHPUnit need Xdebug or PCOV to emit Clover. Without one they print
# "No code coverage driver available" and produce no report -> we leave it ABSENT (honest).
#
# Env: SENTINEL_SHIELD_PHP_COVERAGE_BIN (default: vendor/bin/pest, then vendor/bin/phpunit)
# Usage: php-coverage.sh [--output reports/raw/php-coverage.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/php-coverage.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: php-coverage.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "php-coverage: jq is required."; exit 2; }
command_exists php || { log_warn "php-coverage: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/clover-to-coverage-json.php"
[ -f "$ADAPTER" ] || { log_error "php-coverage: adapter not found: $ADAPTER"; exit 2; }

qp_load "$POLICY"
if [ "$(qp_bool quality.coverage.enabled true)" = "false" ]; then
	log_warn "php-coverage: disabled in quality policy (quality.coverage.enabled: false); leaving '$OUTPUT' absent."
	exit 0
fi

BIN="${SENTINEL_SHIELD_PHP_COVERAGE_BIN:-}"
if [ -z "$BIN" ]; then
	if [ -x vendor/bin/pest ]; then BIN="vendor/bin/pest"
	elif [ -x vendor/bin/phpunit ]; then BIN="vendor/bin/phpunit"
	fi
fi
if [ -z "$BIN" ]; then
	log_warn "php-coverage: no pest/phpunit found (vendor/bin/pest or vendor/bin/phpunit); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_clover="$_dir/php-coverage.clover.xml"
_err="$_dir/php-coverage.stderr.log"
rm -f "$_clover" 2>/dev/null || true

# Xdebug 3 emits NO coverage unless XDEBUG_MODE includes 'coverage' — an unset mode makes an
# installed driver look absent and the run silently degrade to 'unavailable'. PCOV ignores it.
export XDEBUG_MODE=coverage
log_info "php-coverage: $BIN --coverage-clover $_clover (XDEBUG_MODE=coverage)"
_rc=0
"$BIN" --coverage-clover "$_clover" >"$_dir/php-coverage.stdout.raw" 2>"$_err" || _rc=$?

if [ ! -s "$_clover" ]; then
	log_warn "php-coverage: no Clover report produced (exit ${_rc:-?}) — usually no coverage driver (Xdebug/PCOV). Leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

# Assemble adapter args from the quality policy.
set -- "$_clover" \
	--line-min "$(qp_num quality.coverage.line_min 80)" \
	--branch-min "$(qp_num quality.coverage.branch_min 60)" \
	--method-min "$(qp_num quality.coverage.method_min 0)" \
	--class-min "$(qp_num quality.coverage.class_min 0)" \
	--fail-on-decrease "$(qp_bool quality.coverage.fail_on_decrease false)"
_baseline=$(qp_get quality.coverage.baseline_file)
[ -n "$_baseline" ] && set -- "$@" --baseline "$_baseline"
set -- "$@" --output "$OUTPUT"

if php "$ADAPTER" "$@" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "php-coverage: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_clover" "$_dir/php-coverage.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "php-coverage: adapter could not normalize Clover (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_clover, $_err."
exit 0
