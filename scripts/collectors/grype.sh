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
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"
TOOL="grype"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (grype -> grype), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="grype"
INPUT="reports/raw/grype.json"
PROVENANCE=""
FIXTURE=0
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		--producer-key) PRODUCER="${2:?--producer-key requires a value}"; shift 2 ;;
  --provenance) PROVENANCE="${2:?--provenance requires a value}"; shift 2 ;;
  --fixture-evidence) FIXTURE=1; shift ;;
  -h|--help) echo "Usage: grype.sh [--input <path>] [--tool-name <name>] [--producer-key <key>] [--provenance <path>] [--fixture-evidence]"; exit 0 ;;
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

# Fail closed on an unrecognized SHAPE (v2.0.2). Without this the `else` branch of the
# extraction below coerced every missing key to 0, ss_counts_or_fail accepted those as
# valid non-negative integers, and an unreadable report produced a clean PASS — the
# exact fail-open this hotfix exists to close.
# #182: the bare `{critical,high,medium}` alternative is GONE. It let any process that could
# write this path assert clean counts with health=ok — a positive claim that the scanner ran.
# Production evidence is now a native Grype report that Sentinel normalizes itself, or nothing.
# NOT in a command substitution: ne_gate_input must run in THIS shell so its refusal can
# stop the collector. See the note on the function.
ne_gate_input "$TOOL" "$INPUT" '(type == "object") and ((.matches? | type) == "array")' \
	'{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}' "$FIXTURE" || exit 0

# Counts are DERIVED here from the native matches array — never read from the input as
# pre-computed totals. That is what makes them reconcile with the source report by
# construction rather than by assertion.
if [ "$NE_KIND" = fixture ]; then
	OV=$(jq '{critical_vulnerabilities:(.counts.critical//0), high_vulnerabilities:(.counts.high//0), medium_vulnerabilities:(.counts.medium//0), _native:false}' "$INPUT")
else
	OV=$(jq '([.matches[]?.vulnerability.severity // empty | ascii_upcase]) as $s
			| {critical_vulnerabilities:([$s[]|select(.=="CRITICAL")]|length),
			   high_vulnerabilities:([$s[]|select(.=="HIGH")]|length),
			   medium_vulnerabilities:([$s[]|select(.=="MEDIUM")]|length), _native:true}' "$INPUT")
fi
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

# #310: verify the EXECUTION RECORD before stamping anything. A parseable report is not a
# completed scan — the record carries the invoker's observed exit status and binds it to this
# report's digest, so a non-zero exit, a timeout, a kill, or stale output from an earlier
# successful run are all refused here rather than normalized into clean evidence.
if [ "$NE_KIND" != fixture ]; then
	if ! ne_execution_verify "$PRODUCER" "$INPUT"; then
		log_warn "$TOOL: $NE_EXEC_REASON; status=execution-error"
		ss_emit_collector "$TOOL" "execution-error" \
			"$(jq -n --arg r "$NE_EXEC_REASON" '{status:"execution-error", health:"untrusted-evidence", reason:$r, critical:0, high:0, medium:0}')" \
			'{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
		exit 0
	fi
else
	NE_EXEC_JSON='{"observed":false,"completed":null,"status":"fixture","exit_code":null}'
fi

# The evidence envelope is STAMPED HERE, after this collector parsed the native report
# itself. `trust.type` is produced internally; it is never echoed from the input.
if [ "$NE_KIND" = fixture ]; then
	NE_TRUST_TYPE="$NE_TRUST_FIXTURE"
else
	NE_TRUST_TYPE="$NE_TRUST_NATIVE"
fi
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "grype-json" "$NE_TRUST_TYPE" \
	"$(printf '%s' "$OV" | jq '{counts:{critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities}}')")
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" --arg h "$HEALTH" --argjson p "$PROV" \
	--argjson e "$ENVELOPE" --argjson np "$([ "$NE_KIND" = fixture ] && echo true || echo false)" \
	'{status:$s, health:$h, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities, provenance:$p, evidence:$e}
	 + (if $np then {non_production:true} else {} end)')
OVCOUNTS=$(printf '%s' "$OV" | jq '{critical_vulnerabilities,high_vulnerabilities,medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OVCOUNTS"
