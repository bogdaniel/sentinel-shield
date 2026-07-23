#!/bin/sh
# Sentinel Shield collector — BDD behavior-specification evidence (v2.2.0).
#
#   .spec_count + .scenario_count       -> behavior_spec_count      (informational)
#   .orphan_behavior_specifications     -> orphan_behavior_specifications
#   .missing_behavior_specification     -> missing_behavior_specification
#
# Canonical raw shape (templates/raw/behavior-specs.example.json):
#   { "tool":"behavior-specs", "status":"pass", "spec_count":12, "scenario_count":34,
#     "orphan_behavior_specifications":0, "missing_behavior_specification":false,
#     "failures":[] }
#
# Producer-agnostic: Behat, Cucumber.js, a Pest/PHPUnit feature suite, or a 20-line script of
# your own can emit this contract (scripts/adapters/*-to-behavior-specs.*).
#
# Fail closed: unknown status -> execution-error (with missing_behavior_specification=true);
# malformed counts -> execution-error; missing/empty report -> unavailable; invalid JSON ->
# exit 2.
#
# Scope honesty: counting scenarios does not measure whether they describe the right behavior.
# Sentinel Shield does not guarantee BDD quality (docs/bdd-atdd-evidence.md).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"

TOOL="behavior-specs"
INPUT="reports/raw/behavior-specs.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: behavior-specs.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized behavior-specs report.
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

# The SAFE zero for a report that could not be read. missing_behavior_specification is
# deliberately NOT in the summary overrides: it is derived by the BUILDER, the only component
# that knows whether BDD evidence was EXPECTED here. Emitting it from the collector would mark
# every project that never opted into BDD as missing it — exactly the "libraries forced to
# carry Gherkin" outcome this feature must avoid. The builder reads this collector's STATUS
# plus the missing_behavior_specification flag in its tool_report.
UNKNOWN_OV='{"behavior_spec_count":0,"orphan_behavior_specifications":0}'
UNKNOWN_REPORT_EXTRAS='{"missing_behavior_specification":true}'
UNKNOWN_REPORT='{"status":"unavailable","missing_behavior_specification":true}'

if [ ! -f "$INPUT" ] || [ ! -s "$INPUT" ]; then
	ss_require_jq
	log_warn "$TOOL: input '$INPUT' missing or empty; status=unavailable (no behavior-spec evidence)"
	ss_emit_collector "$TOOL" "unavailable" "$UNKNOWN_REPORT" "$UNKNOWN_OV"
	exit 0
fi
ss_collector_guard "$TOOL" "$INPUT"
td_passthrough_status "$TOOL" "$INPUT" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# Recognized shape: an object carrying a spec/scenario count or the missing flag.
SHAPE=$(jq -r '
	if (type != "object") then "unknown"
	elif ((.spec_count? | type) == "number") then "ok"
	elif ((.scenario_count? | type) == "number") then "ok"
	elif ((.missing_behavior_specification? | type) == "boolean") then "ok"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')
if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized behavior-specs shape in '$INPUT'; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --argjson x "$UNKNOWN_REPORT_EXTRAS" '{status:"execution-error",reason:"unrecognized report shape"} + $x')" "$UNKNOWN_OV"
	exit 0
fi

MISSING=$(td_flag "$INPUT" '.missing_behavior_specification')
[ "$MISSING" = "invalid" ] && td_bad_count "$TOOL" "missing_behavior_specification flag" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

SPECS=$(td_count "$INPUT" '.spec_count // 0')
[ "$SPECS" = "invalid" ] && td_bad_count "$TOOL" "spec_count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"
SCEN=$(td_count "$INPUT" '.scenario_count // 0')
[ "$SCEN" = "invalid" ] && td_bad_count "$TOOL" "scenario_count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"
ORPH=$(td_count "$INPUT" '.orphan_behavior_specifications // 0')
[ "$ORPH" = "invalid" ] && td_bad_count "$TOOL" "orphan_behavior_specifications count" "$UNKNOWN_OV" "$UNKNOWN_REPORT_EXTRAS"

# behavior_spec_count aggregates specs AND scenarios: a producer that reports only one of the
# two still contributes a truthful count of "behavior descriptions that exist".
COUNT=$((SPECS + SCEN))

# A producer that ran but found NOTHING has not produced behavior-spec evidence. Saying
# "0 specs, all clean" would be exactly the fake pass this feature exists to prevent.
if [ "$COUNT" -eq 0 ] && [ "$MISSING" != "true" ]; then
	MISSING=true
	log_warn "$TOOL: report ran but declares 0 specs and 0 scenarios; treated as missing_behavior_specification"
fi

if [ "$MISSING" = "true" ] || [ "$ORPH" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi

MJ=$([ "$MISSING" = "true" ] && printf true || printf false)
OV=$(jq -n --argjson c "$COUNT" --argjson o "$ORPH" '{
	behavior_spec_count:$c, orphan_behavior_specifications:$o }')
REPORT=$(jq -n --arg s "$STATUS" --argjson sp "$SPECS" --argjson sc "$SCEN" \
	--argjson c "$COUNT" --argjson o "$ORPH" --argjson m "$MJ" '{
	status:$s, findings:$o, spec_count:$sp, scenario_count:$sc,
	behavior_spec_count:$c, orphan_behavior_specifications:$o,
	missing_behavior_specification:$m }')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
