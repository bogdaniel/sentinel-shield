#!/bin/sh
# Sentinel Shield runner — Larastan (PHPStan + larastan extension) -> reports/raw/larastan.json.
#
# Larastan is a PHPStan extension; the executable is still phpstan. This runner boots
# the same Laravel CI hardening as laravel-phpstan.sh (APP_ENV/APP_KEY fallback, writable
# dirs, package:discover) because larastan boots the framework, then runs PHPStan with
# --error-format=json and writes the validated JSON object to reports/raw/larastan.json.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically; normalized report;
# findings still EXIT 0 (JSON is the signal); tool ABSENT or no valid
# NOTE: this runner DOES mutate the project when the Laravel prepare/discover steps are
# enabled (default on): it mkdirs bootstrap/cache + storage/** and 'artisan package:discover'
# rewrites bootstrap/cache/packages.php. Set SENTINEL_SHIELD_LARAVEL_PREPARE=false and
# SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER=false to run without touching the tree.
# Continuing the contract:
# JSON -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write
# a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env:
#   SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT  (default 2G)
#   SENTINEL_SHIELD_PHPSTAN_CONFIG        (default: auto — phpstan.neon[.dist])
#   SENTINEL_SHIELD_PHPSTAN_BIN           (default: vendor/bin/phpstan, then phpstan)
#   SENTINEL_SHIELD_LARAVEL_PREPARE       (default true) — writable dirs + APP_KEY
#   SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER (default true) — artisan package:discover
#
# Usage: larastan.sh [--output reports/raw/larastan.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/larastan.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: larastan.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

MEM="${SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT:-2G}"
CONFIG="${SENTINEL_SHIELD_PHPSTAN_CONFIG:-}"
DO_PREPARE=true;  [ "${SENTINEL_SHIELD_LARAVEL_PREPARE:-true}" = "false" ] && DO_PREPARE=false
DO_DISCOVER=true; [ "${SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER:-true}" = "false" ] && DO_DISCOVER=false

command_exists jq || { log_error "larastan: jq is required."; exit 2; }
command_exists php || { log_warn "larastan: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

# Locate PHPStan (larastan registers via extension). Absent -> unavailable, NOT fake-clean.
PHPSTAN_BIN="${SENTINEL_SHIELD_PHPSTAN_BIN:-}"
if [ -z "$PHPSTAN_BIN" ]; then
	if [ -x vendor/bin/phpstan ]; then PHPSTAN_BIN="vendor/bin/phpstan"
	elif command_exists phpstan; then PHPSTAN_BIN="phpstan"
	fi
fi
if [ -z "$PHPSTAN_BIN" ]; then
	log_warn "larastan: PHPStan not found (vendor/bin/phpstan or phpstan); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

if [ -z "$CONFIG" ]; then
	for c in phpstan.neon phpstan.neon.dist phpstan.dist.neon; do
		[ -f "$c" ] && { CONFIG="$c"; break; }
	done
fi

# Laravel CI hardening (larastan boots the framework).
if [ "$DO_PREPARE" = "true" ]; then
	export APP_ENV="${APP_ENV:-testing}"
	if [ -z "${APP_KEY:-}" ]; then
		export APP_KEY="base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
		log_info "larastan: APP_KEY unset; using an ephemeral testing key."
	fi
	mkdir -p bootstrap/cache storage/framework/cache storage/framework/sessions \
		storage/framework/views storage/logs 2>/dev/null || true
fi
if [ "$DO_DISCOVER" = "true" ] && [ -f artisan ]; then
	php artisan package:discover --ansi >/dev/null 2>&1 \
		&& log_info "larastan: ran 'artisan package:discover'." \
		|| log_warn "larastan: 'artisan package:discover' failed (continuing)."
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/larastan.stdout.raw"
_err="$_dir/larastan.stderr.log"

set -- analyse --no-progress --error-format=json --memory-limit="$MEM"
[ -n "$CONFIG" ] && set -- "$@" --configuration "$CONFIG"
[ -z "$CONFIG" ] && set -- "$@" app

log_info "larastan: $PHPSTAN_BIN $* (memory=$MEM, config=${CONFIG:-<none>})"
_rc=0
"$PHPSTAN_BIN" "$@" >"$_raw" 2>"$_err" || _rc=$?

# Validate / extract the JSON object (strip leading boot/deprecation noise). NEVER fake.
finalize_report() {
	_n=$(jq '((.totals.file_errors // 0) + (.totals.errors // 0))' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "larastan: wrote $OUTPUT (errors=$_n)."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
}
if jq -e 'type == "object"' "$_raw" >/dev/null 2>&1; then
	# cp the raw file verbatim — a command-substitution round-trip would strip trailing newlines.
	cp "$_raw" "$OUTPUT"
	finalize_report
fi
_sliced=$(awk 'f==0 && index($0,"{")>0 {f=1} f' "$_raw")
if [ -n "$_sliced" ] && printf '%s' "$_sliced" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_warn "larastan: stdout had leading noise; extracted the JSON object (see $_raw / $_err)."
	printf '%s\n' "$_sliced" > "$OUTPUT"
	finalize_report
fi

log_warn "larastan: produced no valid JSON object on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
