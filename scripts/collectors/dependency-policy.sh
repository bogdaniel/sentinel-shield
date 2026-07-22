#!/bin/sh
# Sentinel Shield collector — dependency-policy. Maps violation count -> dependency_policy_violations.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="dependency-policy"
INPUT="reports/raw/dependency-policy.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: dependency-policy.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
jq -e '(type == "object" and (has("count") or has("violations"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { log_warn "$TOOL: report has neither .count nor .violations (malformed/error output); status=execution-error (fail-closed)"; ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error"}' '{}'; exit 0; }
N=$(jq '(.count // (.violations | length?) // 0) | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, dependency_policy_violations:$n}')
OV=$(jq -n --argjson n "$N" '{dependency_policy_violations:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
