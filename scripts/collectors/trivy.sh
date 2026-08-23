#!/bin/sh
# Sentinel Shield collector — Trivy. Maps vulnerability severities to vuln buckets.
#   CRITICAL -> critical_vulnerabilities
#   HIGH     -> high_vulnerabilities
#   MEDIUM   -> medium_vulnerabilities
# Supports .Results[].Vulnerabilities[].Severity (image/fs JSON).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/collector-evidence.sh
. "$SCRIPT_DIR/../lib/collector-evidence.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SCRIPT_DIR/../lib/scanner-contracts.sh"

TOOL="trivy"
INPUT="reports/raw/trivy-fs.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: trivy.sh [--input <path>] [--tool-name <name>] [--producer-key <key>]
Emit a Sentinel Shield collector object (stdout) for a Trivy JSON report.
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

# EVIDENCE BINDING FIRST (#136). Before any severity is read: provenance exists, its digest is the
# digest of THIS report, the producer is the filesystem scanner, and the completion state carries a
# scan result at all.
if ! ce_bind "$INPUT" "trivy-fs" "${SENTINEL_SHIELD_TRIVY_SUBJECT:-}"; then
	log_error "$TOOL: evidence rejected — ${CE_REASON:-unbound}"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "${CE_REASON:-unbound}" '{status:"execution-error", reason:$r}')" '{}'
	exit 0
fi

# SCAN TYPE IS PART OF IDENTITY (#136, #99). An image scan and a filesystem scan answer different
# questions, and until the path unification they could overwrite each other. A filesystem contract
# refuses image evidence however well-formed it is.
_tv_mode=$(ce_target_mode "$INPUT") || _tv_mode=""
if [ "$_tv_mode" != "filesystem" ]; then
	log_error "$TOOL: evidence describes target mode '$_tv_mode', not a filesystem scan"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg m "$_tv_mode" '{status:"execution-error", reason:("wrong scan type: " + $m)}')" '{}'
	exit 0
fi

if ! sc_trivy_validate "$INPUT"; then
	log_error "$TOOL: not a valid Trivy report — ${SC_REASON:-unknown}"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "${SC_REASON:-unknown}" '{status:"invalid-output", reason:$r}')" '{}'
	exit 0
fi

# UNKNOWN VOCABULARY FAILS CLOSED (#136). A severity or misconfiguration status outside the
# documented set is not silently dropped into "no findings" -- an unrecognised value is precisely
# the case where a silent omission becomes a false clean.
_tv_known='CRITICAL HIGH MEDIUM LOW UNKNOWN'
_tv_bad=$(jq -r --arg k "$_tv_known" '
	[ (.Results // .results // [])[]?
	  | ((.Vulnerabilities // [])[]?.Severity // empty),
	    ((.Secrets // [])[]?.Severity // empty) ]
	| map(select((. | type != "string") or ((. | ascii_upcase) as $s | ($k | split(" ") | index($s)) == null)))
	| unique | join(",")' "$INPUT" 2>/dev/null) || _tv_bad=""
if [ -n "$_tv_bad" ]; then
	log_error "$TOOL: unknown severity vocabulary '$_tv_bad' — failing closed rather than omitting it"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg v "$_tv_bad" '{status:"execution-error", reason:("unknown severity: " + $v)}')" '{}'
	exit 0
fi
_tv_badstatus=$(jq -r '
	[ (.Results // .results // [])[]? | (.Misconfigurations // [])[]?.Status // empty ]
	| map(select((. | type != "string") or ((. | ascii_downcase) as $s | (["pass","fail","exception"] | index($s)) == null)))
	| unique | join(",")' "$INPUT" 2>/dev/null) || _tv_badstatus=""
if [ -n "$_tv_badstatus" ]; then
	log_error "$TOOL: unknown misconfiguration status '$_tv_badstatus' — failing closed"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg v "$_tv_badstatus" '{status:"execution-error", reason:("unknown status: " + $v)}')" '{}'
	exit 0
fi
# Fail closed on a report whose SHAPE this collector does not recognize (v2.0.2).
# This collector has NO pre-normalized fallback in its extraction, so the recognizer
# deliberately matches the NATIVE shape ONLY. Widening it to accept {critical:N}
# would ACCEPT a document the extraction cannot read and report a clean 0 — a
# fail-open strictly worse than rejecting the input.
ss_shape_or_fail "$TOOL" "$INPUT" '(type == "object") and ((.Results? | type) == "array")' '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'

# Trivy's single JSON carries THREE finding families and only one was being read.
# `.Results[].Misconfigurations[]` (Dockerfile/IaC) and `.Results[].Secrets[]` were both
# dropped, so a project using `trivy config` as its IaC producer or Trivy's secret scanner
# got iac_violations:0 / secrets:0 from a report that contained findings.
# Each family maps to its OWN channel — misconfigurations are not vulnerabilities.
OV=$(jq '
	[ .Results[]?.Vulnerabilities[]?.Severity // empty | ascii_upcase ] as $s
	| ([ .Results[]?.Misconfigurations[]? | select((.Status // "FAIL") == "FAIL") ] | length) as $mis
	| ([ .Results[]?.Secrets[]? ] | length) as $sec
	| {
		critical_vulnerabilities: ([ $s[] | select(. == "CRITICAL") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "HIGH") ] | length),
		medium_vulnerabilities:   ([ $s[] | select(. == "MEDIUM") ] | length),
		iac_violations:           $mis,
		secrets:                  $sec
	}' "$INPUT")

# Fail closed on negative/float/non-numeric counts (v2.0.2); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities, iac_violations: .iac_violations, secrets: .secrets}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
