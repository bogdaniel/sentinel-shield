#!/bin/sh
# Sentinel Shield collector — Gitleaks. Maps secret findings -> summary.secrets.
# Supports an array of findings, or an object with a `findings` array.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="gitleaks"
INPUT="reports/raw/gitleaks.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: gitleaks.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Gitleaks JSON report.
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
# Fail closed on a report whose SHAPE this collector does not recognize (v2.0.2).
ss_shape_or_fail "$TOOL" "$INPUT" '(type == "array") or (type == "object" and ((.findings? | type) == "array"))' '{"secrets":0}'

N=$(jq '
	if type == "array" then length
	elif (type == "object" and (.findings | type) == "array") then (.findings | length)
	else 0 end' "$INPUT")

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, findings: $n}')
OV=$(jq -n --argjson n "$N" '{secrets: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
