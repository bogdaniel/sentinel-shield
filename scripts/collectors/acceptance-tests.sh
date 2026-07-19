#!/bin/sh
# Sentinel Shield collector — ATDD acceptance-test evidence (v2.2.0).
#
#   .tests                        -> acceptance_test_count      (informational)
#   .failures                     -> acceptance_test_failures
#   .missing_acceptance_evidence  -> missing_acceptance_evidence
#
# Canonical raw shape (templates/raw/acceptance-tests.example.json):
#   { "tool":"acceptance-tests", "status":"findings",
#     "tests":48, "failures":2, "skipped":1, "missing_acceptance_evidence":false }
#
# Producer-agnostic: Playwright, Cypress, Behat or Cucumber run at acceptance level, or any
# JUnit XML converted by scripts/adapters/junit-to-acceptance-tests.*.
#
# DOCUMENTED CHOICE — tests=0: an acceptance report that executed ZERO tests is treated as
# MISSING acceptance evidence, not as a clean pass. A suite that ran nothing proves nothing,
# and the whole point of this gate is that "we never ran it" must not read as "we are green".
#
# Fail closed: unknown status -> execution-error (missing_acceptance_evidence=true); a
# status=execution-error report counts as missing evidence; malformed counts ->
# execution-error; missing/empty report -> unavailable; invalid JSON -> exit 2.
#
# Scope honesty: passing acceptance tests do not mean the product owner accepted anything.
# Sentinel Shield does not replace product-owner acceptance (docs/acceptance-test-evidence.md).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"

TOOL="acceptance-tests"
INPUT="reports/raw/acceptance-tests.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: acceptance-tests.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized acceptance-tests report.
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

# The SAFE zero for a report that could not be read. missing_acceptance_evidence is
# deliberately NOT in the summary overrides: it is derived by the BUILDER, the only component
# that knows whether acceptance evidence was EXPECTED here. Emitting it from the collector
# would demand a browser acceptance suite from every project. The builder reads this
# collector's STATUS plus the missing_acceptance_evidence flag in its tool_report.
UNKNOWN_OV='{"acceptance_test_count":0,"acceptance_test_failures":0}'
UNKNOWN_REPORT_EXTRAS='{"missing_acceptance_evidence":true}'
UNKNOWN_REPORT='{"status":"unavailable","missing_acceptance_evidence":true}'

if [ ! -f "$INPUT" ] || [ ! -s "$INPUT" ]; then
	ss_require_jq
	log_warn "$TOOL: input '$INPUT' missing or empty; status=unavailable (no acceptance evidence)"
	ss_emit_collector "$TOOL" "unavailable" "$UNKNOWN_REPORT" "$UNKNOWN_OV"
	exit 0
fi
ss_collector_guard "$TOOL" "$INPUT"
td_passthrough_status "$TOOL" "$INPUT" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# Recognized shape: an object carrying a test count, a failure count, or the missing flag.
SHAPE=$(jq -r '
	if (type != "object") then "unknown"
	elif ((.tests? | type) == "number") then "ok"
	elif ((.failures? | type) == "number") then "ok"
	elif ((.missing_acceptance_evidence? | type) == "boolean") then "ok"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')
if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized acceptance-tests shape in '$INPUT'; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --argjson x "$UNKNOWN_REPORT_EXTRAS" '{status:"execution-error",reason:"unrecognized report shape"} + $x')" "$UNKNOWN_OV"
	exit 0
fi

MISSING=$(td_flag "$INPUT" '.missing_acceptance_evidence')
[ "$MISSING" = "invalid" ] && td_bad_count "$TOOL" "missing_acceptance_evidence flag" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

TESTS=$(td_count "$INPUT" '.tests // 0')
[ "$TESTS" = "invalid" ] && td_bad_count "$TOOL" "tests count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"
FAILS=$(td_count "$INPUT" '.failures // 0')
[ "$FAILS" = "invalid" ] && td_bad_count "$TOOL" "failures count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"
SKIP=$(td_num "$INPUT" '.skipped // 0')

# tests=0 -> missing evidence (see the DOCUMENTED CHOICE note above).
if [ "$TESTS" -eq 0 ] && [ "$MISSING" != "true" ]; then
	MISSING=true
	log_warn "$TOOL: report ran but executed 0 acceptance tests; treated as missing_acceptance_evidence"
fi

if [ "$MISSING" = "true" ] || [ "$FAILS" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

MJ=$([ "$MISSING" = "true" ] && printf true || printf false)
OV=$(jq -n --argjson t "$TESTS" --argjson f "$FAILS" '{
	acceptance_test_count:$t, acceptance_test_failures:$f }')
REPORT=$(jq -n --arg s "$STATUS" --argjson t "$TESTS" --argjson f "$FAILS" \
	--argjson sk "$SKIP" --argjson m "$MJ" '{
	status:$s, findings:$f, tests:$t, failures:$f, skipped:$sk,
	acceptance_test_count:$t, acceptance_test_failures:$f,
	missing_acceptance_evidence:$m }')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
