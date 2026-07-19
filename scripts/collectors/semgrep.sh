#!/bin/sh
# Sentinel Shield collector — Semgrep. Maps result severities to vuln buckets.
#   ERROR/CRITICAL -> critical_vulnerabilities
#   WARNING/HIGH   -> high_vulnerabilities
#   INFO/MEDIUM    -> medium_vulnerabilities
# NOTE: severity->bucket mapping is conservative and may need project tuning.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="semgrep"
INPUT="reports/raw/semgrep.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: semgrep.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Semgrep JSON report (.results[]).
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
# Fail closed on a report whose SHAPE this collector does not recognize (v2.0.1).
ss_shape_or_fail "$TOOL" "$INPUT" '(type == "object") and ((.results? | type) == "array")' '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'

OV=$(jq '
	[ .results[]?.extra.severity // empty | ascii_upcase ] as $s
	| {
		# docs/severity-policy.md: Informational findings have "no direct security impact
		# ... never blocks". INFO was mapped to medium_vulnerabilities, which BLOCKS in
		# strict/regulated — the collector contradicted the policy it is judged by.
		# INFO is now reported separately (informational, never gated).
		#
		# The Semgrep ERROR level is its default for many non-vulnerability correctness
		# rules, so promoting it straight to CRITICAL — never suppressible, blocking from
		# baseline — massively over-blocked. ERROR now maps to high; only an explicit
		# CRITICAL severity is critical.
		critical_vulnerabilities: ([ $s[] | select(. == "CRITICAL") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "ERROR" or . == "HIGH") ] | length),
		medium_vulnerabilities:   ([ $s[] | select(. == "WARNING" or . == "MEDIUM") ] | length),
		_informational:           ([ $s[] | select(. == "INFO" or . == "LOW") ] | length)
	}' "$INPUT")

# Fail closed on negative/float/non-numeric counts (v2.0.1, #51); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
# Status is derived from the GATING buckets only (#52). Informational findings are reported but
# must never drive the status, or "1 INFO finding" would still fail the gate — exactly the
# behavior docs/severity-policy.md says never happens.
TOTAL=$(printf '%s' "$OV" | jq '[.critical_vulnerabilities, .high_vulnerabilities, .medium_vulnerabilities] | add // 0')
INFO=$(printf '%s' "$OV" | jq '._informational // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; elif [ "$INFO" -gt 0 ]; then STATUS="warn"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities, informational: ._informational}')
# `_informational` is internal metadata: it is surfaced in the tool_report but must NOT
# enter summary.* — schemas/security-summary.schema.json sets additionalProperties:false
# on summary, so an undeclared key would make the whole document invalid.
OVCOUNTS=$(printf '%s' "$OV" | jq '{critical_vulnerabilities, high_vulnerabilities, medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OVCOUNTS"
