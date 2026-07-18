#!/bin/sh
# Sentinel Shield collector — changed-lines (diff) coverage (normalized JSON).
#   .violations                     -> changed_lines_coverage_violations
#   .changed_lines_coverage_percent -> informational changed_lines_coverage_percent
# Canonical raw shape (see docs/engineering-quality-gates.md):
#   { "tool":"diff-coverage", "status":"pass", "changed_lines_coverage_percent":85.5,
#     "threshold":80, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="diff-coverage"
INPUT="reports/raw/diff-coverage.json"

usage() {
	cat <<'EOF'
Usage: diff-coverage.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized diff-coverage report.
Maps .violations -> changed_lines_coverage_violations; .changed_lines_coverage_percent ->
informational.
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
PCT=$(jq 'if ((.changed_lines_coverage_percent|type)=="number" and .changed_lines_coverage_percent >= 0) then .changed_lines_coverage_percent else 0 end' "$INPUT")
if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson p "$PCT" \
	'{changed_lines_coverage_violations:$v, changed_lines_coverage_percent:$p}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson p "$PCT" \
	'{status:$s, findings:$v, changed_lines_coverage_percent:$p}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
