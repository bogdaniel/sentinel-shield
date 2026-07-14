#!/bin/sh
# Sentinel Shield collector — duplication (normalized JSON).
#   .violations          -> duplication_violations
#   .duplication_percent -> informational duplication_percent
# Canonical raw shape:
#   { "tool":"duplication", "status":"pass", "duplication_percent":3.1,
#     "threshold":5, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="duplication"
INPUT="reports/raw/duplication.json"

usage() {
	cat <<'EOF'
Usage: duplication.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized duplication report.
Maps .violations -> duplication_violations; .duplication_percent -> informational.
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

V=$(jq '((.violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
DP=$(jq 'if ((.duplication_percent|type)=="number" and .duplication_percent >= 0) then .duplication_percent else 0 end' "$INPUT")
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson dp "$DP" '{duplication_violations:$v, duplication_percent:$dp}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson dp "$DP" '{status:$s, findings:$v, duplication_percent:$dp}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
