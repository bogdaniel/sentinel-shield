#!/bin/sh
# Sentinel Shield runner — Psalm static analysis. Runs psalm if available and writes
# reports/raw/psalm.json; absent tool OR no valid JSON array -> report left ABSENT (collector
# reports 'unavailable'), never a fake clean report. stderr kept as a debug artifact.
#
# Usage: psalm.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/psalm.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: psalm.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "psalm: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true
command_exists jq || { log_error "psalm: jq is required."; exit 2; }

if ! [ -x vendor/bin/psalm ]; then
	log_warn "psalm: vendor/bin/psalm not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

_dir=$(dirname "$OUTPUT"); _raw="$_dir/psalm.stdout.raw"; _err="$_dir/psalm.stderr.log"
# psalm exits non-zero when issues exist — expected; the JSON array is the signal.
vendor/bin/psalm --output-format=json >"$_raw" 2>"$_err" || true
if jq -e 'type == "array"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"; rm -f "$_raw" "$_err" 2>/dev/null || true
	log_info "psalm: wrote $OUTPUT."
	exit 0
fi
log_warn "psalm: no valid JSON array produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT faking a clean report. Debug: $_raw, $_err."
exit 0
