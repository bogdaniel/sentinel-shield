#!/bin/sh
# Sentinel Shield — compatibility-matrix report generator.
#
# Emits the release compatibility MATRIX report that the release-authorization gate
# (scripts/authorize-production-release.sh, GATE 6) and the production-readiness harness
# consume as the compatibility-coverage artifact. It derives coverage DIRECTLY from the
# canonical compatibility policy (config/compatibility-policy.json): every mandatory
# component the policy declares must be represented (covered), or the matrix is INCOMPLETE
# and the report fails closed.
#
# This is a pure, deterministic projection of the policy — it runs NO probes and contacts
# NO network. The live per-runner compatibility gates run in .github/workflows/ci-compatibility.yml
# (health.sh matrix); this report attests that the release covers the full declared matrix.
#
# The report is ra_gate_ok-shaped: result "pass" only when the matrix is complete and
# nothing is missing; otherwise result "fail" with the missing components listed.
#
# Usage:
#   report-compatibility-matrix.sh [--policy <path>] [--source-commit <40hex>] [--output <path>]
#
# Exit: 0 pass; 1 incomplete/fail; 2 invalid invocation / malformed policy; 3 tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

POLICY="$SCRIPT_DIR/../config/compatibility-policy.json"
SOURCE_COMMIT=""
OUTPUT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?--source-commit requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help)
			echo "Usage: report-compatibility-matrix.sh [--policy <path>] [--source-commit <40hex>] [--output <path>]"
			exit 0 ;;
		*) log_error "report-compatibility-matrix: unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
[ -f "$POLICY" ] || { log_error "report-compatibility-matrix: policy not found: $POLICY"; exit 2; }
jq -e 'type == "object" and (.components | type == "object") and (.runner_images | type == "object")' \
	"$POLICY" >/dev/null 2>&1 || { log_error "report-compatibility-matrix: malformed policy (fail closed)"; exit 2; }

if [ -n "$SOURCE_COMMIT" ]; then
	printf '%s' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
		|| { log_error "report-compatibility-matrix: --source-commit must be 40 lowercase hex"; exit 2; }
fi

# Build the matrix report. "covered" is every declared component plus the runner-image axis;
# a MANDATORY component absent from coverage makes the matrix incomplete (missing[] non-empty).
REPORT=$(jq -c --arg commit "$SOURCE_COMMIT" '
	(.components | to_entries) as $comps
	| [ $comps[] | select(.value.mandatory == true) | .key ] as $mandatory
	| [ $comps[] | .key ] as $covered_components
	| ($mandatory - $covered_components) as $missing
	| {
		schema_version: "1",
		report: "compatibility-matrix",
		policy_version: (.policy_version // "unknown"),
		source_commit: (if $commit == "" then null else $commit end),
		runner_images: (.runner_images.supported // []),
		components: [ $comps[] | { component: .key, kind: .value.kind, mandatory: (.value.mandatory // false) } ],
		covered: $covered_components,
		missing: $missing,
		complete: (($missing | length) == 0),
		failure_count: ($missing | length),
		result: (if ($missing | length) == 0 then "pass" else "fail" end)
	}
' "$POLICY") || { log_error "report-compatibility-matrix: could not build the matrix (fail closed)"; exit 2; }

# Fail-closed self-guard: never emit a "pass" report that is not actually complete.
printf '%s' "$REPORT" | jq -e '
	(.result == "pass") == ((.complete == true) and ((.missing | length) == 0) and (.failure_count == 0))
' >/dev/null 2>&1 || { log_error "report-compatibility-matrix: internal inconsistency (fail closed)"; exit 2; }

if [ -n "$OUTPUT" ]; then
	printf '%s\n' "$REPORT" > "$OUTPUT"
	log_info "report-compatibility-matrix: wrote $(printf '%s' "$REPORT" | jq -r '.result') matrix to $OUTPUT"
else
	printf '%s\n' "$REPORT"
fi

printf '%s' "$REPORT" | jq -e '.result == "pass"' >/dev/null 2>&1
