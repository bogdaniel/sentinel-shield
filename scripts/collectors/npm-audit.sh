#!/bin/sh
# Sentinel Shield collector — npm audit (--json).
#   metadata.vulnerabilities.critical -> critical_vulnerabilities
#   metadata.vulnerabilities.high     -> high_vulnerabilities
#   metadata.vulnerabilities.moderate -> medium_vulnerabilities
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="npm_audit"
INPUT="reports/raw/npm-audit.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: npm-audit.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for `npm audit --json`.
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
	(.metadata.vulnerabilities // {}) as $v
	| {
		critical_vulnerabilities: ($v.critical // 0),
		high_vulnerabilities:     ($v.high // 0),
		medium_vulnerabilities:   ($v.moderate // 0)
	}' "$INPUT")

TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
