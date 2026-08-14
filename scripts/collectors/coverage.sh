#!/bin/sh
# Sentinel Shield collector — code coverage (normalized JSON).
#   .violations > 0     -> coverage_threshold_violations
#   .regression == true -> coverage_regression = 1
#   .line/branch/method/class_percent -> informational coverage_*_percent
# Canonical raw shape (see docs/raw-report-contract.md / engineering-quality-gates.md):
#   { "tool":"coverage", "status":"pass", "line_percent":82.4, "branch_percent":61.2,
#     "method_percent":0, "class_percent":0, "violations":0, "regression":false }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"

TOOL="coverage"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (coverage -> coverage), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="coverage"
INPUT="reports/raw/coverage.json"

usage() {
	cat <<'EOF'
Usage: coverage.sh [--input <path>] [--tool-name <name>] [--producer-key <key>]
Emit a Sentinel Shield collector object (stdout) for a normalized coverage report.
Maps threshold violations -> coverage_threshold_violations, regression ->
coverage_regression, and percentages -> informational coverage_*_percent keys.
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

# Honest non-clean statuses pass straight through (never invented as a clean 0).
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

# num <key> — the numeric value of .<key>, or 0 for absent/non-numeric.
num() { jq --arg k "$1" 'if ((.[$k]|type)=="number" and .[$k] >= 0) then .[$k] else 0 end' "$INPUT"; }

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
		'{"status":"execution-error","health":"untrusted-evidence","reason":"violations absent; a missing count is not a measured zero"}' '{"coverage_threshold_violations":0}'
	exit 0
fi
if [ "$V" = "invalid" ]; then
	log_warn "$TOOL: .violations is malformed; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","reason":"malformed violations count"}' '{"coverage_threshold_violations":0}'
	exit 0
fi
REG=$(jq 'if (.regression == true) then 1 else 0 end' "$INPUT")
LP=$(num line_percent); BP=$(num branch_percent); MP=$(num method_percent); CP=$(num class_percent)

# #204: the raw producer status is CHECKED against the derived counts and the observed
# execution, not recomputed over the top of it. A producer could previously report one thing
# while the numbers said another, and the contradiction was resolved in whichever direction
# this line preferred — letting a broken or hostile producer pick which field Sentinel trusts.
ne_quality_verify "$PRODUCER" "$INPUT" || {
	log_warn "$TOOL: $NE_EXEC_REASON; status=execution-error"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "$NE_EXEC_REASON" '{status:"execution-error", health:"untrusted-evidence", reason:$r}')" \
		'{"coverage_threshold_violations":0}'
	exit 0
}
# #204 C1: the execution STATE is derived from the evidence, never asserted by this script.
# The line that used to sit here was
#     [ "$NE_COMPLETED" = "unobserved" ] && NE_COMPLETED=true
# which told the consistency matrix the producer had finished on the strength of nobody having
# watched it. The envelope was always truthful; the decision input was not.
NE_EXEC_STATE=$(ne_execution_state "${NE_EXEC_JSON:-$NE_EXEC_UNOBSERVED}")
NE_TOTAL=$((V + REG))
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
			'{"coverage_threshold_violations":0}'
		exit 0 ;;
esac

OV=$(jq -n --argjson v "$V" --argjson r "$REG" --argjson lp "$LP" --argjson bp "$BP" \
	--argjson mp "$MP" --argjson cp "$CP" '{
		coverage_threshold_violations: $v,
		coverage_regression: $r,
		coverage_line_percent: $lp,
		coverage_branch_percent: $bp,
		coverage_method_percent: $mp,
		coverage_class_percent: $cp
	}')
# #204: the evidence envelope is stamped here, carrying the quality payload — analyzed scope
# and the configuration digest — above the shared core, exactly as the other four producers do.
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "sentinel-quality-json" "$NE_TRUST_NATIVE" \
	"$(printf '%s' "${NE_QUALITY_JSON:-$NE_QUALITY_EMPTY}" | jq --argjson v "$NE_TOTAL" '{quality:{violations:$v}} + .')")

REPORT=$(jq -n --arg s "$STATUS" --argjson v "$V" --argjson r "$REG" --argjson lp "$LP" --argjson bp "$BP" \
	'{status:$s, findings:$v, regression:($r==1), line_percent:$lp, branch_percent:$bp}')
REPORT=$(printf '%s' "$REPORT" | jq --argjson e "$ENVELOPE" '. + {evidence:$e}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
