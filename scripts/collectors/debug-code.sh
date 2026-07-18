#!/bin/sh
# Sentinel Shield collector — debug residue (normalized JSON).
#   .debug_code_violations -> debug_code_violations
# Canonical raw shape (see scripts/runners/debug-code.sh):
#   { "tool":"debug-code", "status":"pass", "debug_code_violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="debug-code"
INPUT="reports/raw/debug-code.json"

usage() {
	cat <<'EOF'
Usage: debug-code.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized debug-code report.
Maps .debug_code_violations -> debug_code_violations.
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

DCV=$(jq '((.debug_code_violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT")

if [ "$DCV" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson n "$DCV" '{debug_code_violations:$n}')
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$DCV" \
	'{status:$s, findings:$n, debug_code_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
