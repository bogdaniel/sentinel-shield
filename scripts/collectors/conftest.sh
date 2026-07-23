#!/bin/sh
# Sentinel Shield collector — conftest. Maps finding count -> iac_violations.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="conftest"
INPUT="reports/raw/conftest.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: conftest.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
jq -e '(type == "array" or (type == "object" and has("failures"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { log_warn "$TOOL: unrecognized report shape (malformed/error output); status=execution-error (fail-closed)"; ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error"}' '{}'; exit 0; }
N=$(jq '([ (if type=="array" then .[] else . end) | (.failures // []) | length ] | add // 0) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, iac_violations:$n}')
OV=$(jq -n --argjson n "$N" '{iac_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
