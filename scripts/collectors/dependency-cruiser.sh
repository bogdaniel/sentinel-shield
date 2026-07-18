#!/bin/sh
# Sentinel Shield collector — dependency-cruiser (JS/TS structural-boundary producer).
#   violation count -> architecture_violations
#
# Accepts BOTH:
#   1. dependency-cruiser's native JSON:
#        { "summary": { "violations":[...], "error":N, "warn":N,
#                       "ruleSetUsed": { "forbidden":[...], "allowed":[...] } } }
#   2. The normalized architecture raw contract (docs/architecture-governance.md).
#
# Fail closed: status-bearing reports keep their status; an unknown status or an
# unrecognized shape becomes execution-error — never a clean architecture_violations: 0.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"

TOOL="dependency-cruiser"
INPUT="reports/raw/dependency-cruiser.json"

usage() {
	cat <<'EOF'
Usage: dependency-cruiser.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a dependency-cruiser report
(native or normalized architecture contract). Maps violations -> architecture_violations.
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
	if (type != "object") then "unknown"
	elif ((.summary.violations? | type) == "array") then "native"
	elif ((.violations? | type) == "number") then "normalized"
	elif ((.violations? | type) == "array") then "normalized"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')

if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized dependency-cruiser JSON shape in '$INPUT'; status=execution-error (never reported as clean)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","violations":0,"reason":"unrecognized dependency-cruiser report shape"}' '{}'
	exit 0
fi

if [ "$SHAPE" = "native" ]; then
	# Count NOT coerced (see arch_count): a malformed count fails closed, never a clean 0.
	N=$(arch_count "$INPUT" '.summary.violations | length')
	# Rules evaluated = the forbidden/allowed rule set dependency-cruiser actually used.
	RULES=$(arch_num "$INPUT" '((.summary.ruleSetUsed.forbidden? // []) | length) + ((.summary.ruleSetUsed.allowed? // []) | length)')
else
	N=$(arch_count "$INPUT" 'if ((.violations|type)=="array") then (.violations|length) else .violations end')
	RULES=$(arch_num "$INPUT" '.rule_count // 0')
fi
CTX=$(arch_num "$INPUT" '.context_count // 0')

arch_emit "$TOOL" "$N" "$RULES" "$CTX"
