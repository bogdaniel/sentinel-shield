#!/bin/sh
# Sentinel Shield collector — duplication (normalized JSON).
#   .violations          -> duplication_violations
#   .duplication_percent -> informational duplication_percent
# Canonical raw shape:
#   { "tool":"duplication", "status":"pass", "duplication_percent":3.1,
#     "threshold":5, "violations":0 }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"

TOOL="duplication"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (duplication -> duplication), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="duplication"
INPUT="reports/raw/duplication.json"

usage() {
	cat <<'EOF'
Usage: duplication.sh [--input <path>] [--tool-name <name>] [--producer-key <key>]
Emit a Sentinel Shield collector object (stdout) for a normalized duplication report.
Maps .violations -> duplication_violations; .duplication_percent -> informational.
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
# .violations still legitimately means 0; a present-but-malformed one does not.
V=$(jq -r '
	if (has("violations") | not) then "missing"
	elif ((.violations | type) == "number" and .violations >= 0 and (.violations | floor) == .violations)
		then (.violations | floor | tostring)
	else "invalid" end' "$INPUT" 2>/dev/null || printf 'invalid')
# #204: an ABSENT count is not a measured zero. The previous read returned "0" for a
# report with no `violations` field at all, so `{}` became a clean gate.
if [ "$V" = "missing" ]; then
	log_warn "$TOOL: no .violations field; a missing count is not a measured zero; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","health":"untrusted-evidence","reason":"violations absent; a missing count is not a measured zero"}' '{"duplication_violations":0}'
	exit 0
fi
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"duplication_violations":0}'
	exit 0
fi
DP=$(jq 'if ((.duplication_percent|type)=="number" and .duplication_percent >= 0) then .duplication_percent else 0 end' "$INPUT")
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
		'{"duplication_violations":0}'
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
			'{"duplication_violations":0}'
		exit 0 ;;
esac

OV=$(jq -n --argjson v "$V" --argjson dp "$DP" '{duplication_violations:$v, duplication_percent:$dp}')
# #204: the evidence envelope is stamped here, carrying the quality payload — analyzed scope
# and the configuration digest — above the shared core. Both are LOAD-BEARING: ne_quality_verify
# recomputes the configuration digest from the file on disk, so a threshold change invalidates
# evidence produced under the old thresholds rather than merely annotating it.
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "sentinel-quality-json" "$NE_TRUST_NATIVE" \
	"$(printf '%s' "${NE_QUALITY_JSON:-$NE_QUALITY_EMPTY}" | jq --argjson v "$V" '{quality:{violations:$v}} + .')")

REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson dp "$DP" '{status:$s, findings:$v, duplication_percent:$dp}')
REPORT=$(printf '%s' "$REPORT" | jq --argjson e "$ENVELOPE" '. + {evidence:$e}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
