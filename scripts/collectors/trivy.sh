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

TOOL="trivy"
INPUT="reports/raw/trivy.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: trivy.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Trivy JSON report.
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
# Fail closed on a report whose SHAPE this collector does not recognize (v2.0.2).
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
