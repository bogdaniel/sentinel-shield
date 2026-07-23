#!/bin/sh
# Sentinel Shield collector — actionlint.
#   errors -> unsafe_github_actions
# actionlint's native JSON support is inconsistent across versions, so the
# canonical input is a NORMALIZED shape: { "errors": N, "warnings": N }.
# A native array of error objects is also accepted (length = errors).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="actionlint"
INPUT="reports/raw/actionlint.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: actionlint.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for actionlint output.
Canonical input: { "errors": N, "warnings": N }. A native error array is also accepted.
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

# Fail CLOSED on an unrecognized shape: a valid-JSON error object would otherwise coerce to
# 0 findings via the else-branch and clear the unsafe_github_actions gate.
jq -e '(type == "array" or (type == "object" and has("errors"))) or . == {}' "$INPUT" >/dev/null 2>&1 \
	|| { log_warn "$TOOL: unrecognized report shape (malformed/error output); status=execution-error (fail-closed)"; ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error"}' '{}'; exit 0; }

N=$(jq '
	if type == "array" then length
	elif (type == "object" and (.errors | type) == "number") then .errors
	elif (type == "object" and (.errors | type) == "array") then (.errors | length)
	else 0 end' "$INPUT")
case "$N" in ''|*[!0-9]*) log_error "$TOOL: non-integer count"; exit 2 ;; esac

if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, violations: $n}')
OV=$(jq -n --argjson n "$N" '{unsafe_github_actions: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
