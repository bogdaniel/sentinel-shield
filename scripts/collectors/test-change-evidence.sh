#!/bin/sh
# Sentinel Shield collector — TDD proxy: production change without test change (v2.2.0).
#
#   .production_change_without_test_change -> production_change_without_test_change
#   .missing_test_change_evidence          -> missing_test_change_evidence
#   .expired_waivers                       -> expired_exceptions
#
# Canonical raw shape (see scripts/runners/test-change-evidence.sh and
# templates/raw/test-change-evidence.example.json):
#   { "tool":"test-change-evidence", "status":"findings",
#     "production_changed_files":3, "test_changed_files":0,
#     "production_change_without_test_change":1, "missing_test_change_evidence":false }
#
# Fail closed: unknown status -> execution-error (with missing_test_change_evidence=true);
# malformed count/flag -> execution-error; missing/empty report -> unavailable; invalid JSON ->
# exit 2. A run that did not happen is NEVER reported as a clean 0.
#
# Scope honesty: this is a PROXY for test-first discipline, not proof of it
# (docs/tdd-evidence-policy.md).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"

TOOL="test-change-evidence"
INPUT="reports/raw/test-change-evidence.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: test-change-evidence.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized test-change-evidence report.
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

# The SAFE zero for a report that could not be read. missing_test_change_evidence is
# deliberately NOT in the summary overrides: like missing_architecture_evidence (v2.1.0), it is
# derived by the BUILDER, which is the only component that knows whether this evidence was
# EXPECTED for this profile. A collector that emitted it directly would mark the gate missing
# for every project that never wired the producer up. The signal the builder reads is this
# collector's STATUS plus the missing_test_change_evidence flag in its tool_report.
UNKNOWN_OV='{"production_change_without_test_change":0}'
UNKNOWN_REPORT_EXTRAS='{"missing_test_change_evidence":true}'
UNKNOWN_REPORT='{"status":"unavailable","missing_test_change_evidence":true}'

if [ ! -f "$INPUT" ] || [ ! -s "$INPUT" ]; then
	ss_require_jq
	log_warn "$TOOL: input '$INPUT' missing or empty; status=unavailable (missing changed-file evidence)"
	ss_emit_collector "$TOOL" "unavailable" "$UNKNOWN_REPORT" "$UNKNOWN_OV"
	exit 0
fi
ss_collector_guard "$TOOL" "$INPUT"
td_passthrough_status "$TOOL" "$INPUT" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# Recognized evidence shape: an object carrying the violation count or the missing-evidence
# flag. Anything else fails closed — a valid-JSON document of the wrong shape is not evidence.
SHAPE=$(jq -r '
	if (type != "object") then "unknown"
	elif ((.production_change_without_test_change? | type) == "number") then "ok"
	elif ((.missing_test_change_evidence? | type) == "boolean") then "ok"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')
if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized test-change-evidence shape in '$INPUT'; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --argjson x "$UNKNOWN_REPORT_EXTRAS" '{status:"execution-error",reason:"unrecognized report shape"} + $x')" "$UNKNOWN_OV"
	exit 0
fi

MISSING=$(td_flag "$INPUT" '.missing_test_change_evidence')
[ "$MISSING" = "invalid" ] && td_bad_count "$TOOL" "missing_test_change_evidence flag" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# The violation count is NOT coerced: a recognized shape carrying a malformed/negative count
# fails closed rather than being reported as clean.
N=$(td_count "$INPUT" '.production_change_without_test_change // 0')
[ "$N" = "invalid" ] && td_bad_count "$TOOL" "production_change_without_test_change count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# Expired TDD waivers ride the long-standing expired_exceptions gate (which blocks in EVERY
# mode) rather than inventing a parallel counter: an expired waiver is an expired exception.
EXPW=$(td_num "$INPUT" '.expired_waivers // 0')
PROD=$(td_num "$INPUT" '.production_changed_files // 0')
TESTS=$(td_num "$INPUT" '.test_changed_files // 0')

if [ "$MISSING" = "true" ] || [ "$N" -gt 0 ] || [ "$EXPW" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

OV=$(jq -n --argjson v "$N" --argjson e "$EXPW" '{
		production_change_without_test_change:$v,
		expired_exceptions:$e }')
REPORT=$(jq -n --arg s "$STATUS" --argjson v "$N" --argjson p "$PROD" --argjson t "$TESTS" \
	--argjson e "$EXPW" --argjson m "$([ "$MISSING" = "true" ] && printf true || printf false)" '{
		status:$s, findings:$v,
		production_changed_files:$p, test_changed_files:$t,
		production_change_without_test_change:$v,
		missing_test_change_evidence:$m, expired_waivers:$e }')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
