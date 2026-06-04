#!/bin/sh
# Sentinel Shield collector — Deptrac (JSON report).
#   violation count -> architecture_violations
# Deptrac's JSON shape has varied across versions; parsing is defensive:
#   .report.violations (number) | .Report.Violations (number)
#   | .violations (array -> length, or number)
# Document/adjust to match your Deptrac version.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="deptrac"
INPUT="reports/raw/deptrac.json"

usage() {
	cat <<'EOF'
Usage: deptrac.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Deptrac JSON report.
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

N=$(jq '
	if (.report.violations | type) == "number" then .report.violations
	elif (.Report.Violations | type) == "number" then .Report.Violations
	elif (.violations | type) == "array" then (.violations | length)
	elif (.violations | type) == "number" then .violations
	else 0 end' "$INPUT")

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, violations: $n}')
OV=$(jq -n --argjson n "$N" '{architecture_violations: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
