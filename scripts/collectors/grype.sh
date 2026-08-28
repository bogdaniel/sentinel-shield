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
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/collector-evidence.sh
. "$SCRIPT_DIR/../lib/collector-evidence.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SCRIPT_DIR/../lib/scanner-contracts.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "$SCRIPT_DIR/../lib/normalized-evidence.sh"
# The database policy below is scoped by adoption mode and compares calendar dates; both already
# have one implementation in this engine and neither is reimplemented here.
. "$SCRIPT_DIR/../lib/adoption-mode.sh"
. "$SCRIPT_DIR/../lib/control-waivers.sh"
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
  --fixture-evidence)
	# RETIRED (Option B). This flag asked the collector to accept a normalized-evidence envelope
	# with precomputed counts and trust.type=fixture in place of a real scan. Evidence binding is
	# now absolute: a collector reads no field until provenance proves a scan produced THIS report,
	# and there is no exemption a caller can request. The flag therefore cannot do what its name
	# promises.
	#
	# It fails LOUDLY rather than being ignored. Silently accepting a retired flag is worse than
	# removing it: the caller believes fixture evidence was produced, the collector produces none,
	# and the difference only shows up as a missing tool in a summary nobody reads closely. Exit 2
	# is the configuration-error status used elsewhere for an unusable invocation.
	printf '%s\n' "[sentinel-shield][error] grype: --fixture-evidence is retired and cannot be honoured." >&2
	printf '%s\n' "[sentinel-shield][error]   Fixture evidence cannot bypass evidence binding. A report is accepted only when it is" >&2
	printf '%s\n' "[sentinel-shield][error]   natively valid AND accompanied by generated provenance whose digest matches it." >&2
	printf '%s\n' "[sentinel-shield][error]   Generate real provenance for the fixture instead of requesting a trust downgrade." >&2
	exit 2
	;;
  -h|--help) echo "Usage: grype.sh [--input <path>] [--tool-name <name>] [--producer-key <key>] [--provenance <path>]"; exit 0 ;;
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

# EVIDENCE BINDING (#137). `{"matches":[]}` is the forgeable shape: two bytes of structure and a
# reader concludes "clean". Binding runs before any match is counted -- the digest must be this
# report's, the producer must be grype, the completion state must carry a scan result, and where a
# subject was requested the provenance must describe that subject and no other.
if ! ce_bind "$INPUT" "grype" "${SENTINEL_SHIELD_GRYPE_SUBJECT:-}"; then
	log_error "$TOOL: evidence rejected — ${CE_REASON:-unbound}"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "${CE_REASON:-unbound}" '{status:"execution-error", health:"unbound-evidence", critical:0, high:0, medium:0, reason:$r}')" '{}'
	exit 0
fi
if ! sc_grype_validate "$INPUT"; then
	log_error "$TOOL: not a valid Grype report — ${SC_REASON:-unknown}"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg r "${SC_REASON:-unknown}" '{status:"invalid-output", health:"invalid-output", critical:0, high:0, medium:0, reason:$r}')" '{}'
	exit 0
fi

# Native provenance fallback: Grype embeds its own version and DB build time.
NV=$(jq -r '.descriptor.version // ""' "$INPUT" 2>/dev/null) || NV=""
NDB=$(jq -r '.descriptor.db.built // ""' "$INPUT" 2>/dev/null) || NDB=""
PROV=$(ss_provenance_object "$PROVENANCE" "$NV" "$NDB")

# A CLEAN RESULT MUST NAME THE SCANNER THAT PRODUCED IT (#137-AC2).
#
# The version was read for the provenance record and never gated on. "No matches" from an
# unidentified scanner is not a verdict anyone can act on: there is no way to tell whether an
# approved build did the scanning, and the criterion asks a clean result to prove exactly that.
# The sidecar may supply it when the native report does not, so both are consulted before failing.
# SCOPED TO A CLEAN RESULT, which is what the criterion actually says: "A clean result proves the
# exact target was scanned to completion by an approved scanner version/database." A report that
# CARRIES findings is evidence of the findings regardless of who produced it, and refusing those
# for a missing descriptor would discard real vulnerability data to enforce a metadata rule.
_gr_ver="$NV"
[ -n "$_gr_ver" ] || _gr_ver=$(printf '%s' "$PROV" | jq -r '.scanner_version // ""' 2>/dev/null) || _gr_ver=""
_gr_matches=$(jq -r '[.matches[]?] | length' "$INPUT" 2>/dev/null) || _gr_matches=0
case "$_gr_matches" in ''|*[!0-9]*) _gr_matches=0 ;; esac
if [ "$_gr_matches" -eq 0 ] && { [ -z "$_gr_ver" ] || [ "$_gr_ver" = unknown ] || [ "$_gr_ver" = null ]; }; then
	log_error "$TOOL: the report names no scanner version — a clean result cannot be attributed to an approved scanner"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","health":"execution-error","critical":0,"high":0,"medium":0,"reason":"no scanner version in report or provenance"}' '{}'
	exit 0
