#!/bin/sh
# Sentinel Shield runner — TypeScript --noEmit. Runs tsc if available and writes
# reports/raw/typescript.json {errors:N}; when tsc is not available OR fails to run, leaves the
# report ABSENT (collector reports 'unavailable') — it does NOT fake a clean report.
#
# Usage: typescript.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/typescript.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: typescript.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "typescript: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true   # never leave a stale report as evidence for this run
command_exists jq || { log_error "typescript: jq is required."; exit 2; }

if ! command_exists npx; then
	log_warn "typescript: npx not available; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

TSC_RC=0
TSC_OUT=$(npx --no-install tsc --noEmit 2>&1) || TSC_RC=$?
if [ "$TSC_RC" -ne 0 ] && ! printf '%s\n' "$TSC_OUT" | grep -q "error TS"; then
	# tsc itself failed to run (missing install, crash) — report unavailable, never a fake clean pass.
	log_warn "typescript: tsc failed to run (rc=$TSC_RC); leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi
ERR=$(printf '%s\n' "$TSC_OUT" | grep -c "error TS" || true)
jq -n --argjson e "${ERR:-0}" '{errors:$e}' > "$OUTPUT"
log_info "typescript: $ERR error(s) -> $OUTPUT."
exit 0
