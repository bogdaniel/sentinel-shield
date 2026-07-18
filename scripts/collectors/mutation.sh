#!/bin/sh
# Sentinel Shield collector — mutation testing (normalized JSON).
#   .violations   -> mutation_score_violations
#   .score_percent -> informational mutation_score_percent
# Canonical raw shape:
#   { "tool":"mutation", "status":"pass", "score_percent":72.5, "min_score":70, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="mutation"
INPUT="reports/raw/mutation.json"

usage() {
	cat <<'EOF'
Usage: mutation.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized mutation report.
Maps .violations -> mutation_score_violations, .score_percent -> informational
mutation_score_percent.
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

RS=$(jq -r '.status // ""' "$INPUT")
case "$RS" in
	'' | pass | findings | warn) : ;;  # normal: derive status from the numeric fields below
	unavailable | not-configured | execution-error | disabled | not-applicable)
		ss_emit_collector "$TOOL" "$RS" "$(jq -n --arg s "$RS" '{status:$s, findings:0}')" '{}'
		exit 0 ;;
	*)  # unknown/unexpected status -> fail closed (never derive a clean pass)
		ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error","findings":0}' '{}'
		exit 0 ;;
esac

V=$(jq '((.violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
SC=$(jq 'if ((.score_percent|type)=="number" and .score_percent >= 0) then .score_percent else 0 end' "$INPUT")
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson sc "$SC" '{mutation_score_violations:$v, mutation_score_percent:$sc}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson sc "$SC" '{status:$s, findings:$v, score_percent:$sc}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
