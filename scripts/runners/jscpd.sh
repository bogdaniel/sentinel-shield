#!/bin/sh
# Sentinel Shield runner — jscpd (JS/TS copy-paste detection) -> reports/raw/js-duplication.json.
#
# Detects node_modules/.bin/jscpd (or npx jscpd), runs it with the JSON reporter, reads
# statistics.total.percentage, and thresholds it against quality.duplication.max_percentage.
#
# Contract: tool ABSENT or unparseable output -> leave report ABSENT + EXIT 0 + log_warn
# (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Env: SENTINEL_SHIELD_JSCPD_PATHS (default: src)
# Usage: jscpd.sh [--output reports/raw/js-duplication.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/js-duplication.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: jscpd.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "jscpd: jq is required."; exit 2; }
command_exists node || { log_warn "jscpd: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

BIN=""
if [ -x node_modules/.bin/jscpd ]; then BIN="node_modules/.bin/jscpd"
elif command_exists jscpd; then BIN="jscpd"
fi
[ -n "$BIN" ] || { log_warn "jscpd: not found (node_modules/.bin/jscpd); leaving '$OUTPUT' absent (tool unavailable). Install with 'npm i -D jscpd'."; exit 0; }

PATHS="${SENTINEL_SHIELD_JSCPD_PATHS:-}"
[ -n "$PATHS" ] || { [ -d src ] && PATHS="src" || PATHS="."; }

qp_load "$POLICY"
THRESH=$(qp_num quality.duplication.max_percentage 5)

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_rep="$_dir/jscpd"
_err="$_dir/jscpd.stderr.log"
rm -rf "$_rep" 2>/dev/null || true

log_info "jscpd: $BIN $PATHS --reporters json --output $_rep"
# shellcheck disable=SC2086
"$BIN" $PATHS --reporters json --output "$_rep" --silent >"$_dir/jscpd.stdout.log" 2>"$_err" || true

_json="$_rep/jscpd-report.json"
PCT=$(jq -r 'if (.statistics.total.percentage|type)=="number" then .statistics.total.percentage else empty end' "$_json" 2>/dev/null || true)
if [ -z "$PCT" ]; then
	log_warn "jscpd: no valid JSON report with statistics.total.percentage; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

jq -n --argjson pct "$PCT" --argjson thr "$THRESH" '
	{ tool:"duplication",
	  status: (if $pct > $thr then "findings" else "pass" end),
	  duplication_percent: $pct, threshold: $thr,
	  violations: (if $pct > $thr then 1 else 0 end) }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "jscpd: wrote $OUTPUT (duplication=$PCT%, threshold=$THRESH%)."
	rm -rf "$_rep" 2>/dev/null || true; rm -f "$_err" "$_dir/jscpd.stdout.log" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "jscpd: could not write normalized report; leaving '$OUTPUT' absent."
exit 0
