#!/bin/sh
# Sentinel Shield collector — Hadolint (-f json).
#   error/warning findings -> unsafe_docker
# Hadolint JSON is an array of { "level": "error|warning|info|style", ... }.
# Conservative: count error + warning (info/style are ignored).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="hadolint"
INPUT="reports/raw/hadolint.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: hadolint.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Hadolint JSON report.
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

# Fail CLOSED on non-array input: hadolint JSON is an array; an error object would otherwise
# coerce to 0 and clear the unsafe_docker gate.
jq -e 'type == "array"' "$INPUT" >/dev/null 2>&1 \
	|| { log_error "$TOOL: report is not a JSON array (malformed/error output); refusing to clear the gate"; exit 2; }

N=$(jq '
	if type == "array" then
		[ .[]? | (.level // "") | ascii_downcase | select(. == "error" or . == "warning") ] | length
	else 0 end' "$INPUT")

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, violations: $n}')
OV=$(jq -n --argjson n "$N" '{unsafe_docker: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
