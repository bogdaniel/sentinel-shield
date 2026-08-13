#!/bin/sh
# Sentinel Shield collector — changed-lines (diff) coverage (normalized JSON).
#   .violations                     -> changed_lines_coverage_violations
#   .changed_lines_coverage_percent -> informational changed_lines_coverage_percent
# Canonical raw shape (see docs/engineering-quality-gates.md):
#   { "tool":"diff-coverage", "status":"pass", "changed_lines_coverage_percent":85.5,
#     "threshold":80, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"

TOOL="diff-coverage"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (diff-coverage -> diff_coverage), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="diff-coverage"
INPUT="reports/raw/diff-coverage.json"

usage() {
	cat <<'EOF'
Usage: diff-coverage.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized diff-coverage report.
Maps .violations -> changed_lines_coverage_violations; .changed_lines_coverage_percent ->
informational.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		--producer-key) PRODUCER="${2:?--producer-key requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_collector_guard "$TOOL" "$INPUT"

RS=$(jq -r '.status // ""' "$INPUT")
case "$RS" in
	'' | pass | findings | warn) : ;;  # normal: derive status from the numeric fields below
	unavailable | not-configured | execution-error | disabled | not-applicable)
		ss_emit_collector "$TOOL" "$RS" "$(jq -n --arg s "$RS" '{status:$s, findings:0}')" '{}'
		exit 0 ;;
	*)  # unknown/unexpected status -> fail closed (never derive a clean pass)
		ss_emit_collector "$TOOL" "execution-error" '{"status":"execution-error","findings":0}' '{}'
		exit 0 ;;
esac

# The GATING count is never coerced. This read
#   ((.violations // 0) | if (type=="number" and . >= 0) then floor else 0 end)
# which turned a negative, fractional or non-numeric .violations into a clean 0 — a
# corrupted or truncated report reported PASS. docs/raw-report-contract.md states the
# opposite rule verbatim, and lib/architecture-evidence.sh already implements it. An ABSENT
# .violations is NOT a measured zero (#204); a present-but-malformed one is not either.
V=$(jq -r '
	if (has("violations") | not) then "missing"
	elif ((.violations | type) == "number" and .violations >= 0 and (.violations | floor) == .violations)
		then (.violations | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
# #204: an ABSENT count is not a measured zero. This read returned "0" for a report with
# no `violations` field at all, so `{}` became a clean coverage gate.
if [ "$V" = "missing" ]; then
	log_warn "$TOOL: no .violations field; a missing count is not a measured zero; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","health":"untrusted-evidence","reason":"violations absent; a missing count is not a measured zero"}' '{"changed_lines_coverage_violations":0}'
	exit 0
fi
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"changed_lines_coverage_violations":0}'
	exit 0
fi
PCT=$(jq 'if ((.changed_lines_coverage_percent|type)=="number" and .changed_lines_coverage_percent >= 0) then .changed_lines_coverage_percent else 0 end' "$INPUT")
# #204: the raw producer status is CHECKED against the derived counts and the observed
# execution, not recomputed over the top of it. A producer could previously report one thing
# while the numbers said another, and the contradiction was resolved in whichever direction
# this line preferred — letting a broken or hostile producer pick which field Sentinel trusts.
ne_quality_verify "$PRODUCER" "$INPUT" || {
	log_warn "$TOOL: $NE_EXEC_REASON; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "$NE_EXEC_REASON" '{status:"execution-error", health:"untrusted-evidence", reason:$r}')" \
		'{"changed_lines_coverage_violations":0}'
	exit 0
}
# #204 C1: the execution STATE is derived from the evidence, never asserted by this script.
# The line that used to sit here was
#     [ "$NE_COMPLETED" = "unobserved" ] && NE_COMPLETED=true
# which told the consistency matrix the producer had finished on the strength of nobody having
# watched it. The envelope was always truthful; the decision input was not.
NE_EXEC_STATE=$(ne_execution_state "${NE_EXEC_JSON:-$NE_EXEC_UNOBSERVED}")
NE_TOTAL="$V"
VERDICT=$(ne_status_consistency "$RS" "$NE_TOTAL" "$NE_EXEC_STATE")
case "$VERDICT" in
	valid-clean)    STATUS="pass" ;;
	valid-findings) STATUS="findings" ;;
	# Findings from a producer nobody watched are REAL — something was found. What the run
	# cannot support is the claim that this is all there was, so the public status is the
	# ordinary `findings` and the weakness is carried by the envelope's own execution record,
	# which still says observed:false. Widening the public status vocabulary is a schema
	# decision, deliberately not taken here.
	valid-findings-unobserved) STATUS="findings" ;;
	*)
		log_warn "$TOOL: inconsistent evidence ($VERDICT); raw status='"'"'$RS'"'"' countable=$NE_TOTAL execution=$NE_EXEC_STATE; status=execution-error"
		ss_emit_collector "$TOOL" "execution-error" \
			"$(jq -n --arg h "$(ne_verdict_health "$VERDICT")" --arg r "$VERDICT" --arg raw "$RS" --argjson v "$NE_TOTAL" '{status:"execution-error", health:$h, reason:$r, raw_status:$raw, violations:$v}')" \
			'{"changed_lines_coverage_violations":0}'
		exit 0 ;;
esac

OV=$(jq -n --argjson v "$V" --argjson p "$PCT" \
	'{changed_lines_coverage_violations:$v, changed_lines_coverage_percent:$p}')
# #204: the evidence envelope is stamped here, carrying the quality payload — analyzed scope
# and the configuration digest — above the shared core, exactly as the other four producers do.
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "sentinel-quality-json" "$NE_TRUST_NATIVE" \
	"$(printf '%s' "${NE_QUALITY_JSON:-$NE_QUALITY_EMPTY}" | jq --argjson v "$NE_TOTAL" '{quality:{violations:$v}} + .')")

REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson p "$PCT" \
	'{status:$s, findings:$v, changed_lines_coverage_percent:$p}')
REPORT=$(printf '%s' "$REPORT" | jq --argjson e "$ENVELOPE" '. + {evidence:$e}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
