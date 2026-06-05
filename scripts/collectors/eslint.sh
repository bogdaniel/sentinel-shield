#!/bin/sh
# Sentinel Shield collector — ESLint (--format json).
#
# First-pass, CONSERVATIVE and TUNABLE mapping (see docs/node-react-normalization.md):
#   total errorCount                         -> type_errors
#   total warningCount                       -> medium_vulnerabilities
#   severity-2 messages whose ruleId starts
#   with security/ or no-unsanitized/        -> high_vulnerabilities
#
# NOTE: a security-rule error is counted BOTH in type_errors (it is an errorCount)
# and in high_vulnerabilities (it is a security finding). This is deliberate and
# conservative — both gates should fire. Tune in your own fork if you prefer to
# exclude security errors from type_errors.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="eslint"
INPUT="reports/raw/eslint.json"

usage() {
	cat <<'EOF'
Usage: eslint.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for ESLint JSON output (array of
file results with errorCount/warningCount/messages[]).
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

# Compute counts defensively; tolerate non-array inputs by yielding zeros.
COUNTS=$(jq '
	if type == "array" then
		{
			errors:   ([ .[].errorCount? // 0 ] | add // 0),
			warnings: ([ .[].warningCount? // 0 ] | add // 0),
			security_errors: ([
				.[].messages[]?
				| select(.severity == 2 and ((.ruleId // "") | test("^(security/|no-unsanitized/)")))
			] | length)
		}
	else { errors: 0, warnings: 0, security_errors: 0 } end' "$INPUT")

ERRORS=$(printf '%s' "$COUNTS" | jq '.errors')
WARNINGS=$(printf '%s' "$COUNTS" | jq '.warnings')
SEC=$(printf '%s' "$COUNTS" | jq '.security_errors')

if [ "$ERRORS" -gt 0 ] || [ "$SEC" -gt 0 ]; then
	STATUS="fail"
elif [ "$WARNINGS" -gt 0 ]; then
	STATUS="warn"
else
	STATUS="pass"
fi

REPORT=$(jq -n --arg s "$STATUS" --argjson e "$ERRORS" --argjson w "$WARNINGS" --argjson sec "$SEC" \
	'{status: $s, errors: $e, warnings: $w, security_errors: $sec}')
OV=$(jq -n --argjson e "$ERRORS" --argjson w "$WARNINGS" --argjson sec "$SEC" \
	'{type_errors: $e, medium_vulnerabilities: $w, high_vulnerabilities: $sec}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
