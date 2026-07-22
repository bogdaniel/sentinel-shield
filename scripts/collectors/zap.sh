#!/bin/sh
# Sentinel Shield collector — zap. Maps finding count -> dast_findings.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# Default = ZAP baseline (passive) report. A ZAP FULL (active) report lives at
# reports/raw/zap-full.json; pass it via --input and the tool label auto-promotes to
# "zap-full" (distinct dast_findings source). Override with --report-kind/--tool-name.
TOOL=""
KIND=""
INPUT="reports/raw/zap.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  --report-kind) KIND="${2:?--report-kind requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: zap.sh [--input <path>] [--report-kind baseline|full] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
# Resolve the report kind: explicit --report-kind wins; else auto-detect from the input
# basename (a name containing "zap-full" => full); else default to baseline.
case "$KIND" in
  baseline|full) : ;;
  "") case "$(basename "$INPUT")" in *zap-full*) KIND="full" ;; *) KIND="baseline" ;; esac ;;
  *) log_error "--report-kind must be 'baseline' or 'full'"; exit 2 ;;
esac
# Resolve the tool label: explicit --tool-name wins; else derive from the report kind so a
# full report maps to dast_findings under a distinct "zap-full" label.
if [ -z "$TOOL" ]; then
  case "$KIND" in full) TOOL="zap-full" ;; *) TOOL="zap" ;; esac
fi
ss_collector_guard "$TOOL" "$INPUT"
jq -e '(type == "object" and (has("site") or has("findings"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { log_warn "$TOOL: unrecognized report shape (malformed/error output); status=execution-error (fail-closed)"; ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error"}' '{}'; exit 0; }
N=$(jq '(if has("site") then ([.site[]?.alerts[]? | select(((.riskcode // "0")|tonumber) >= 2)] | length) elif has("findings") then (if (.findings|type)=="array" then (.findings|length) else .findings end) else 0 end) // 0 | floor' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status:$s, dast_findings:$n}')
OV=$(jq -n --argjson n "$N" '{dast_findings:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
