#!/bin/sh
# Sentinel Shield collector — normalized architecture evidence (v2.1.0).
#
# The ONE implementation of the normalized architecture raw contract
# (docs/architecture-governance.md); the per-producer collectors
# (architecture-tests.sh / php-arkitect.sh / js-architecture-tests.sh) delegate here with a
# different --tool-name, exactly as php-/js-coverage share collectors/coverage.sh.
#
#   { "tool":"architecture", "status":"pass|findings|unavailable|not-configured|
#      execution-error|disabled|not-applicable",
#     "violations":0, "rule_count":12, "context_count":4, "failures":[] }
#
#   violations   -> architecture_violations
#   rule_count   -> architecture_rule_count      (informational)
#   context_count-> architecture_context_count   (informational)
#   evidence     -> architecture_tool_count = 1  (only for pass/findings)
#
# Fail closed: unknown status -> execution-error; unreadable shape -> execution-error;
# missing/empty report -> unavailable; invalid JSON -> exit 2.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"

TOOL="architecture"
INPUT="reports/raw/architecture.json"

usage() {
	cat <<'EOF'
Usage: architecture.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized architecture report.
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

# Recognized evidence shape: an object carrying a numeric violations count, an array of
# failures, or the legacy `{violations:[...]}`. Anything else fails closed.
SHAPE=$(jq -r '
	if (type != "object") then "unknown"
	elif ((.violations? | type) == "number") then "ok"
	elif ((.violations? | type) == "array") then "ok"
	elif ((.failures? | type) == "array") then "ok"
	else "unknown" end' "$INPUT" 2>/dev/null || printf 'unknown')

if [ "$SHAPE" = "unknown" ]; then
	log_warn "$TOOL: unrecognized architecture report shape in '$INPUT'; status=execution-error (never reported as clean)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","violations":0,"reason":"unrecognized architecture report shape"}' '{}'
	exit 0
fi

# The count is NOT coerced: a recognized shape carrying a malformed/negative count fails closed
# as execution-error inside arch_emit rather than being reported as a clean 0.
N=$(arch_count "$INPUT" '
	if ((.violations? | type) == "number") then .violations
	elif ((.violations? | type) == "array") then (.violations | length)
	elif ((.failures? | type) == "array") then (.failures | length)
	else -1 end')
RULES=$(arch_num "$INPUT" '.rule_count // 0')
CTX=$(arch_num "$INPUT" '.context_count // 0')

arch_emit "$TOOL" "$N" "$RULES" "$CTX"
