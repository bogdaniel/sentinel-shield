#!/bin/sh
# Sentinel Shield runner — generic PHPStan -> reports/raw/phpstan.json.
#
# Framework-agnostic PHPStan runner for Symfony / PHP-library / plain PHP projects.
# UNLIKE laravel-phpstan.sh it performs NO Laravel bootstrap (no APP_KEY, no
# artisan package:discover, no writable-dir creation) — it just runs PHPStan with
# the project's own phpstan.neon (which is where Symfony/Doctrine extensions are
# configured). Use laravel-phpstan.sh for Laravel projects.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically; no project
# mutation; EXTRACT/validate the JSON object from stdout; tool ABSENT or no valid
# JSON -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable');
# NEVER write a fake clean report; a non-zero PHPStan run (errors found) is NOT a
# runner failure (the JSON is the signal, EXIT stays 0); EXIT 2 only on bad
# invocation / missing jq.
#
# Env:
#   SENTINEL_SHIELD_PHPSTAN_BIN           (default: vendor/bin/phpstan, then phpstan)
#   SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT  (default 1G)
#   SENTINEL_SHIELD_PHPSTAN_CONFIG        (default: auto — phpstan.neon[.dist])
#   SENTINEL_SHIELD_PHPSTAN_PATHS         (default: per config; else "src")
# Usage: phpstan.sh [--output reports/raw/phpstan.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/phpstan.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpstan.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

MEM="${SENTINEL_SHIELD_PHPSTAN_MEMORY_LIMIT:-1G}"
CONFIG="${SENTINEL_SHIELD_PHPSTAN_CONFIG:-}"
PATHS="${SENTINEL_SHIELD_PHPSTAN_PATHS:-}"

command_exists jq || { log_error "phpstan: jq is required."; exit 2; }
command_exists php || { log_warn "phpstan: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

PHPSTAN_BIN="${SENTINEL_SHIELD_PHPSTAN_BIN:-}"
if [ -z "$PHPSTAN_BIN" ]; then
	if [ -x vendor/bin/phpstan ]; then PHPSTAN_BIN="vendor/bin/phpstan"
	elif command_exists phpstan; then PHPSTAN_BIN="phpstan"
	fi
fi
if [ -z "$PHPSTAN_BIN" ]; then
	log_warn "phpstan: not found (vendor/bin/phpstan or phpstan); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

if [ -z "$CONFIG" ]; then
	for c in phpstan.neon phpstan.neon.dist phpstan.dist.neon; do
		[ -f "$c" ] && { CONFIG="$c"; break; }
	done
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/$(basename "$OUTPUT" .json).stdout.raw"
_err="$_dir/$(basename "$OUTPUT" .json).stderr.log"

set -- analyse --no-progress --error-format=json --memory-limit="$MEM"
[ -n "$CONFIG" ] && set -- "$@" --configuration "$CONFIG"
if [ -n "$PATHS" ] && [ -z "$CONFIG" ]; then
	# Intentional word-split of a comma-separated PATHS list into separate args.
	# shellcheck disable=SC2086,SC2046
	set -- "$@" $(printf '%s' "$PATHS" | tr ',' ' ')
elif [ -z "$PATHS" ] && [ -z "$CONFIG" ]; then
	set -- "$@" src
fi

log_info "phpstan: $PHPSTAN_BIN $* (memory=$MEM, config=${CONFIG:-<none>})"
_rc=0
"$PHPSTAN_BIN" "$@" >"$_raw" 2>"$_err" || _rc=$?

write_report() {
	printf '%s' "$1" > "$OUTPUT"
	_n=$(jq '((.totals.file_errors // 0) + (.totals.errors // 0))' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "phpstan: wrote $OUTPUT (errors=$_n)."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
}

if jq -e 'type == "object"' "$_raw" >/dev/null 2>&1; then
	write_report "$(cat "$_raw")"
fi
_sliced=$(awk 'f==0 && index($0,"{")>0 {f=1} f' "$_raw")
if [ -n "$_sliced" ] && printf '%s' "$_sliced" | jq -e 'type == "object"' >/dev/null 2>&1; then
	log_warn "phpstan: stdout had leading noise; extracted the JSON object (see $_raw / $_err)."
	write_report "$_sliced"
fi

log_warn "phpstan: produced no valid JSON object on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
