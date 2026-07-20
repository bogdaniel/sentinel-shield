#!/bin/sh
# Sentinel Shield collector — code coverage (normalized JSON).
#   .violations > 0     -> coverage_threshold_violations
#   .regression == true -> coverage_regression = 1
#   .line/branch/method/class_percent -> informational coverage_*_percent
# Canonical raw shape (see docs/raw-report-contract.md / engineering-quality-gates.md):
#   { "tool":"coverage", "status":"pass", "line_percent":82.4, "branch_percent":61.2,
#     "method_percent":0, "class_percent":0, "violations":0, "regression":false }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="coverage"
INPUT="reports/raw/coverage.json"

usage() {
	cat <<'EOF'
Usage: coverage.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized coverage report.
Maps threshold violations -> coverage_threshold_violations, regression ->
coverage_regression, and percentages -> informational coverage_*_percent keys.
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

# num <key> — the numeric value of .<key>, or 0 for absent/non-numeric.
num() { jq --arg k "$1" 'if ((.[$k]|type)=="number" and .[$k] >= 0) then .[$k] else 0 end' "$INPUT"; }

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
		'{"status":"execution-error","reason":"malformed violations count"}' '{"coverage_threshold_violations":0}'
	exit 0
fi
REG=$(jq 'if (.regression == true) then 1 else 0 end' "$INPUT")
LP=$(num line_percent); BP=$(num branch_percent); MP=$(num method_percent); CP=$(num class_percent)

if [ "$V" -gt 0 ] || [ "$REG" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$V" --argjson r "$REG" --argjson lp "$LP" --argjson bp "$BP" \
	--argjson mp "$MP" --argjson cp "$CP" '{
		coverage_threshold_violations: $v,
		coverage_regression: $r,
		coverage_line_percent: $lp,
		coverage_branch_percent: $bp,
		coverage_method_percent: $mp,
		coverage_class_percent: $cp
	}')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson r "$REG" --argjson lp "$LP" --argjson bp "$BP" \
	'{status:$s, findings:$v, regression:($r==1), line_percent:$lp, branch_percent:$bp}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
