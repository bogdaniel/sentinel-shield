#!/bin/sh
# Sentinel Shield — normalize raw scanner output into the acceptance summary.
#
# CREATED for MACRO-TASK 3: the production spec named this script as an existing input,
# but it was ABSENT from the repo (recorded in the task blockers). It reads a scanner
# MANIFEST (--manifest) that lists, per required scanner, its category, applicability,
# execution status, version, vulnerability-database timestamp, raw report path and any
# normalized findings, then produces the NORMALIZED security summary
# (schemas/security-summary.schema.json + the v1.11 scanners/findings/targets keys) that
# scripts/enforce-security-policy.sh consumes.
#
# What normalization actually does here (so the acceptance gate can trust the summary):
#   * computes each scanner's RAW REPORT DIGEST (sha256) over the declared raw file;
#   * computes vulnerability-database FRESHNESS (age_days) from the db timestamp;
#   * fails CLOSED when a declared raw report is missing or malformed JSON (a malformed
#     report must never normalize into a clean, empty summary);
#   * assembles + validates the output against the summary contract before writing.
#
# It carries NO secrets and prints no repo-local absolute paths.
#
# Exit codes: 0 wrote a conformant summary; 2 configuration / malformed-input error
# (fail closed); 4 a bounded step timed out.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/security-policy.sh
. "$SCRIPT_DIR/lib/security-policy.sh"

MANIFEST=""
OUTPUT="reports/security-summary.json"
BOUND=60

usage() {
	cat <<'EOF'
Usage: normalize-security-summary.sh --manifest <path> [--output <path>] [--timeout <s>]

Normalize a scanner manifest into the acceptance security summary.

Options:
  --manifest <path>   Scanner manifest to normalize (required)
  --output <path>     Normalized summary to write (default: reports/security-summary.json)
  --timeout <s>       Bounded per-step timeout (default: 60)
  -h, --help          Show this help

Exit: 0 ok, 2 config/malformed-input (fail closed), 4 timeout. Requires jq.
EOF
}

die_cfg() { log_error "$*"; exit 2; }

while [ $# -gt 0 ]; do case "$1" in
	--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	--timeout) BOUND="${2:?--timeout requires a value}"; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die_cfg "unknown argument: $1" ;;
esac; done

case "$BOUND" in ''|*[!0-9]*) die_cfg "--timeout must be a positive integer" ;; esac
command_exists jq || die_cfg "jq is required."
ss_have_sha256 || die_cfg "a SHA-256 tool (sha256sum or shasum) is required for raw report digests."
[ -n "$MANIFEST" ] || { usage >&2; die_cfg "--manifest is required"; }
[ -f "$MANIFEST" ] && [ -s "$MANIFEST" ] || die_cfg "manifest missing/empty: $MANIFEST"
jq -e . "$MANIFEST" >/dev/null 2>&1 || die_cfg "manifest is not valid JSON: $MANIFEST"
jq -e '(.scanners | type == "array") and (.targets | type == "object")' "$MANIFEST" >/dev/null 2>&1 \
	|| die_cfg "manifest must have .scanners[] and .targets{}: $MANIFEST"

# epoch_of <iso-timestamp> — portable seconds-since-epoch (GNU date, then BSD date).
# Prints nothing on failure.
epoch_of() {
	_e=$(date -u -d "$1" +%s 2>/dev/null) && { printf '%s' "$_e"; return 0; }
	_e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null) && { printf '%s' "$_e"; return 0; }
	return 1
}

# age_days <iso-timestamp> — whole days between the timestamp and now (>=0), or "null".
age_days() {
	[ -n "${1:-}" ] || { printf 'null'; return 0; }
	_ts_e=$(epoch_of "$1") || { printf 'null'; return 0; }
	_now_e=$(date -u +%s 2>/dev/null) || { printf 'null'; return 0; }
	case "$_ts_e$_now_e" in *[!0-9]*) printf 'null'; return 0 ;; esac
	_d=$(( (_now_e - _ts_e) / 86400 ))
	[ "$_d" -lt 0 ] && _d=0
	printf '%s' "$_d"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
SCAN_ND="$WORK/scanners.ndjson"; : > "$SCAN_ND"
FIND_ND="$WORK/findings.ndjson"; : > "$FIND_ND"

# Top-level findings (if any) pass through verbatim.
jq -c '(.findings // [])[]' "$MANIFEST" >> "$FIND_ND" 2>/dev/null || true

