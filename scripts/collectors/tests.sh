#!/bin/sh
# Sentinel Shield collector — tests (normalized JSON).
#   failures + errors -> test_failures
# Canonical shape: { "failures": 0, "errors": 0 }
# Producing workflows normalize their test runner output to this shape.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="tests"
INPUT="reports/raw/tests.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: tests.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for normalized test results
({ "failures": N, "errors": N }).
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

N=$(jq '((.failures // 0) + (.errors // 0))' "$INPUT")
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, failures: $n}')
OV=$(jq -n --argjson n "$N" '{test_failures: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
