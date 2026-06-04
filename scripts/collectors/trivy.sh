#!/bin/sh
# Sentinel Shield collector — Trivy. Maps vulnerability severities to vuln buckets.
#   CRITICAL -> critical_vulnerabilities
#   HIGH     -> high_vulnerabilities
#   MEDIUM   -> medium_vulnerabilities
# Supports .Results[].Vulnerabilities[].Severity (image/fs JSON).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="trivy"
INPUT="reports/raw/trivy.json"

usage() {
	cat <<'EOF'
Usage: trivy.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Trivy JSON report.
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

OV=$(jq '
	[ .Results[]?.Vulnerabilities[]?.Severity // empty | ascii_upcase ] as $s
	| {
		critical_vulnerabilities: ([ $s[] | select(. == "CRITICAL") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "HIGH") ] | length),
		medium_vulnerabilities:   ([ $s[] | select(. == "MEDIUM") ] | length)
	}' "$INPUT")

TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
