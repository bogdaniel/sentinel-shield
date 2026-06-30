#!/bin/sh
# Sentinel Shield collector — PHPStan (--error-format=json).
#   .totals.file_errors + .totals.errors -> type_errors
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="phpstan"
INPUT="reports/raw/phpstan.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: phpstan.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for PHPStan JSON output.
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

N=$(jq '((.totals.file_errors // 0) + (.totals.errors // 0))' "$INPUT")
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, errors: $n}')
OV=$(jq -n --argjson n "$N" '{type_errors: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