fi

# ---------------------------------------------------------------------------
# VULNERABILITY DATABASE METADATA POLICY (#137-AC5)
#
# "No matches" from a scanner whose database is a year old, or absent, is not a clean result --
# it is an unanswered question wearing a clean result's clothes. The build timestamp was read for
# the provenance record and otherwise ignored, so every one of these produced an unqualified pass.
#
# Five conditions, one policy: MISSING (no build timestamp at all), MALFORMED (present but not a
# timestamp), FUTURE-DATED (built after now, beyond tolerated clock skew), EXPIRED (older than the
# maximum age), and otherwise CURRENT.
#
# The policy is applied BY MODE, as the criterion states. In a gated mode (strict, regulated) a
# database that cannot be vouched for fails closed. In report-only and baseline it warns and the
# scan still reports, because those modes exist to observe a repository rather than to gate it.
#
# Thresholds follow the control-waiver convention already in the engine: a documented default for
# an UNSET variable, a tighter value under regulated, and a set-but-EMPTY value treated as a
# configuration error rather than silently substituted -- an operator who writes
# SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS= is saying something different from not writing it at all.
GRYPE_DB_MAX_AGE_DAYS_DEFAULT=7
GRYPE_DB_MAX_AGE_DAYS_REGULATED=2
# Clock skew is expressed in days, matching the waiver convention: runners disagree across a UTC
# midnight, but a database built next month is not skew.
GRYPE_DB_MAX_SKEW_DAYS=1

grype__db_max_days() {
	if [ -n "${SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS+set}" ]; then
		case "$SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS" in
		'' | *[!0-9]*) return 2 ;;
		*) printf '%s' "$SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS"; return 0 ;;
		esac
	fi
	if [ "$(am_mode)" = regulated ]; then printf '%s' "$GRYPE_DB_MAX_AGE_DAYS_REGULATED"
	else printf '%s' "$GRYPE_DB_MAX_AGE_DAYS_DEFAULT"; fi
}

# Classify without deciding: the state is a fact about the database, the response is policy.
# Dates are compared with the engine's existing civil-date primitives rather than date(1) parsing,
# which is neither portable nor deterministic across GNU and BSD. Day granularity is the right
# resolution for a policy whose threshold is expressed in days.
grype__db_state() { # grype__db_state <timestamp> -> missing|malformed|future|expired|current
	[ -n "$1" ] || { printf 'missing'; return 0; }
	_g_day="${1%%T*}"
	cw__valid_date "$_g_day" || { printf 'malformed'; return 0; }
	_g_today=$(cw_today_utc) || { printf 'malformed'; return 0; }
	_g_built=$(cw__days "$_g_day")
	_g_now=$(cw__days "$_g_today")
	[ "$_g_built" -gt "$((_g_now + GRYPE_DB_MAX_SKEW_DAYS))" ] && { printf 'future'; return 0; }
	_g_max=$(grype__db_max_days) || { printf 'malformed'; return 0; }
	[ "$((_g_now - _g_built))" -gt "$_g_max" ] && { printf 'expired'; return 0; }
	printf 'current'
}

if ! am_mode_valid; then
	log_error "$TOOL: SENTINEL_SHIELD_MODE '$(am_mode)' is not one of: $AM_MODES_ALL"
	ss_emit_collector "$TOOL" "execution-error" \
		"$(jq -n --arg m "$(am_mode)" '{status:"execution-error", health:"execution-error", critical:0, high:0, medium:0, reason:("unknown mode: " + $m)}')" '{}'
	exit 0
fi
if ! grype__db_max_days >/dev/null; then
	log_error "$TOOL: SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS is set to an unusable value — a configuration error, not a default"
	ss_emit_collector "$TOOL" "execution-error" \
		'{"status":"execution-error","health":"execution-error","critical":0,"high":0,"medium":0,"reason":"unusable SENTINEL_SHIELD_GRYPE_DB_MAX_AGE_DAYS"}' '{}'
	exit 0
fi
GRYPE_DB_STATE=$(grype__db_state "$NDB")
if [ "$GRYPE_DB_STATE" != current ]; then
	if am_gated; then
		log_error "$TOOL: vulnerability database is $GRYPE_DB_STATE and mode '$(am_mode)' gates releases — a scan against an unvouched database is not a clean result"
		ss_emit_collector "$TOOL" "execution-error" \
			"$(jq -n --arg s "$GRYPE_DB_STATE" --arg m "$(am_mode)" \
				'{status:"execution-error", health:"execution-error", critical:0, high:0, medium:0,
				  reason:("vulnerability database " + $s + " in " + $m + " mode"), database_state:$s}')" '{}'
		exit 0
	fi
	log_warn "$TOOL: vulnerability database is $GRYPE_DB_STATE; findings are reported but are not gate-quality evidence"
fi

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
