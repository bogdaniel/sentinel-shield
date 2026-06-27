#!/bin/sh
# Sentinel Shield runner — PHP-CS-Fixer (dry-run) -> reports/raw/php-cs-fixer.json.
#
# Runs `php-cs-fixer fix --dry-run --diff --format=json` which reports style violations
# WITHOUT mutating files (--dry-run). The tool exits non-zero when violations exist — that
# is FINDINGS, not a runner failure, so we keep going and EXIT 0; the JSON is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (vendor/bin/php-cs-fixer
# then php-cs-fixer on PATH); no project mutation; validated normalized report; tool ABSENT
# or no valid JSON -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable');
# NEVER write a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_PHP_CS_FIXER_BIN (default: vendor/bin/php-cs-fixer, then php-cs-fixer)
# Usage: php-cs-fixer.sh [--output reports/raw/php-cs-fixer.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/php-cs-fixer.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: php-cs-fixer.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "php-cs-fixer: jq is required."; exit 2; }

FIXER_BIN="${SENTINEL_SHIELD_PHP_CS_FIXER_BIN:-}"
if [ -z "$FIXER_BIN" ]; then
	if [ -x vendor/bin/php-cs-fixer ]; then FIXER_BIN="vendor/bin/php-cs-fixer"
	elif command_exists php-cs-fixer; then FIXER_BIN="php-cs-fixer"
	fi
fi
if [ -z "$FIXER_BIN" ]; then
	log_warn "php-cs-fixer: not found (vendor/bin/php-cs-fixer or php-cs-fixer); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/php-cs-fixer.stdout.raw"
_err="$_dir/php-cs-fixer.stderr.log"

# --dry-run + --diff = report only, no mutation. --format=json -> stdout JSON.
log_info "php-cs-fixer: $FIXER_BIN fix --dry-run --diff --format=json"
_rc=0
"$FIXER_BIN" fix --dry-run --diff --format=json >"$_raw" 2>"$_err" || _rc=$?

if jq -e . "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"
	log_info "php-cs-fixer: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi

log_warn "php-cs-fixer: produced no valid JSON on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
