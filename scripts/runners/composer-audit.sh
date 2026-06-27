#!/bin/sh
# Sentinel Shield runner — Composer audit -> reports/raw/composer-audit.json.
#
# Runs `composer audit --format=json` to report known vulnerabilities in installed
# dependencies WITHOUT mutating the project. composer audit exits NON-ZERO when vulnerabilities
# are found — that is FINDINGS, not a runner failure, so we capture the JSON and EXIT 0; the
# report is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (composer on PATH);
# no project mutation; validated normalized report; tool ABSENT or no valid JSON -> leave
# report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write a fake clean
# report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_COMPOSER_BIN (default: composer on PATH)
# Usage: composer-audit.sh [--output reports/raw/composer-audit.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/composer-audit.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: composer-audit.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "composer-audit: jq is required."; exit 2; }

COMPOSER_BIN="${SENTINEL_SHIELD_COMPOSER_BIN:-}"
if [ -z "$COMPOSER_BIN" ]; then
	if [ -x vendor/bin/composer ]; then COMPOSER_BIN="vendor/bin/composer"
	elif command_exists composer; then COMPOSER_BIN="composer"
	fi
fi
if [ -z "$COMPOSER_BIN" ]; then
	log_warn "composer-audit: composer not found; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/composer-audit.stdout.raw"
_err="$_dir/composer-audit.stderr.log"

# composer audit exits non-zero when vulns exist — that is findings, not failure.
log_info "composer-audit: $COMPOSER_BIN audit --format=json"
_rc=0
"$COMPOSER_BIN" audit --format=json >"$_raw" 2>"$_err" || _rc=$?

if jq -e . "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"
	_n=$(jq '(.advisories | if type=="object" then ([.[]] | add | length) else (. | length) end) // 0' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "composer-audit: wrote $OUTPUT (advisories=$_n, exit ${_rc:-0})."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi

log_warn "composer-audit: produced no valid JSON on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
