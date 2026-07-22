#!/bin/sh
# Sentinel Shield runner — zizmor (GitHub Actions security). Runs zizmor if available and
# writes reports/raw/zizmor.json; absent tool / no workflows / no valid JSON -> report left
# ABSENT (collector reports 'unavailable'), never a fake clean report. stderr kept.
#
# Usage: zizmor.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/zizmor.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: zizmor.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "zizmor: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true
command_exists jq || { log_error "zizmor: jq is required."; exit 2; }

if ! command_exists zizmor; then
	log_warn "zizmor: not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi
if [ ! -d .github/workflows ]; then
	log_warn "zizmor: no .github/workflows directory; leaving '$OUTPUT' absent (not applicable)."
	exit 0
fi

_dir=$(dirname "$OUTPUT"); _raw="$_dir/zizmor.stdout.raw"; _err="$_dir/zizmor.stderr.log"
# Non-zero exit means findings — expected; the JSON is the signal.
zizmor --format json .github/workflows >"$_raw" 2>"$_err" || true
if jq -e 'type == "array" or type == "object"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"; rm -f "$_raw" "$_err" 2>/dev/null || true
	log_info "zizmor: wrote $OUTPUT."
	exit 0
fi
log_warn "zizmor: no valid JSON produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT faking a clean report. Debug: $_raw, $_err."
exit 0
