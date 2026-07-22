#!/bin/sh
# Sentinel Shield collector — kuzushi. Maps finding count -> ai_review_findings.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="kuzushi"
INPUT="reports/raw/kuzushi.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: kuzushi.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
jq -e 'type == "array" or (type == "object" and has("findings"))' "$INPUT" >/dev/null 2>&1 \
	|| { log_error "$TOOL: unrecognized report shape (malformed/error output); refusing to clear the gate"; exit 2; }
N=$(jq '(if (.findings|type)=="array" then (.findings|length) elif (.findings|type)=="number" then .findings elif type=="array" then length else 0 end) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="warn"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, ai_review_findings:$n}')
OV=$(jq -n --argjson n "$N" '{ai_review_findings:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
