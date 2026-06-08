#!/bin/sh
# Sentinel Shield collector — GitHub Actions pin audit.
#   unpinned refs -> unsafe_github_actions
# Input: reports/raw/github-actions-pins.json — an array of findings produced by
# scripts/audit-github-actions-pins.sh ([{file,line,type,ref,reason}, ...]).
# Complementary to actionlint/zizmor; the builder SUMS unsafe_github_actions across them.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="github_actions_pins"
INPUT="reports/raw/github-actions-pins.json"

usage() {
	cat <<'EOF'
Usage: github-actions-pins.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object for the GitHub Actions pin audit.
Input: array of unpinned-ref findings. Count -> unsafe_github_actions.
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

N=$(jq 'if type == "array" then length else 0 end' "$INPUT")
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, unpinned: $n}')
OV=$(jq -n --argjson n "$N" '{unsafe_github_actions: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
