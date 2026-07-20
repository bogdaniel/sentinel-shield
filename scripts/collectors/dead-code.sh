#!/bin/sh
# Sentinel Shield collector — dead code (normalized JSON).
#   .violations (or .dead_code_count) -> dead_code_violations
#   .dead_code_count                  -> informational dead_code_count
# Canonical raw shape:
#   { "tool":"dead-code", "status":"pass", "dead_code_count":0, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="dead-code"
INPUT="reports/raw/dead-code.json"

usage() {
	cat <<'EOF'
Usage: dead-code.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized dead-code report.
Maps .violations (or .dead_code_count) -> dead_code_violations; .dead_code_count ->
informational dead_code_count.
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

DCC=$(jq '((.dead_code_count // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
# .violations wins when present and VALID. Two behaviours changed here:
#   * a present-but-MALFORMED .violations used to fall back to .dead_code_count — so
#     {"violations":"abc","dead_code_count":7} reported 7 violations, a number the report
#     never asserted and that no sibling collector would produce. A malformed gating count
#     is untrusted evidence, not a licence to substitute a different field.
#   * a NEGATIVE .violations was clamped to 0, i.e. silently reported as clean.
# Both now fail closed. An ABSENT .violations still legitimately uses .dead_code_count.
V=$(jq -r --argjson dcc "$DCC" '
	if (has("violations") | not) then ($dcc | tostring)
	elif ((.violations | type) == "number" and .violations >= 0 and (.violations | floor) == .violations)
		then (.violations | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced, never substituted)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"dead_code_violations":0}'
	exit 0
fi
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson dcc "$DCC" '{dead_code_violations:$v, dead_code_count:$dcc}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson dcc "$DCC" '{status:$s, findings:$v, dead_code_count:$dcc}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
