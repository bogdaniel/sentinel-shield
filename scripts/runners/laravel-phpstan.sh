#!/bin/sh
# Sentinel Shield runner — Laravel PHPStan/Larastan -> reports/raw/phpstan.json.
#
# Wraps the common Laravel CI pitfalls discovered during the zenchron-tools pilot so a
# consuming project does not re-implement them:
#   - APP_ENV=testing, APP_KEY fallback if unset (Larastan boots the framework)
#   - create the writable dirs a fresh checkout lacks (bootstrap/cache, storage/**)
#   - run `php artisan package:discover` when artisan is present
#   - configurable memory limit / config / paths
#   - ALWAYS write reports/raw/phpstan.json (PHPStan's JSON), even on non-zero exit
#   - if PHPStan is unavailable, write NOTHING and exit 0 so the builder marks the tool
#     `unavailable` (never a faked clean report)
#
# Env:
#   SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT  (default 2G)
#   SENTINEL_SHIELD_PHPSTAN_CONFIG        (default phpstan.neon, then phpstan.neon.dist)
#   SENTINEL_SHIELD_PHPSTAN_PATHS         (default: analyse per config; else "app")
#   SENTINEL_SHIELD_PHPSTAN_BIN           (default: vendor/bin/phpstan, then phpstan)
#
# Usage: laravel-phpstan.sh [--output reports/raw/phpstan.json]
# Exit: 0 ran (report written) or unavailable; 2 config error. A non-zero PHPStan run
# (errors found) is NOT a runner failure — the report is the signal.
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
export APP_ENV="${APP_ENV:-testing}"
if [ -z "${APP_KEY:-}" ]; then
	# Larastan boots the app; a missing APP_KEY aborts encryption setup.
	export APP_KEY="base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	log_info "laravel-phpstan: APP_KEY unset; using an ephemeral testing key."
fi
# Fresh checkouts lack these writable dirs (excludePaths / framework boot need them).
mkdir -p bootstrap/cache storage/framework/cache storage/framework/sessions \
	storage/framework/views storage/logs 2>/dev/null || true

# package:discover primes the container so Larastan can resolve providers.
if [ -f artisan ]; then
	php artisan package:discover --ansi >/dev/null 2>&1 \
		&& log_info "laravel-phpstan: ran 'artisan package:discover'." \
		|| log_warn "laravel-phpstan: 'artisan package:discover' failed (continuing)."
fi

ensure_dir "$OUTPUT"

# Build args. PHPStan writes JSON to stdout with --error-format=json.
set -- analyse --no-progress --error-format=json --memory-limit="$MEM"
[ -n "$CONFIG" ] && set -- "$@" --configuration "$CONFIG"
# Explicit paths only when given AND not already covered by config (PHPStan errors if
# both a config 'paths' and CLI paths are supplied; default to config when present).
if [ -n "$PATHS" ] && [ -z "$CONFIG" ]; then
	# shellcheck disable=SC2086
	set -- "$@" $(printf '%s' "$PATHS" | tr ',' ' ')
elif [ -z "$PATHS" ] && [ -z "$CONFIG" ]; then
	set -- "$@" app
fi

log_info "laravel-phpstan: $PHPSTAN_BIN $* (memory=$MEM, config=${CONFIG:-<none>})"
# Capture stdout (JSON) regardless of exit code; PHPStan exits non-zero when it finds
# errors — that is expected, the report is the signal. Guard against an empty/garbage
# stdout (e.g. fatal before JSON) so we never write an invalid report.
_out=$("$PHPSTAN_BIN" "$@" 2>/dev/null || true)
if printf '%s' "$_out" | jq -e '.' >/dev/null 2>&1; then
	printf '%s' "$_out" > "$OUTPUT"
	_n=$(jq '((.totals.file_errors // 0) + (.totals.errors // 0))' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "laravel-phpstan: wrote $OUTPUT (errors=$_n)."
	exit 0
else
	log_warn "laravel-phpstan: PHPStan did not emit valid JSON (likely a fatal/bootstrap error); leaving '$OUTPUT' absent (tool unavailable). NOT writing a fake clean report."
	exit 0
fi
