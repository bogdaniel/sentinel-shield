#!/bin/sh
# Sentinel Shield collector — composer audit (--format=json).
#   critical -> critical_vulnerabilities
#   high     -> high_vulnerabilities
#   medium/moderate -> medium_vulnerabilities
# Expects { "advisories": { "<pkg>": [ { "severity": "high", ... } ] } }.
# NOTE: composer audit JSON has varied across versions; parsing is defensive and
# may need tuning. Severity strings are lowercased before matching.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="composer_audit"
INPUT="reports/raw/composer-audit.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: composer-audit.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for `composer audit --format=json`.
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
	[ (.advisories // {}) | to_entries[] | .value[]? | (.severity // "") | ascii_downcase ] as $s
	| {
		critical_vulnerabilities: ([ $s[] | select(. == "critical") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "high") ] | length),
		medium_vulnerabilities:   ([ $s[] | select(. == "medium" or . == "moderate") ] | length)
	}' "$INPUT")

TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
