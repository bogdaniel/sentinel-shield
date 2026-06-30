#!/bin/sh
# Sentinel Shield collector — TypeScript (tsc).
#   compiler errors -> type_errors
# `tsc --noEmit` does not emit JSON, so the canonical input is a NORMALIZED shape
# produced by the project/CI:
#     { "errors": N }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="typescript"
INPUT="reports/raw/typescript.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: typescript.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for normalized tsc output
({ "errors": N }).
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

N=$(jq '(.errors // 0)' "$INPUT")
case "$N" in '' | *[!0-9]*) log_error "$TOOL: .errors must be a non-negative integer, got '$N'"; exit 2 ;; esac

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, errors: $n}')
OV=$(jq -n --argjson n "$N" '{type_errors: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
