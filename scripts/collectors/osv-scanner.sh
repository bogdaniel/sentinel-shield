#!/bin/sh
# Sentinel Shield collector — osv-scanner. Maps vulnerability severities to vuln buckets
# (critical/high/medium_vulnerabilities). Accepts native format or a normalized
# {critical,high,medium} object. Severity parsing is best-effort; see docs.
#
# HEALTH + PROVENANCE (v2 hardening): the tool_report now carries an explicit `health`
# state and a `provenance` object so callers can tell apart:
#   ok            scanner ran, scanned targets, found nothing
#   findings      scanner ran, findings present
#   no-targets    scanner ran but no applicable manifests were scannable (empty results)
#   scanner-error scanner produced no report (did not run / crashed)  -> status unavailable
#   parser-error  report present but not valid JSON                    -> status execution-error
# provenance (scanner_version + vulnerability_db.timestamp) is read from the sidecar
# reports/raw/osv-scanner.provenance.json (written by the audit wrapper); a populated
# version is what distinguishes an EMPTY report from a scanner that DID NOT RUN.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"
TOOL="osv-scanner"
# #310/#204: PRODUCER is the VERIFIED EXECUTION IDENTITY and is captured HERE, before any
# argument is parsed, so no presentation argument can overwrite or influence it.
#
# TOOL is the CHANNEL — the summary key this evidence is aggregated under. The builder renames
# it per stack (osv-scanner -> osv_scanner), and several producers may legitimately share one
# channel (php-style and php-cs-fixer both emit php_style). PRODUCER is what actually ran.
#
# These were ONE variable. `--tool-name` set both, so build-security-summary.sh — which invokes
# collectors with the channel — made ne_execution_verify demand a record naming the channel,
# while the audit that wrote the record named the producer. osv-scanner and dependency-check
# rejected their own real execution records in production for exactly that reason.
PRODUCER="osv-scanner"
FIXTURE=0
INPUT="reports/raw/osv-scanner.json"
PROVENANCE=""
while [ $# -gt 0 ]; do case "$1" in
  --input) INPUT="${2:?--input requires a value}"; shift 2 ;;
  --tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		--producer-key) PRODUCER="${2:?--producer-key requires a value}"; shift 2 ;;
  --provenance) PROVENANCE="${2:?--provenance requires a value}"; shift 2 ;;
  --fixture-evidence) FIXTURE=1; shift ;;
  -h|--help) echo "Usage: osv-scanner.sh [--input <path>] [--tool-name <name>] [--provenance <path>] [--fixture-evidence]"; exit 0 ;;
  *) log_error "unknown argument: $1"; exit 2 ;;
esac; done
ss_require_jq
[ -n "$PROVENANCE" ] || PROVENANCE="${INPUT%.json}.provenance.json"
PROV=$(ss_provenance_object "$PROVENANCE" "" "")

# Health-aware preflight (supersedes ss_collector_guard for this collector so the
# scanner-error / parser-error states are SURFACED, not collapsed to a bare status).
if [ ! -f "$INPUT" ] || [ ! -s "$INPUT" ]; then
	log_warn "$TOOL: input '$INPUT' missing or empty; scanner did not run (health=scanner-error)"
	REPORT=$(jq -n --argjson p "$PROV" '{status:"unavailable", health:"scanner-error", critical:0, high:0, medium:0, provenance:$p}')
	ss_emit_collector "$TOOL" "unavailable" "$REPORT" '{}'
	exit 0
fi
if ! jq -e . "$INPUT" >/dev/null 2>&1; then
	log_error "$TOOL: invalid JSON in '$INPUT' (health=parser-error)"
	REPORT=$(jq -n --argjson p "$PROV" '{status:"execution-error", health:"parser-error", critical:0, high:0, medium:0, provenance:$p}')
	ss_emit_collector "$TOOL" "execution-error" "$REPORT" '{}'
	# fail-closed: unparseable scanner output is an error, not a clean result
	exit 2
fi

# Fail closed on an unrecognized SHAPE (v2.0.2, #51). Without this the `else` branch of the
# extraction below coerced every missing key to 0, ss_counts_or_fail accepted those as
# valid non-negative integers, and an unreadable report produced a clean PASS — the
# exact fail-open this hotfix exists to close.
# #182: the bare `{critical,high,medium}` alternative is GONE — it let any writer of this
# path assert clean counts with a positive health signal. NOT in a command substitution:
# ne_gate_input must run in THIS shell so its refusal can stop the collector.
ne_gate_input "$TOOL" "$INPUT" '(type == "object") and ((.results? | type) == "array")' \
	'{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}' "$FIXTURE" || exit 0
