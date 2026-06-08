#!/bin/sh
# Sentinel Shield runner — Laravel PHPStan/Larastan -> reports/raw/phpstan.json.
#
# Wraps the common Laravel CI pitfalls so a consuming project does not re-implement them:
#   - APP_ENV=testing, APP_KEY fallback if unset (Larastan boots the framework)
#   - create the writable dirs a fresh checkout lacks (bootstrap/cache, storage/**)
#   - run `php artisan package:discover` when artisan is present and safe
#   - configurable memory limit / config / paths / binary
#   - capture stdout and stderr SEPARATELY, then EXTRACT/validate the JSON object before
#     writing reports/raw/phpstan.json — so stdout noise (deprecations, boot output, a
#     fatal message) does not corrupt the report.
#   - debug artifacts on trouble: reports/raw/phpstan.stdout.raw, phpstan.stderr.log
#   - NEVER write a fake clean report. PHPStan missing OR no valid JSON -> leave the
#     report absent so the builder marks the tool `unavailable` (honest, not 0-faked).
#
# Env:
#   SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT      (default 2G)
#   SENTINEL_SHIELD_PHPSTAN_CONFIG            (default: auto — phpstan.neon[.dist])
#   SENTINEL_SHIELD_PHPSTAN_PATHS             (default: per config; else "app")
#   SENTINEL_SHIELD_PHPSTAN_BIN              (default: vendor/bin/phpstan, then phpstan)
#   SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER  (default true) — run artisan package:discover
#   SENTINEL_SHIELD_LARAVEL_PREPARE           (default true) — create writable dirs + APP_KEY
#
# Usage: laravel-phpstan.sh [--output reports/raw/phpstan.json]
# Exit: 0 ran (report written) OR unavailable (no report, honest); 2 config error.
# A non-zero PHPStan run (errors found) is NOT a runner failure — the JSON is the signal,
# and exit stays 0 so the workflow still uploads artifacts.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/phpstan.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: laravel-phpstan.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

MEM="${SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT:-2G}"
CONFIG="${SENTINEL_SHIELD_PHPSTAN_CONFIG:-}"
PATHS="${SENTINEL_SHIELD_PHPSTAN_PATHS:-}"
# Default true; only the literal "false" disables (avoids bool_value edge cases).
DO_DISCOVER=true; [ "${SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER:-true}" = "false" ] && DO_DISCOVER=false
DO_PREPARE=true;  [ "${SENTINEL_SHIELD_LARAVEL_PREPARE:-true}" = "false" ] && DO_PREPARE=false

command_exists jq || { log_error "laravel-phpstan: jq is required."; exit 2; }
command_exists php || { log_warn "laravel-phpstan: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

# Locate PHPStan. If absent -> unavailable (NOT a fake clean report).
PHPSTAN_BIN="${SENTINEL_SHIELD_PHPSTAN_BIN:-}"
if [ -z "$PHPSTAN_BIN" ]; then
	if [ -x vendor/bin/phpstan ]; then PHPSTAN_BIN="vendor/bin/phpstan"
	elif command_exists phpstan; then PHPSTAN_BIN="phpstan"
	fi
fi
if [ -z "$PHPSTAN_BIN" ]; then
	log_warn "laravel-phpstan: PHPStan not found (vendor/bin/phpstan or phpstan); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

# Auto-detect config if not provided.
if [ -z "$CONFIG" ]; then
	for c in phpstan.neon phpstan.neon.dist phpstan.dist.neon; do
		[ -f "$c" ] && { CONFIG="$c"; break; }
	done
fi

# --- Laravel CI environment hardening (pilot lessons) -----------------------
if [ "$DO_PREPARE" = "true" ]; then
	export APP_ENV="${APP_ENV:-testing}"
	if [ -z "${APP_KEY:-}" ]; then
		# Larastan boots the app; a missing APP_KEY aborts encryption setup.
		export APP_KEY="base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
		log_info "laravel-phpstan: APP_KEY unset; using an ephemeral testing key."
	fi
	# Fresh checkouts lack these writable dirs (excludePaths / framework boot need them).
	mkdir -p bootstrap/cache storage/framework/cache storage/framework/sessions \
		storage/framework/views storage/logs 2>/dev/null || true
fi

# package:discover primes the container so Larastan can resolve providers. Its output
# goes to /dev/null (it must NOT pollute the PHPStan stdout we parse later).
if [ "$DO_DISCOVER" = "true" ] && [ -f artisan ]; then
	php artisan package:discover --ansi >/dev/null 2>&1 \
		&& log_info "laravel-phpstan: ran 'artisan package:discover'." \
		|| log_warn "laravel-phpstan: 'artisan package:discover' failed (continuing)."
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/phpstan.stdout.raw"
_err="$_dir/phpstan.stderr.log"

# Build args. PHPStan writes the JSON report to stdout with --error-format=json.
set -- analyse --no-progress --error-format=json --memory-limit="$MEM"
[ -n "$CONFIG" ] && set -- "$@" --configuration "$CONFIG"
# Explicit paths only when given AND not covered by config (PHPStan errors if both a
# config 'paths' and CLI paths are supplied; default to config when present).
if [ -n "$PATHS" ] && [ -z "$CONFIG" ]; then
	# shellcheck disable=SC2086
	set -- "$@" $(printf '%s' "$PATHS" | tr ',' ' ')
elif [ -z "$PATHS" ] && [ -z "$CONFIG" ]; then
	set -- "$@" app
fi

log_info "laravel-phpstan: $PHPSTAN_BIN $* (memory=$MEM, config=${CONFIG:-<none>})"
# Capture stdout and stderr to SEPARATE files (stderr noise never touches the JSON we
# parse). PHPStan exits non-zero when it finds errors — expected; we keep going.
_rc=0
"$PHPSTAN_BIN" "$@" >"$_raw" 2>"$_err" || _rc=$?

# Validate / extract the JSON object from stdout. Order:
#   1. whole stdout is a JSON object  -> use as-is
#   2. slice from the first '{' line to EOF (strip leading boot/deprecation noise) -> validate
#   3. otherwise: do NOT fake — leave the report absent, keep debug artifacts.
write_report() { # write_report <json-text>
	printf '%s' "$1" > "$OUTPUT"
	_n=$(jq '((.totals.file_errors // 0) + (.totals.errors // 0))' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "laravel-phpstan: wrote $OUTPUT (errors=$_n)."
	# Clean debug artifacts on success to keep reports/raw tidy.
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
}

if jq -e 'type == "object"' "$_raw" >/dev/null 2>&1; then
	write_report "$(cat "$_raw")"
fi
# Slice from the first line containing '{' to EOF, then validate.
_sliced=$(awk 'f==0 && index($0,"{")>0 {f=1} f' "$_raw")
if [ -n "$_sliced" ] && printf '%s' "$_sliced" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_warn "laravel-phpstan: PHPStan stdout had leading noise; extracted the JSON object (see $_raw / $_err)."
	write_report "$_sliced"
fi

log_warn "laravel-phpstan: PHPStan produced no valid JSON object on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
