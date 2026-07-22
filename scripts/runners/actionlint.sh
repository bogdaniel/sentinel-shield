#!/bin/sh
# Sentinel Shield runner — actionlint. Runs actionlint if available and writes
# reports/raw/actionlint.json; absent tool / no workflows / no valid JSON array -> report
# left ABSENT (collector reports 'unavailable'), never a fake clean report. stderr kept.
#
# Usage: actionlint.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/actionlint.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: actionlint.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "actionlint: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true
command_exists jq || { log_error "actionlint: jq is required."; exit 2; }

if ! command_exists actionlint; then
	log_warn "actionlint: not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

_dir=$(dirname "$OUTPUT"); _raw="$_dir/actionlint.stdout.raw"; _err="$_dir/actionlint.stderr.log"
# No file glob: actionlint auto-discovers .github/workflows/*.yml AND *.yaml (the glob missed
# .yaml). Non-zero exit means findings — expected; the JSON array is the signal.
actionlint -format '{{json .}}' >"$_raw" 2>"$_err" || true
if jq -e 'type == "array"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"; rm -f "$_raw" "$_err" 2>/dev/null || true
	log_info "actionlint: wrote $OUTPUT."
	exit 0
fi
log_warn "actionlint: no valid JSON array produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT faking a clean report. Debug: $_raw, $_err."
exit 0
