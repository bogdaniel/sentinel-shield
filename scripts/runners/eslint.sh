#!/bin/sh
# Sentinel Shield runner — ESLint. Runs eslint if available and writes reports/raw/eslint.json;
# if the tool is absent OR produces no valid JSON array, leaves the report ABSENT (collector
# reports 'unavailable') — never a fake clean report. stderr is kept as a debug artifact.
#
# Usage: eslint.sh [--output <path>]   (a bare positional path is also accepted, back-compat)
# Exit:  0 ran (report written) or honest unavailable (no report); 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/eslint.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: eslint.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "eslint: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true   # (Issue 7) never inherit a previous run's report
command_exists jq || { log_error "eslint: jq is required."; exit 2; }

if ! command_exists npx; then
	log_warn "eslint: npx not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

_dir=$(dirname "$OUTPUT"); _raw="$_dir/eslint.stdout.raw"; _err="$_dir/eslint.stderr.log"
# eslint exits non-zero when lint errors exist — expected; the JSON array is the signal.
npx --no-install eslint . -f json >"$_raw" 2>"$_err" || true
if jq -e 'type == "array"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"; rm -f "$_raw" "$_err" 2>/dev/null || true
	log_info "eslint: wrote $OUTPUT."
	exit 0
fi
log_warn "eslint: no valid JSON array produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT faking a clean report. Debug: $_raw, $_err."
exit 0
