#!/bin/sh
# Sentinel Shield collector — dependency-check. Maps vulnerability severities to vuln buckets
# (critical/high/medium_vulnerabilities). Accepts native format or a normalized
# {critical,high,medium} object. Severity parsing is best-effort; see docs.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"
TOOL="dependency-check"
FIXTURE=0
INPUT="reports/raw/dependency-check.json"
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  --fixture-evidence) FIXTURE=1; shift ;;
  -h|--help) echo "Usage: dependency-check.sh [--input <path>] [--tool-name <name>] [--fixture-evidence]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_collector_guard "$TOOL" "$INPUT"
# Fail closed on a report whose SHAPE this collector does not recognize (v2.0.2).
# #182: the bare `{critical,high,medium}` alternative is GONE — it let any writer of this
# path assert clean counts with a positive health signal. NOT in a command substitution:
# ne_gate_input must run in THIS shell so its refusal can stop the collector.
ne_gate_input "$TOOL" "$INPUT" '(type == "object") and ((.dependencies? | type) == "array")' \
	'{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}' "$FIXTURE" || exit 0
# Severity vocab is normalized: Dependency-Check mixes NVD/CVSS labels (CRITICAL/HIGH/MEDIUM/LOW)
# with the npm Node-Audit / RetireJS labels (critical/high/moderate/low). npm "MODERATE" IS the
# medium bucket — map it so real moderate CVEs are counted (and gated in strict), not dropped.
# (v0.1.27: surfaced by a real dependency-rich consumer run — 3 moderate npm CVEs were being lost.)
if [ "$NE_KIND" = fixture ]; then
	OV=$(jq '{critical_vulnerabilities:(.counts.critical//0), high_vulnerabilities:(.counts.high//0), medium_vulnerabilities:(.counts.medium//0)}' "$INPUT")
else
	OV=$(jq '([.dependencies[]?.vulnerabilities[]?.severity // empty | ascii_upcase | if . == "MODERATE" then "MEDIUM" else . end]) as $s | {critical_vulnerabilities:([$s[]|select(.=="CRITICAL")]|length), high_vulnerabilities:([$s[]|select(.=="HIGH")]|length), medium_vulnerabilities:([$s[]|select(.=="MEDIUM")]|length)}' "$INPUT")
fi
# Fail closed on negative/float/non-numeric counts (v2.0.2); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
# The envelope is STAMPED HERE, after this collector parsed the native report itself.
if [ "$NE_KIND" = fixture ]; then NE_TRUST_TYPE="$NE_TRUST_FIXTURE"; else NE_TRUST_TYPE="$NE_TRUST_NATIVE"; fi
ENVELOPE=$(ne_envelope "$TOOL" "$INPUT" "dependency-check-json" "$NE_TRUST_TYPE" \
	"$(printf '%s' "$OV" | jq '{counts:{critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities}}')")
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" --argjson e "$ENVELOPE" \
	--argjson np "$([ "$NE_KIND" = fixture ] && echo true || echo false)" \
	'{status:$s, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities, evidence:$e}
	 + (if $np then {non_production:true} else {} end)')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
