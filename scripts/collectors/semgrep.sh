#!/bin/sh
# Sentinel Shield collector — Semgrep. Maps result severities to vuln buckets.
#   ERROR/CRITICAL -> critical_vulnerabilities
#   WARNING/HIGH   -> high_vulnerabilities
#   INFO/MEDIUM    -> medium_vulnerabilities
# NOTE: severity->bucket mapping is conservative and may need project tuning.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="semgrep"
INPUT="reports/raw/semgrep.json"

usage() {
	cat <<'EOF'
Usage: semgrep.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Semgrep JSON report (.results[]).
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
	[ .results[]?.extra.severity // empty | ascii_upcase ] as $s
	| {
		critical_vulnerabilities: ([ $s[] | select(. == "ERROR" or . == "CRITICAL") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "WARNING" or . == "HIGH") ] | length),
		medium_vulnerabilities:   ([ $s[] | select(. == "INFO" or . == "MEDIUM") ] | length)
	}' "$INPUT")

TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
