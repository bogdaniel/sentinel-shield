#!/bin/sh
# Sentinel Shield collector — Deptrac (PHP structural-boundary producer).
#   violation count -> architecture_violations
#
# Accepts BOTH:
#   1. Deptrac's native JSON (shape has varied across versions):
#        .report.violations (number) | .Report.Violations (number)
#        | .violations (array -> length, or number)
#   2. The normalized architecture raw contract (docs/architecture-governance.md):
#        { "tool":"architecture", "status":"findings", "violations":2,
#          "rule_count":12, "context_count":4, "failures":[...] }
#
# Fail-closed rules (v2.1.0): a status-bearing report keeps its status (unavailable /
# not-configured / execution-error / disabled / not-applicable are NEVER collapsed into a
# clean pass); an unknown status and an UNRECOGNIZED JSON shape both become execution-error
# — a shape this collector cannot read must never be reported as architecture_violations: 0.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"

TOOL="deptrac"
INPUT="reports/raw/deptrac.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: deptrac.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Deptrac JSON report (native or
normalized architecture contract). Maps violations -> architecture_violations.
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

# Honest non-evidence statuses pass straight through; unknown status fails closed.
arch_passthrough_status "$TOOL" "$INPUT"

# Shape recognition: an unreadable shape must NOT become a clean 0 (fail closed).
SHAPE=$(jq -r '
	if (type != "object") then "unknown"
	elif ((.report.violations? | type) == "number") then "report"
	elif ((.Report.Violations? | type) == "number") then "Report"
	elif ((.violations? | type) == "number") then "violations-number"
	elif ((.violations? | type) == "array") then "violations-array"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')

if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized Deptrac/architecture JSON shape in '$INPUT'; status=execution-error (never reported as clean)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","violations":0,"reason":"unrecognized deptrac report shape"}' '{}'
	exit 0
fi

N=$(jq '
	if ((.report.violations? | type) == "number") then .report.violations
	elif ((.Report.Violations? | type) == "number") then .Report.Violations
	elif ((.violations? | type) == "number") then .violations
	elif ((.violations? | type) == "array") then (.violations | length)
	else 0 end | if . >= 0 then floor else 0 end' "$INPUT")

# Rule/context metadata where the producer exposes it (normalized contract, or Deptrac's
# layer list when present). Absent metadata stays 0 — informational only, never a gate.
RULES=$(arch_num "$INPUT" '.rule_count // .report.rule_count? // 0')
CTX=$(arch_num "$INPUT" '.context_count // (if (.layers? | type) == "array" then (.layers | length) else 0 end)')

arch_emit "$TOOL" "$N" "$RULES" "$CTX"
