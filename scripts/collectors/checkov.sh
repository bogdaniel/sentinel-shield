#!/bin/sh
# Sentinel Shield collector — checkov. Maps finding count -> iac_violations.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="checkov"
INPUT="reports/raw/checkov.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: checkov.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
N=$(jq '(if (.summary.failed?) != null then .summary.failed elif (.results.failed_checks?) != null then (.results.failed_checks|length) else 0 end) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, iac_violations:$n}')
OV=$(jq -n --argjson n "$N" '{iac_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
