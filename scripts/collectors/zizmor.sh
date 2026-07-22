#!/bin/sh
# Sentinel Shield collector — zizmor (GitHub Actions auditing).
#   findings -> unsafe_github_actions
# zizmor output format varies; parsing is defensive:
#   array of findings (length) | object with .findings array (length)
#   | normalized { "findings": N }.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="zizmor"
INPUT="reports/raw/zizmor.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: zizmor.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for zizmor output.
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

jq -e '(type == "array" or (type == "object" and has("findings"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { log_warn "$TOOL: unrecognized report shape (malformed/error output); status=execution-error (fail-closed)"; ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error"}' '{}'; exit 0; }

N=$(jq '(
	if type == "array" then length
	elif (type == "object" and (.findings | type) == "array") then (.findings | length)
	elif (type == "object" and (.findings | type) == "number") then .findings
	else 0 end) // 0 | floor' "$INPUT")
case "$N" in '' | *[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, violations: $n}')
OV=$(jq -n --argjson n "$N" '{unsafe_github_actions: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
