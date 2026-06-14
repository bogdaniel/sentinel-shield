#!/bin/sh
# Sentinel Shield collector — dependency-check. Maps vulnerability severities to vuln buckets
# (critical/high/medium_vulnerabilities). Accepts native format or a normalized
# {critical,high,medium} object. Severity parsing is best-effort; see docs.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="dependency-check"
INPUT="reports/raw/dependency-check.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: dependency-check.sh [--input <path>] [--tool-name <name>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
# Severity vocab is normalized: Dependency-Check mixes NVD/CVSS labels (CRITICAL/HIGH/MEDIUM/LOW)
# with the npm Node-Audit / RetireJS labels (critical/high/moderate/low). npm "MODERATE" IS the
# medium bucket — map it so real moderate CVEs are counted (and gated in strict), not dropped.
# (v0.1.27: surfaced by a real dependency-rich consumer run — 3 moderate npm CVEs were being lost.)
OV=$(jq 'if has("dependencies") then ([.dependencies[]?.vulnerabilities[]?.severity // empty | ascii_upcase | if . == "MODERATE" then "MEDIUM" else . end]) as $s | {critical_vulnerabilities:([$s[]|select(.=="CRITICAL")]|length), high_vulnerabilities:([$s[]|select(.=="HIGH")]|length), medium_vulnerabilities:([$s[]|select(.=="MEDIUM")]|length)} else {critical_vulnerabilities:(.critical//0), high_vulnerabilities:(.high//0), medium_vulnerabilities:(.medium//0)} end' "$INPUT")
TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status:$s, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
