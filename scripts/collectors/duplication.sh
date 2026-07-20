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

# The GATING count is never coerced. This read
#   ((.violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)
# which turned a negative, fractional or non-numeric .violations into a clean 0 — a
# corrupted or truncated report reported PASS. docs/raw-report-contract.md states the
# opposite rule verbatim, and lib/architecture-evidence.sh already implements it. An ABSENT
# .violations still legitimately means 0; a present-but-malformed one does not.
V=$(jq -r '
	if (has("violations") | not) then "0"
	elif ((.violations | type) == "number" and .violations >= 0 and (.violations | floor) == .violations)
		then (.violations | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"duplication_violations":0}'
	exit 0
fi
DP=$(jq 'if ((.duplication_percent|type)=="number" and .duplication_percent >= 0) then .duplication_percent else 0 end' "$INPUT")
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson dp "$DP" '{duplication_violations:$v, duplication_percent:$dp}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson dp "$DP" '{status:$s, findings:$v, duplication_percent:$dp}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
