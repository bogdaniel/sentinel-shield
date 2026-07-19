#!/bin/sh
# Sentinel Shield collector — grype. Maps vulnerability severities to vuln buckets
# (critical/high/medium_vulnerabilities). Accepts native format or a normalized
# {critical,high,medium} object. Severity parsing is best-effort; see docs.
#
# HEALTH + PROVENANCE (v2 hardening): the tool_report now carries an explicit `health`
# state and a `provenance` object so callers can tell apart:
#   ok            scanner ran, found nothing
#   findings      scanner ran, findings present
#   scanner-error scanner produced no report (did not run / crashed)  -> status unavailable
#   parser-error  report present but not valid JSON                    -> status execution-error
# provenance (scanner_version + vulnerability_db.timestamp) is read from the sidecar
# reports/raw/grype.provenance.json when present, else from Grype's own native
# `.descriptor` (version + db.built). A populated version distinguishes an EMPTY report
# from a scanner that DID NOT RUN.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
TOOL="grype"
INPUT="reports/raw/grype.json"
PROVENANCE=""
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
  --provenance) PROVENANCE="${2:?--provenance requires a value}"; shift 2 ;;
  -h|--help) echo "Usage: grype.sh [--input <path>] [--tool-name <name>] [--provenance <path>]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_require_jq
[ -n "$PROVENANCE" ] || PROVENANCE="${INPUT%.json}.provenance.json"

# Health-aware preflight (supersedes ss_collector_guard so scanner-error / parser-error
# are surfaced). Provenance for the no-report case has no native fallback available.
if [ ! -f "$INPUT" ] || [ ! -s "$INPUT" ]; then
	log_warn "$TOOL: input '$INPUT' missing or empty; scanner did not run (health=scanner-error)"
	PROV=$(ss_provenance_object "$PROVENANCE" "" "")
	REPORT=$(jq -n --argjson p "$PROV" '{status:"unavailable", health:"scanner-error", critical:0, high:0, medium:0, provenance:$p}')
	ss_emit_collector "$TOOL" "unavailable" "$REPORT" '{}'
	exit 0
fi
if ! jq -e . "$INPUT" >/dev/null 2>&1; then
	log_error "$TOOL: invalid JSON in '$INPUT' (health=parser-error)"
	PROV=$(ss_provenance_object "$PROVENANCE" "" "")
	REPORT=$(jq -n --argjson p "$PROV" '{status:"execution-error", health:"parser-error", critical:0, high:0, medium:0, provenance:$p}')
	ss_emit_collector "$TOOL" "execution-error" "$REPORT" '{}'
	# fail-closed: unparseable scanner output is an error, not a clean result
	exit 2
fi

# Native provenance fallback: Grype embeds its own version and DB build time.
NV=$(jq -r '.descriptor.version // ""' "$INPUT" 2>/dev/null) || NV=""
NDB=$(jq -r '.descriptor.db.built // ""' "$INPUT" 2>/dev/null) || NDB=""
PROV=$(ss_provenance_object "$PROVENANCE" "$NV" "$NDB")

OV=$(jq 'if has("matches") then
			([.matches[]?.vulnerability.severity // empty | ascii_upcase]) as $s
			| {critical_vulnerabilities:([$s[]|select(.=="CRITICAL")]|length),
			   high_vulnerabilities:([$s[]|select(.=="HIGH")]|length),
			   medium_vulnerabilities:([$s[]|select(.=="MEDIUM")]|length), _native:true}
		 else
			{critical_vulnerabilities:(.critical//0), high_vulnerabilities:(.high//0), medium_vulnerabilities:(.medium//0), _native:false}
		 end' "$INPUT")
# Fail closed on negative/float/non-numeric counts (v2.0.2); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
TOTAL=$(printf '%s' "$OV" | jq '[.critical_vulnerabilities,.high_vulnerabilities,.medium_vulnerabilities]|add // 0')

if [ "$TOTAL" -gt 0 ]; then
	STATUS="fail"; HEALTH="findings"
else
	# Grype always scans a declared target; an empty matches set means it ran clean.
	# (Package-count is not present in Grype's JSON, so no-targets is not inferable
	# here — reported honestly as 'ok'.)
	STATUS="pass"; HEALTH="ok"
fi

REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" --arg h "$HEALTH" --argjson p "$PROV" \
	'{status:$s, health:$h, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities, provenance:$p}')
OVCOUNTS=$(printf '%s' "$OV" | jq '{critical_vulnerabilities,high_vulnerabilities,medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OVCOUNTS"
