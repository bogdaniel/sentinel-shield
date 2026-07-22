#!/bin/sh
# Sentinel Shield runner — Pint / PHP-CS-Fixer style check. Runs the tool if available and
# writes reports/raw/php-style.json; absent tool OR no valid JSON -> report left ABSENT
# (collector reports 'unavailable'), never a fake clean report. stderr kept as a debug artifact.
#
# Usage: php-style.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/php-style.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: php-style.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "php-style: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true
command_exists jq || { log_error "php-style: jq is required."; exit 2; }

if ! { [ -x vendor/bin/pint ] || [ -x vendor/bin/php-cs-fixer ]; }; then
	log_warn "php-style: pint/php-cs-fixer not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

_dir=$(dirname "$OUTPUT"); _raw="$_dir/php-style.stdout.raw"; _err="$_dir/php-style.stderr.log"
# pint/php-cs-fixer exit non-zero when style violations exist — expected; JSON is the signal.
# (No second `pint --test` run: the old code reran the whole tool on every violating repo just
# to write a .txt no collector reads. Accept the JSON if it is valid; else leave absent.)
if [ -x vendor/bin/pint ]; then
	vendor/bin/pint --test --format=json >"$_raw" 2>"$_err" || true
else
	vendor/bin/php-cs-fixer fix --dry-run --format=json >"$_raw" 2>"$_err" || true
fi
if jq -e 'type == "object" or type == "array"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"; rm -f "$_raw" "$_err" 2>/dev/null || true
	log_info "php-style: wrote $OUTPUT."
	exit 0
fi
log_warn "php-style: no valid JSON produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT faking a clean report. Debug: $_raw, $_err."
exit 0
