#!/bin/sh
# Sentinel Shield collector — focused / skipped test markers (normalized JSON).
#   .focused_test_violations        -> focused_test_violations
#   .skipped_test_marker_violations -> skipped_test_marker_violations
# Canonical raw shape (see scripts/runners/focused-tests.sh):
#   { "tool":"focused-tests", "status":"pass",
#     "focused_test_violations":0, "skipped_test_marker_violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="focused-tests"
INPUT="reports/raw/focused-tests.json"

usage() {
	cat <<'EOF'
Usage: focused-tests.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized focused-tests report.
Maps .focused_test_violations -> focused_test_violations and
.skipped_test_marker_violations -> skipped_test_marker_violations.
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

# Fail closed on a valid-JSON object that carries neither an explicit status nor any recognized
# metric key (e.g. a scanner error object): it must not derive a clean 0 pass.
jq -e '(type=="object" and (has("status") or has("findings") or has("focused_test_violations") or has("skipped_test_marker_violations") or has("violations"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error","findings":0}' '{}'; exit 0; }

FTV=$(jq '((.focused_test_violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
STM=$(jq '((.skipped_test_marker_violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")
SUM=$((FTV + STM))

if [ "$FTV" -gt 0 ] || [ "$STM" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson f "$FTV" --argjson s "$STM" \
	'{focused_test_violations:$f, skipped_test_marker_violations:$s}')
REPORT=$(jq -n --arg s "$STATUS" --argjson sum "$SUM" --argjson f "$FTV" --argjson sk "$STM" \
	'{status:$s, findings:$sum, focused_test_violations:$f, skipped_test_marker_violations:$sk}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
