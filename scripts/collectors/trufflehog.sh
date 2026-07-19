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
# Count EVERY finding, verified or not. The previous filter excluded any finding
# explicitly marked Verified:false — but TruffleHog reports unverified findings by
# default, and non-verifiable custom detectors ALWAYS report Verified:false. `secrets`
# blocks in every mode including report-only, so this is the one gate an adopter leans on
# hardest, and a real leaked credential the tool merely could not actively verify
# contributed nothing. docs/severity-policy.md lists "a leaked active secret" as Critical
# with no verification qualifier.
# Verified/unverified are still reported separately so triage can prioritise.
N=$(jq '[ (if type=="array" then .[] elif has("results") then .results[] else empty end) ] | length // 0 | floor' "$INPUT")
NVERIF=$(jq '[ (if type=="array" then .[] elif has("results") then .results[] else empty end)
	| select((.Verified == true) or (.verified == true)) ] | length // 0 | floor' "$INPUT")
case "$NVERIF" in ''|*[!0-9]*) NVERIF=0 ;; esac
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" --argjson v "$NVERIF" '{status:$s, secrets:$n, verified:$v, unverified:($n - $v)}')
OV=$(jq -n --argjson n "$N" '{secrets:$n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