# Bucket by the vulnerability's OWN severity instead of collapsing everything into high (#52).
#
# Previously every OSV finding — regardless of severity — became high_vulnerabilities with
# critical hardcoded to 0. A project that sets gates.fail_on.high_vulnerabilities:false
# during migration (a documented, expected override) while keeping critical:true was
# therefore COMPLETELY BLIND to critical CVEs reported by OSV.
#
# OSV carries severity in `database_specific.severity` (CRITICAL/HIGH/MODERATE/LOW) and/or
# a CVSS vector in `severity[]`. Prefer the explicit label; fall back to the CVSS v3 base
# score when only a vector is present. An UNKNOWN severity is counted as MEDIUM rather
# than dropped — an unclassifiable vulnerability is still a vulnerability.
OV=$(jq 'if has("results") then
			([ .results[]?.packages[]?.vulnerabilities[]?
			   | ((.database_specific.severity // "") | ascii_upcase) as $lbl
			   | if   $lbl == "CRITICAL" then "critical"
			     elif $lbl == "HIGH" then "high"
			     elif ($lbl == "MODERATE" or $lbl == "MEDIUM") then "medium"
			     elif $lbl == "LOW" then "low"
			     else
			       # No usable label. Classify from the CVSS vector IMPACT metrics — not
			       # a single all-high pattern. The old code matched only `/C:H/I:H/A:H` and
			       # dumped everything else into `medium`, so a genuine HIGH or an
			       # off-pattern CRITICAL was downgraded to medium — which does NOT gate in
			       # baseline mode. A real critical escaping the baseline gate is a fail-open,
			       # the exact defect these collector fixes target.
			       #
			       # Rule (fail-closed, impact-based): all three impacts High -> critical;
			       # ANY impact High -> at least high; a CVSS vector with no High impact ->
			       # medium; no CVSS vector at all -> medium (unknown, counted-not-dropped).
			       # This never downgrades a high-impact vuln below `high`, so it can no
			       # longer slip past baseline.
			       # ponytail: heuristic, not the real CVSS base score (exploitability/scope
			       # ignored) — it can over-classify a high-AC vuln, which is the safe
			       # direction. Upgrade path: compute the v3.1 base score if precision is
			       # ever needed.
			       ([ .severity[]? | select((.type // "") | startswith("CVSS")) | .score // "" ]) as $vecs
			       | ($vecs | any(test("/C:H/I:H/A:H"))) as $allhigh
			       | ($vecs | any(test("/C:H|/I:H|/A:H"))) as $anyhigh
			       | if   $allhigh then "critical"
			         elif $anyhigh then "high"
			         else "medium" end
			     end ]) as $b
			| {critical_vulnerabilities:([$b[]|select(.=="critical")]|length),
			   high_vulnerabilities:([$b[]|select(.=="high")]|length),
			   medium_vulnerabilities:([$b[]|select(.=="medium")]|length),
			   _results:([.results[]?]|length), _native:true}
		 else
			# Reachable only on the fixture path — the production gate guarantees `.results`.
			# Counts come from the ENVELOPE payload, never from bare top-level keys.
			{critical_vulnerabilities:(.counts.critical//0), high_vulnerabilities:(.counts.high//0), medium_vulnerabilities:(.counts.medium//0),
			 _results:null, _native:false}
		 end' "$INPUT")
# Fail closed on negative/float/non-numeric counts (v2.0.2); the builder SUMS these.
ss_counts_or_fail "$TOOL" "$OV" '{"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0}'
TOTAL=$(printf '%s' "$OV" | jq '[.critical_vulnerabilities,.high_vulnerabilities,.medium_vulnerabilities]|add // 0')
NATIVE=$(printf '%s' "$OV" | jq -r '._native')
RC=$(printf '%s' "$OV" | jq -r '._results')

if [ "$TOTAL" -gt 0 ]; then
	STATUS="fail"; HEALTH="findings"
elif [ "$NATIVE" = "true" ] && [ "$RC" = "0" ]; then
	# results present but empty: nothing was scannable (no applicable targets).
	STATUS="pass"; HEALTH="no-targets"
else
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

# The envelope is STAMPED HERE, after this collector parsed the native report itself.
if [ "$NE_KIND" = fixture ]; then NE_TRUST_TYPE="$NE_TRUST_FIXTURE"; else NE_TRUST_TYPE="$NE_TRUST_NATIVE"; fi
ENVELOPE=$(ne_envelope "$PRODUCER" "$INPUT" "osv-scanner-json" "$NE_TRUST_TYPE" \
	"$(printf '%s' "$OV" | jq '{counts:{critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities}}')")
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" --arg h "$HEALTH" --argjson p "$PROV" \
	--argjson e "$ENVELOPE" --argjson np "$([ "$NE_KIND" = fixture ] && echo true || echo false)" \
	'{status:$s, health:$h, critical:.critical_vulnerabilities, high:.high_vulnerabilities, medium:.medium_vulnerabilities, provenance:$p, evidence:$e}
	 + (if $np then {non_production:true} else {} end)')
OVCOUNTS=$(printf '%s' "$OV" | jq '{critical_vulnerabilities,high_vulnerabilities,medium_vulnerabilities}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OVCOUNTS"