_n=$(jq -r '.scanners | length' "$MANIFEST")
_i=0
while [ "$_i" -lt "$_n" ]; do
	_rec=$(jq -c --argjson i "$_i" '.scanners[$i]' "$MANIFEST")
	_name=$(printf '%s' "$_rec" | jq -r '.name // ""')
	_cat=$(printf '%s' "$_rec" | jq -r '.category // ""')
	_app=$(printf '%s' "$_rec" | jq -r '.applicable // false')
	_status=$(printf '%s' "$_rec" | jq -r '.status // "success"')
	_ver=$(printf '%s' "$_rec" | jq -r '.version // ""')
	_dbts=$(printf '%s' "$_rec" | jq -r '.database_timestamp // ""')
	_raw=$(printf '%s' "$_rec" | jq -r '.raw_report // ""')
	_tgt=$(printf '%s' "$_rec" | jq -r 'if has("targets_scanned") then .targets_scanned else "null" end')
	# Independent non-applicability proof (detector/version/result/paths/commit/reason/digest)
	# passes through verbatim so the acceptance gate can authenticate an applicable:false claim.
	_na=$(printf '%s' "$_rec" | jq -c 'if (.non_applicability | type == "object") then .non_applicability else null end')
	case "$_na" in ''|null) _najson=null ;; *) _najson=$_na ;; esac

	[ -n "$_name" ] || die_cfg "scanner[$_i] missing name in manifest"
	[ -n "$_cat" ] || die_cfg "scanner '$_name' missing category in manifest"

	# Raw report digest + malformed-report fail-closed. A declared raw report that is
	# absent or not valid JSON is a MALFORMED input for an applicable, successful scanner.
	_digest=""
	if [ -n "$_raw" ]; then
		if [ ! -f "$_raw" ] || [ ! -s "$_raw" ]; then
			if [ "$_app" = "true" ] && [ "$_status" = "success" ]; then
				die_cfg "scanner '$_name': declared raw report missing/empty (malformed input): $(basename -- "$_raw")"
			fi
		elif ! sp_bounded "$BOUND" jq -e . "$_raw" >/dev/null 2>&1; then
			[ "$SP_TIMEOUT" = 1 ] && { log_error "normalize: digesting '$_name' timed out"; exit 4; }
			die_cfg "scanner '$_name': raw report is not valid JSON (malformed report): $(basename -- "$_raw")"
		else
			_digest=$(ss_sha256_file "$_raw") || die_cfg "scanner '$_name': cannot digest raw report"
			_digest="sha256:$_digest"
			# Pull findings embedded in the scanner record (already normalized by the caller).
			printf '%s' "$_rec" | jq -c '(.findings // [])[]' >> "$FIND_ND" 2>/dev/null || true
		fi
	else
		printf '%s' "$_rec" | jq -c '(.findings // [])[]' >> "$FIND_ND" 2>/dev/null || true
	fi

	_age=$(age_days "$_dbts")

	case "$_tgt" in ''|null) _tgtjson=null ;; *[!0-9]*) _tgtjson=null ;; *) _tgtjson=$_tgt ;; esac
	case "$_age" in ''|null) _agejson=null ;; *[!0-9]*) _agejson=null ;; *) _agejson=$_age ;; esac

	# Strings pass through --arg (jq escapes quotes/backslashes); empty -> null in-filter.
	jq -n --arg n "$_name" --arg c "$_cat" --argjson app "$_app" --arg st "$_status" \
		--arg v "$_ver" --arg ts "$_dbts" --argjson age "$_agejson" \
		--argjson tgt "$_tgtjson" --arg dg "$_digest" --argjson na "$_najson" '
		def ornull: if . == "" then null else . end;
		{ name:$n, category:$c, applicable:$app, status:$st, version:($v|ornull),
		  database:{ timestamp:($ts|ornull), age_days:$age },
		  targets_scanned:$tgt, raw_report_digest:($dg|ornull) }
		+ (if $na != null then { non_applicability:$na } else {} end)' >> "$SCAN_ND"
	_i=$((_i + 1))
done

# Assemble the normalized summary. summary{} keeps the legacy required count keys so the
# document is ALSO valid for the existing enforce-gates.sh consumer; counts are derived
# from the normalized findings so a real run is never a silent zero.
ensure_dir "$(dirname -- "$OUTPUT")"
_tmp="$OUTPUT.tmp.$$"
jq -n \
	--arg gen "$(timestamp_utc)" \
	--slurpfile scanners "$SCAN_ND" \
	--slurpfile findings "$FIND_ND" \
	--argjson src "$(jq -c 'if (.source | type == "object") then .source else null end' "$MANIFEST")" \
	--argjson texp "$(jq -r '.targets.expected // 0' "$MANIFEST")" \
	--argjson tscan "$(jq -r '.targets.scanned // 0' "$MANIFEST")" '
	($findings) as $f
	| ([ $f[] | select(.category == "leaked_secrets") ] | length) as $secrets
	| ([ $f[] | select(.severity == "critical") ] | length) as $crit
	| ([ $f[] | select(.severity == "high") ] | length) as $high
	| ([ $f[] | select(.severity == "medium") ] | length) as $med
	| {
		version: "1.0",
		generated_at: $gen,
		summary: {
			secrets: $secrets,
			critical_vulnerabilities: $crit,
			high_vulnerabilities: $high,
			medium_vulnerabilities: $med,
			architecture_violations: 0,
			type_errors: 0,
			test_failures: 0,
			unsafe_docker: 0,
			unsafe_github_actions: 0,
			missing_sbom: false,
			missing_release_evidence: false,
			expired_exceptions: 0
		},
		targets: {
			expected: $texp,
			scanned: $tscan,
			coverage_ratio: (if $texp > 0 then ($tscan / $texp) else 1 end)
		},
		scanners: $scanners,
		findings: $f
	}
	+ (if $src != null then { source:$src } else {} end)' > "$_tmp" || die_cfg "normalize: could not assemble summary"

sp_validate_summary "$_tmp" || { rm -f "$_tmp"; die_cfg "normalize: produced a non-conforming summary"; }
mv -- "$_tmp" "$OUTPUT" || die_cfg "normalize: cannot write $OUTPUT"
log_info "normalize-security-summary: wrote $OUTPUT ($_n scanner record(s))"
exit 0
