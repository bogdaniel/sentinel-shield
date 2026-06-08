#!/bin/sh
# Sentinel Shield collector — trufflehog. Maps finding count -> secrets.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="trufflehog"
INPUT="reports/raw/trufflehog.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: trufflehog.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
N=$(jq '[ (if type=="array" then .[] elif has("results") then .results[] else empty end) | select((.Verified == true) or (.verified == true) or ((has("Verified") or has("verified")) | not)) ] | length // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, secrets:$n}')
OV=$(jq -n --argjson n "$N" '{secrets:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
