#!/bin/sh
# Sentinel Shield collector — dead code (normalized JSON).
#   .violations (or .dead_code_count) -> dead_code_violations
#   .dead_code_count                  -> informational dead_code_count
# Canonical raw shape:
#   { "tool":"dead-code", "status":"pass", "dead_code_count":0, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"

TOOL="dead-code"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (dead-code -> dead_code), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="dead-code"
INPUT="reports/raw/dead-code.json"

usage() {
	cat <<'EOF'
Usage: dead-code.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a normalized dead-code report.
Maps .violations (or .dead_code_count) -> dead_code_violations; .dead_code_count ->
informational dead_code_count.
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

# dead_code_count is the gating count whenever .violations is absent, so it must be held to
# the SAME fail-closed standard as .violations: `((.dead_code_count // 0) | if number...)`
# coerced a malformed value (e.g. "abc", -1, 1.5) to 0 — read as a clean pass. Distinguish
# ABSENT (legitimately 0, no count reported) from PRESENT-BUT-MALFORMED (untrusted -> reject).
# #204: neither count present means nothing was measured. "0" here made `{}` a clean gate
# via the violations fallback below.
DCC=$(jq -r '
	if ((has("dead_code_count") | not) and (has("violations") | not)) then "missing"
	elif (has("dead_code_count") | not) then "0"
	elif ((.dead_code_count | type) == "number" and .dead_code_count >= 0 and (.dead_code_count | floor) == .dead_code_count)
		then (.dead_code_count | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
if [ "$DCC" = "invalid" ]; then
	log_warn "$TOOL: .dead_code_count is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed dead_code_count"}' '{"dead_code_violations":0}'
	exit 0
fi
# .violations wins when present and VALID. Two behaviours changed here:
#   * a present-but-MALFORMED .violations used to fall back to .dead_code_count — so
#     {"violations":"abc","dead_code_count":7} reported 7 violations, a number the report
#     never asserted and that no sibling collector would produce. A malformed gating count
#     is untrusted evidence, not a licence to substitute a different field.
#   * a NEGATIVE .violations was clamped to 0, i.e. silently reported as clean.
# Both now fail closed. An ABSENT .violations still legitimately uses .dead_code_count.
V=$(jq -r --argjson dcc "$DCC" '
	if (has("violations") | not) then ($dcc | tostring)
	elif ((.violations | type) == "number" and .violations >= 0 and (.violations | floor) == .violations)
		then (.violations | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
if [ "$DCC" = "missing" ] || [ "$V" = "missing" ]; then
	log_warn "$TOOL: neither .violations nor .dead_code_count is present; a missing count is not a measured zero; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","health":"untrusted-evidence","reason":"no count present; a missing count is not a measured zero"}' '{"dead_code_violations":0}'
	exit 0
fi
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced, never substituted)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"dead_code_violations":0}'
	exit 0
fi
# #204: the raw producer status is CHECKED against the derived counts and the observed
# execution, not recomputed over the top of it. Previously `status` was read, accepted, and
# then discarded in favour of a count-derived verdict — so a producer could say one thing
# while the numbers said another and the contradiction was silently resolved in whichever
# direction this line happened to prefer. That is exploitable: a broken or hostile producer
# picks which field Sentinel privileges.
#
# Contradictory evidence is not clean evidence and not finding evidence. It is INVALID.
ne_quality_verify "$PRODUCER" "$INPUT" || {
	log_warn "$TOOL: $NE_EXEC_REASON; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "$NE_EXEC_REASON" '{status:"execution-error", health:"untrusted-evidence", reason:$r}')" \
		'{"dead_code_violations":0}'
	exit 0
}
# NOT "${NE_EXEC_JSON:-{}}": the `}` closing the inline JSON also closes the parameter
# expansion, so jq receives truncated text and the collector emits nothing at all. Named
# constant instead — this exact trap has now bitten three times in this library.
# #204 C1: the execution STATE is derived from the evidence, never asserted by this script.
# The line that used to sit here was
#     [ "$NE_COMPLETED" = "unobserved" ] && NE_COMPLETED=true
# which told the consistency matrix the producer had finished on the strength of nobody having
# watched it. The envelope was always truthful; the decision input was not.
NE_EXEC_STATE=$(ne_execution_state "${NE_EXEC_JSON:-$NE_EXEC_UNOBSERVED}")
VERDICT=$(ne_status_consistency "$RS" "$V" "$NE_EXEC_STATE")
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
		log_warn "$TOOL: inconsistent evidence ($VERDICT); raw status='"'"'$RS'"'"' violations=$V execution=$NE_EXEC_STATE; status=execution-error"
		ss_emit_collector "$TOOL" "execution-error" \
			"$(jq -n --arg h "$(ne_verdict_health "$VERDICT")" --arg r "$VERDICT" --arg raw "$RS" --argjson v "$V" '{status:"execution-error", health:$h, reason:$r, raw_status:$raw, violations:$v}')" \
			'{"dead_code_violations":0}'
		exit 0 ;;
esac

OV=$(jq -n --argjson v "$V" --argjson dcc "$DCC" '{dead_code_violations:$v, dead_code_count:$dcc}')
# #204: the evidence envelope is stamped here, carrying the quality payload — analyzed scope
# and the configuration digest — above the shared core. Both are LOAD-BEARING: ne_quality_verify
# recomputes the configuration digest from the file on disk, so a threshold change invalidates
# evidence produced under the old thresholds rather than merely annotating it.
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "sentinel-quality-json" "$NE_TRUST_NATIVE" \
	"$(printf '%s' "${NE_QUALITY_JSON:-$NE_QUALITY_EMPTY}" | jq --argjson v "$V" '{quality:{violations:$v}} + .')")

REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson dcc "$DCC" '{status:$s, findings:$v, dead_code_count:$dcc}')
REPORT=$(printf '%s' "$REPORT" | jq --argjson e "$ENVELOPE" '. + {evidence:$e}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
