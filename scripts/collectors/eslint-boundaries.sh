#!/bin/sh
# Sentinel Shield collector — ESLint architecture-boundary rules (JS/TS producer).
#   architecture-boundary violations -> architecture_violations
#
# Counts ONLY boundary rules — general ESLint findings already map elsewhere
# (collectors/eslint.sh -> style/type channels), so a project is never charged twice:
#   boundaries/*            (eslint-plugin-boundaries)
#   import/no-restricted-paths
#   no-restricted-imports
#
# Accepts BOTH:
#   1. ESLint's native JSON array: [ { "filePath":..., "messages":[{"ruleId":...}] } ]
#   2. The normalized architecture raw contract (what runners/eslint-boundaries.sh writes).
#
# Fail closed: status-bearing reports keep their status; unknown status or unrecognized
# shape -> execution-error, never a clean 0.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"

TOOL="eslint-boundaries"
INPUT="reports/raw/eslint-boundaries.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: eslint-boundaries.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for ESLint boundary findings (native
ESLint JSON or the normalized architecture contract). Counts ONLY architecture-boundary
rules (boundaries/*, import/no-restricted-paths, no-restricted-imports).
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
arch_passthrough_status "$TOOL" "$INPUT"

SHAPE=$(jq -r '
	if (type == "array") then
		(if (length == 0) or (all(.[]; type=="object" and has("messages"))) then "eslint" else "unknown" end)
	elif (type == "object") and ((.violations? | type) == "number" or (.violations? | type) == "array") then "normalized"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')

if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized ESLint/architecture JSON shape in '$INPUT'; status=execution-error (never reported as clean)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","violations":0,"reason":"unrecognized eslint-boundaries report shape"}' '{}'
	exit 0
fi

if [ "$SHAPE" = "eslint" ]; then
	# ONLY architecture-boundary rule ids are counted here.
	N=$(arch_count "$INPUT" '[ .[].messages[]? | select((.ruleId // "") | test("^boundaries/|^import/no-restricted-paths$|^no-restricted-imports$")) ] | length')
	RULES=$(jq '[ .[].messages[]? | (.ruleId // "") | select(test("^boundaries/|^import/no-restricted-paths$|^no-restricted-imports$")) ] | unique | length' "$INPUT")
else
	N=$(arch_count "$INPUT" 'if ((.violations|type)=="array") then (.violations|length) else .violations end')
	RULES=$(arch_num "$INPUT" '.rule_count // 0')
fi
case "$RULES" in '' | *[!0-9]*) RULES=0 ;; esac
CTX=$(jq 'if type=="object" then (.context_count // 0) else 0 end | if type=="number" and . >= 0 then floor else 0 end' "$INPUT" 2>/dev/null || printf 0)

arch_emit "$TOOL" "$N" "$RULES" "$CTX"
