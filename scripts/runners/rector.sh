#!/bin/sh
# Sentinel Shield runner — Rector (dry-run) -> reports/raw/rector.json.
#
# Runs `rector process --dry-run --output-format=json` which reports suggested changes
# WITHOUT mutating files (--dry-run). Rector exits non-zero when changes are suggested —
# that is FINDINGS, not a runner failure, so we keep going and EXIT 0; the JSON is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (vendor/bin/rector then
# rector on PATH); no project mutation; validated normalized report; tool ABSENT or no valid
# JSON -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write
# a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_RECTOR_BIN (default: vendor/bin/rector, then rector)
# Usage: rector.sh [--output reports/raw/rector.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/rector.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: rector.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "rector: jq is required."; exit 2; }

RECTOR_BIN="${SENTINEL_SHIELD_RECTOR_BIN:-}"
if [ -z "$RECTOR_BIN" ]; then
	if [ -x vendor/bin/rector ]; then RECTOR_BIN="vendor/bin/rector"
	elif command_exists rector; then RECTOR_BIN="rector"
	fi
fi
if [ -z "$RECTOR_BIN" ]; then
	log_warn "rector: not found (vendor/bin/rector or rector); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/rector.stdout.raw"
_err="$_dir/rector.stderr.log"

log_info "rector: $RECTOR_BIN process --dry-run --output-format=json"
_rc=0
"$RECTOR_BIN" process --dry-run --output-format=json >"$_raw" 2>"$_err" || _rc=$?

# Validate; tolerate leading boot noise by slicing from the first '{' to EOF.
if jq -e . "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"
	log_info "rector: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi
_sliced=$(awk 'f==0 && index($0,"{")>0 {f=1} f' "$_raw")
if [ -n "$_sliced" ] && printf '%s' "$_sliced" | jq -e . >/dev/null 2>&1; then
	log_warn "rector: stdout had leading noise; extracted the JSON object (see $_raw / $_err)."
	printf '%s' "$_sliced" > "$OUTPUT"
	log_info "rector: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi

log_warn "rector: produced no valid JSON on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
