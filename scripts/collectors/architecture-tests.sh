#!/bin/sh
# Sentinel Shield collector — architecture-tests. Maps violation count -> architecture_violations.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="architecture-tests"
INPUT="reports/raw/architecture-tests.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: architecture-tests.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
N=$(jq '(.violations // .failures // 0) | (if type=="array" then length else . end) | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, architecture_violations:$n}')
OV=$(jq -n --argjson n "$N" '{architecture_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
