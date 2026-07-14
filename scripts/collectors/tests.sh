#!/bin/sh
# Sentinel Shield collector — tests (normalized JSON).
#   failures + errors -> test_failures
# Canonical shape: { "failures": 0, "errors": 0 }
# Producing workflows normalize their test runner output to this shape.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="tests"
INPUT="reports/raw/tests.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: tests.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for normalized test results
({ "failures": N, "errors": N }).
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

# num <key> — numeric value of .<key>, floored, or 0 for absent/non-numeric.
num() { jq --arg k "$1" '((.[$k] // 0) | if (type=="number" and . >= 0) then floor else 0 end)' "$INPUT"; }

N=$(jq '((.failures // 0) + (.errors // 0))' "$INPUT")
TESTS=$(num tests); SKIP=$(num skipped)
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
# test_count / skipped_tests are v2.1 additive informational-plus-gate signals; empty_test_suite /
# missing_test_evidence are computed PROFILE-AWARE by the builder (per-stack), not here.
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" --argjson t "$TESTS" --argjson k "$SKIP" \
	'{status: $s, failures: $n, tests: $t, skipped: $k}')
OV=$(jq -n --argjson n "$N" --argjson t "$TESTS" --argjson k "$SKIP" \
	'{test_failures: $n, test_count: $t, skipped_tests: $k}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
