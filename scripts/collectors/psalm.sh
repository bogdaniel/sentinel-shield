#!/bin/sh
# Sentinel Shield collector — Psalm (--output-format=json).
#   issue count -> type_errors
# Supports an array of issues, or an object with an `issues` array.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="psalm"
INPUT="reports/raw/psalm.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: psalm.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for Psalm JSON output.
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

# Fail CLOSED on an unrecognized shape (else-branch 0 would clear the type_errors gate).
jq -e 'type == "array" or (type == "object" and has("issues"))' "$INPUT" >/dev/null 2>&1 \
	|| { log_error "$TOOL: unrecognized report shape (malformed/error output); refusing to clear the gate"; exit 2; }

N=$(jq '
	if type == "array" then length
	elif (type == "object" and (.issues | type) == "array") then (.issues | length)
	else 0 end' "$INPUT")

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, errors: $n}')
OV=$(jq -n --argjson n "$N" '{type_errors: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
