#!/bin/sh
# Sentinel Shield collector — source size (normalized JSON).
#   .large_file_violations     -> large_file_violations
#   .large_function_violations -> large_function_violations
#   .max_file_lines            -> informational max_file_lines
#   .max_function_lines        -> informational max_function_lines
# Canonical raw shape (see scripts/runners/source-size.sh):
#   { "tool":"source-size", "status":"pass", "large_file_violations":0,
#     "large_function_violations":0, "max_file_lines":0, "max_function_lines":0,
#     "thresholds": { "max_file_lines":500, "max_function_lines":80 } }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="source-size"
INPUT="reports/raw/source-size.json"

usage() {
	cat <<'EOF'
Usage: source-size.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized source-size report.
Maps .large_file_violations -> large_file_violations and .large_function_violations ->
large_function_violations; .max_file_lines / .max_function_lines -> informational keys.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_collector_guard "$TOOL" "$INPUT"

# Honest non-clean statuses pass straight through (never invented as a clean 0).
RS=$(jq -r '.status // "pass"' "$INPUT")
case "$RS" in
	unavailable | not-configured | execution-error)
		ss_emit_collector "$TOOL" "$RS" "$(jq -n --arg s "$RS" '{status:$s, findings:0}')" '{}'
		exit 0 ;;
esac

LFV=$(jq '((.large_file_violations // 0) | if type=="number" then floor else 0 end)' "$INPUT")
LFUV=$(jq '((.large_function_violations // 0) | if type=="number" then floor else 0 end)' "$INPUT")
MAXF=$(jq '((.max_file_lines // 0) | if type=="number" then floor else 0 end)' "$INPUT")
MAXFN=$(jq '((.max_function_lines // 0) | if type=="number" then floor else 0 end)' "$INPUT")
SUM=$((LFV + LFUV))

if [ "$LFV" -gt 0 ] || [ "$LFUV" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson lf "$LFV" --argjson lfn "$LFUV" --argjson mx "$MAXF" --argjson mxfn "$MAXFN" \
	'{large_file_violations:$lf, large_function_violations:$lfn, max_file_lines:$mx, max_function_lines:$mxfn}')
REPORT=$(jq -n --arg s "$STATUS" --argjson sum "$SUM" --argjson lf "$LFV" --argjson lfn "$LFUV" \
	--argjson mx "$MAXF" --argjson mxfn "$MAXFN" '{
		status:$s, findings:$sum,
		large_file_violations:$lf, large_function_violations:$lfn,
		max_file_lines:$mx, max_function_lines:$mxfn
	}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
