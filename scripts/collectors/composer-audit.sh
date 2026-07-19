#!/bin/sh
# Sentinel Shield collector — composer audit (--format=json).
#   critical -> critical_vulnerabilities
#   high     -> high_vulnerabilities
#   medium/moderate -> medium_vulnerabilities
# Expects { "advisories": { "<pkg>": [ { "severity": "high", ... } ] } }.
# NOTE: composer audit JSON has varied across versions; parsing is defensive and
# may need tuning. Severity strings are lowercased before matching.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="composer_audit"
INPUT="reports/raw/composer-audit.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: composer-audit.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for `composer audit --format=json`.
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
ss_shape_or_fail "$TOOL" "$INPUT" '(type == "object") and (((.advisories? | type) == "object") or ((.advisories? | type) == "array"))' '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'

# An advisory with NO severity is still a vulnerability.
#
# `composer audit --format=json` advisory objects (advisoryId, packageName, title, cve,
# link, sources) frequently carry no `severity` field at all. Those matched none of the
# three buckets, so a PHP project with known CVEs in composer.lock reported
# {critical:0, high:0, medium:0} and PASSED strict. There was no unknown-severity bucket
# and no reconciliation against the advisory total.
#
# Unknown/absent severity is counted as MEDIUM — visible and gated in strict — rather than
# silently dropped: an unclassifiable advisory is a blind spot. But an EXPLICIT `low` is not
# unknown, and the canonical rule (docs/severity-normalization.md) is LOW/INFO → not gated.
# So `low` is excluded from the medium bucket (matching osv-scanner, which buckets `low`
# separately and never sums it), while it STAYS in the IN() list below so it is treated as a
# recognized-and-dropped severity, NOT swept back into medium by the unknown catch-all.
OV=$(jq '
	[ (.advisories // {}) | to_entries[] | .value[]? | (.severity // "") | ascii_downcase ] as $s
	| {
		critical_vulnerabilities: ([ $s[] | select(. == "critical") ] | length),
		high_vulnerabilities:     ([ $s[] | select(. == "high") ] | length),
		medium_vulnerabilities:   ([ $s[]
			| select(. == "medium" or . == "moderate"
				or (IN("critical","high","medium","moderate","low") | not)) ] | length)
	}' "$INPUT")

# Fail closed on negative/float/non-numeric counts (v2.0.2); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{status: $s, critical: .critical_vulnerabilities, high: .high_vulnerabilities, medium: .medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
