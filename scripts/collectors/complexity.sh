#!/bin/sh
# Sentinel Shield collector — complexity (normalized JSON).
#   .violations         -> complexity_violations
#   .max_complexity     -> informational complexity_max
#   .average_complexity -> informational complexity_average
# Canonical raw shape:
#   { "tool":"complexity", "status":"pass", "max_complexity":9,
#     "average_complexity":3.2, "threshold":10, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="complexity"
INPUT="reports/raw/complexity.json"

usage() {
	cat <<'EOF'
Usage: complexity.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized complexity report.
Maps .violations -> complexity_violations; .max_complexity/.average_complexity ->
informational complexity_max / complexity_average.
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

RS=$(jq -r '.status // "pass"' "$INPUT")
case "$RS" in
	unavailable | not-configured | execution-error)
		ss_emit_collector "$TOOL" "$RS" "$(jq -n --arg s "$RS" '{status:$s, findings:0}')" '{}'
		exit 0 ;;
esac

num() { jq --arg k "$1" 'if ((.[$k]|type)=="number" and .[$k] >= 0) then .[$k] else 0 end' "$INPUT"; }

V=$(jq '((.violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
MAXC=$(num max_complexity); AVGC=$(num average_complexity)
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson mx "$MAXC" --argjson av "$AVGC" \
	'{complexity_violations:$v, complexity_max:$mx, complexity_average:$av}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson mx "$MAXC" --argjson av "$AVGC" \
	'{status:$s, findings:$v, max_complexity:$mx, average_complexity:$av}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
