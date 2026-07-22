#!/bin/sh
# Sentinel Shield — production security policy library (POSIX sh).
#
# Source this file; do not execute it. It defines the fail-closed validators and
# helpers behind scripts/enforce-security-policy.sh (the production security
# acceptance + incident-response gate). It READS config/production-security-policy.json
# (schemas/production-security-policy.schema.json), the normalized security summary
# (schemas/security-summary.schema.json + the v1.11 scanners/findings/targets keys),
# the accepted-risks waiver file (schemas/accepted-risks.schema.json + v1.11 fields),
# and validates the emitted acceptance report (schemas/security-acceptance.schema.json).
# It NEVER mutates policy/summary inputs and carries no secrets.
#
# Requires the shared library FIRST (for log_*/command_exists) and jq:
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/security-policy.sh"
#
# All validators FAIL CLOSED: missing / empty / malformed / non-conformant input
# returns non-zero, and callers must treat that as a gate failure — never a pass.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_SECURITY_POLICY_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_SECURITY_POLICY_LOADED=1

# SP_TIMEOUT is read by the caller (enforce-security-policy.sh) to distinguish an
# operation that timed out from a clean result (distinct exit code 4).
SP_TIMEOUT=0

# sp_bounded <seconds> <cmd...> — run a bounded operation. When a timeout tool is
# present, wrap the command; on timeout set SP_TIMEOUT=1 and return 124. Without a
# timeout tool the command runs directly (jq over a local file cannot hang on I/O),
# preserving behaviour on hosts (e.g. stock macOS) with no timeout(1).
# _sp_is_external <name> — 0 if <name> resolves to a filesystem path (an external
# program `timeout` can exec), 1 if it is a shell function/builtin or is unknown.
# `timeout` cannot run a shell function, so functions must be invoked directly.
_sp_is_external() {
	case $(command -v -- "$1" 2>/dev/null) in
		*/*) return 0 ;;
		*) return 1 ;;
	esac
}

sp_bounded() {
	_sp_lim=$1; shift
	# Only wrap EXTERNAL commands in `timeout`; a shell function (e.g. the local
	# jq-based validators) would make `timeout` fail with 127 ("No such file or
	# directory"). Those validations are bounded local jq work, not hangable.
	if ! _sp_is_external "$1"; then
		"$@"; _sp_rc=$?
	elif command_exists timeout; then
		timeout "$_sp_lim" "$@"; _sp_rc=$?
	elif command_exists gtimeout; then
		gtimeout "$_sp_lim" "$@"; _sp_rc=$?
	else
		"$@"; _sp_rc=$?
	fi
	# SP_TIMEOUT is read cross-file by scripts/enforce-security-policy.sh and
	# scripts/normalize-security-summary.sh; shellcheck cannot see that use.
	# shellcheck disable=SC2034
	if [ "$_sp_rc" = 124 ]; then SP_TIMEOUT=1; fi
	return "$_sp_rc"
}

# sp_today_utc — current date as YYYY-MM-DD (UTC), overridable for deterministic tests.
sp_today_utc() {
	if [ -n "${SENTINEL_SHIELD_SECURITY_NOW:-}" ]; then
		printf '%s' "$SENTINEL_SHIELD_SECURITY_NOW"
	else
		date -u +%Y-%m-%d
	fi
}

# sp_valid_date <YYYY-MM-DD> — 0 if a real calendar date (pure shell, portable).
sp_valid_date() {
	_spd="${1:-}"
	case "$_spd" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	_spy=${_spd%%-*}; _sprest=${_spd#*-}; _spm=${_sprest%%-*}; _spday=${_sprest#*-}
	# base-10 normalize (POSIX-safe; no octal pitfalls on 08/09).
	_spy=$(printf '%s' "$_spy" | sed 's/^0*//'); [ -n "$_spy" ] || _spy=0
	_spm=$(printf '%s' "$_spm" | sed 's/^0*//'); [ -n "$_spm" ] || _spm=0
	_spday=$(printf '%s' "$_spday" | sed 's/^0*//'); [ -n "$_spday" ] || _spday=0
	[ "$_spy" -ge 1 ] || return 1
	[ "$_spm" -ge 1 ] && [ "$_spm" -le 12 ] || return 1
	[ "$_spday" -ge 1 ] || return 1
	case "$_spm" in
		1|3|5|7|8|10|12) _spmax=31 ;;
		4|6|9|11) _spmax=30 ;;
		2)
			if { [ $((_spy % 4)) -eq 0 ] && [ $((_spy % 100)) -ne 0 ]; } || [ $((_spy % 400)) -eq 0 ]; then
				_spmax=29
			else
				_spmax=28
			fi ;;
		*) return 1 ;;
	esac
	[ "$_spday" -le "$_spmax" ] || return 1
	return 0
}

# sp_jdn <YYYY-MM-DD> — echo the Julian Day Number (integer). Call only AFTER
# sp_valid_date. Enables day-difference arithmetic without GNU/BSD date(1) skew.
sp_jdn() {
	_jd="${1:-}"
	_jy=${_jd%%-*}; _jr=${_jd#*-}; _jm=${_jr%%-*}; _jday=${_jr#*-}
	_jy=$(printf '%s' "$_jy" | sed 's/^0*//'); [ -n "$_jy" ] || _jy=0
	_jm=$(printf '%s' "$_jm" | sed 's/^0*//'); [ -n "$_jm" ] || _jm=0
	_jday=$(printf '%s' "$_jday" | sed 's/^0*//'); [ -n "$_jday" ] || _jday=0
	_ja=$(( (14 - _jm) / 12 ))
	_jyy=$(( _jy + 4800 - _ja ))
	_jmm=$(( _jm + 12 * _ja - 3 ))
	printf '%s' "$(( _jday + (153 * _jmm + 2) / 5 + 365 * _jyy + _jyy / 4 - _jyy / 100 + _jyy / 400 - 32045 ))"
}

# sp_lifetime_days <created> <expires> — echo (expires - created) in whole days, or
# nothing + return 1 if either date is invalid.
sp_lifetime_days() {
	sp_valid_date "$1" && sp_valid_date "$2" || return 1
	printf '%s' "$(( $(sp_jdn "$2") - $(sp_jdn "$1") ))"
}

# sp_digest_ok <value> — 0 if <value> is a plausible content digest ("sha256:" + 64 hex,
# or a bare 64-hex). A required scanner with no verifiable raw digest fails closed.
sp_digest_ok() {
	case "${1:-}" in
		sha256:[0-9a-f][0-9a-f]*) _spdg=${1#sha256:} ;;
		*) _spdg=${1:-} ;;
	esac
	case "$_spdg" in
		*[!0-9a-f]*|'') return 1 ;;
	esac
	[ "${#_spdg}" -eq 64 ]
}

# sp_nonapplicability_complete <json> — 0 iff the compact non_applicability proof object
# carries EVERY independent-proof field a non-applicable claim needs to be trusted:
# detector name, detector version, detector result, inspected manifests/paths (a non-empty
# array), and the source commit the detector inspected. The policy-approved reason and the
# detector-report digest are validated SEPARATELY by the caller so each yields its own
# stable violation token. An `applicable:false` claim without these is self-asserted, not
# self-authenticating, so this FAILS CLOSED on any missing/empty field. Pass the compact
# object as $1 (empty string => not complete).
sp_nonapplicability_complete() {
	command_exists jq || { log_error "sp_nonapplicability_complete: jq is required"; return 2; }
	[ -n "${1:-}" ] || return 1
	printf '%s' "$1" | jq -e '
		(type == "object")
		and (.detector | type == "string" and (length > 0))
		and (.detector_version | type == "string" and (length > 0))
		and (.result | type == "string" and (length > 0))
		and (.inspected_paths | type == "array" and (length > 0)
			and all(type == "string" and (length > 0)))
		and (.source_commit | type == "string" and (length > 0))
	' >/dev/null 2>&1
}

# --- policy validation -------------------------------------------------------
# sp_validate_policy <path> — fail-closed structural conformance to
# schemas/production-security-policy.schema.json. Missing/empty/malformed/non-conformant => non-zero.
sp_validate_policy() {
	command_exists jq || { log_error "sp_validate_policy: jq is required"; return 2; }
	[ -n "${1:-}" ] && [ -s "$1" ] || { log_error "sp_validate_policy: missing/empty policy '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "sp_validate_policy: invalid JSON in '$1'"; return 1; }
	jq -e '
		(.schema_version == "1")
		and (.policy_version | type == "string" and (test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
		and (.updated | type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))
		and (.blocking_severities | type == "array" and (length > 0))
		and (.waivable_severities | type == "array")
		and (.emergency_waivable_severities | type == "array")
		and (.never_waivable_categories | type == "array" and (length > 0))
		and (.categories | type == "object" and (length > 0)
			and (to_entries | all((.value.blocking | type == "boolean") and (.value.reason | type == "string" and (length > 0)))))
		and (.required_scanners | type == "array" and (length > 0)
			and all((.name | type == "string" and (length > 0))
				and (.category | type == "string" and (length > 0))
				and (.applies_when | . == "always" or . == "manifest_present" or . == "dockerfile_present" or . == "workflows_present")))
		and (.scanner_freshness.max_database_age_days | type == "number")
		and (.scanner_freshness.stale_action == "block")
		and (.scanner_freshness.unverifiable_age_action == "block")
		and (.scanner_execution.failure_action == "block")
		and (.scanner_execution.zero_targets_action == "block")
		and (.scanner_execution.malformed_report_action == "fail-closed")
		and (.scanner_execution.missing_applicable_scanner_action == "block")
		and (.scanner_execution.missing_raw_digest_action == "block")
		and (.provenance.unsigned_action == "block")
		and (.provenance.unverifiable_action == "block")
		and (.waivers.max_lifetime_days | type == "number" and (. >= 1))
		and (.waivers.mandatory_owner | type == "boolean")
		and (.waivers.require_issue_reference | type == "boolean")
		and (.waivers.require_review_approval | type == "boolean")
		and (.waivers.prohibit_blanket_suppression | type == "boolean")
		and (.waivers.prohibited_scopes | type == "array")
		and (.regression_baseline.enabled | type == "boolean")
		and (.regression_baseline.min_coverage_ratio | type == "number")
		and (.emergency_release.allowed | type == "boolean")
		and (.emergency_release.max_lifetime_days | type == "number" and (. >= 1))
		and (.emergency_release.require_incident_reference | type == "boolean")
		and (.incident_response.disclosure_contact | type == "string" and (length > 0))
		and (.incident_response.runbook | type == "string" and (length > 0))
		and (if has("applicability") then (
			(.applicability | type == "object")
			and (.applicability.require_independent_proof | type == "boolean")
			and (.applicability.reject_all_non_applicable | type == "boolean")
			and (.applicability.always_required_categories | type == "array"
				and all(type == "string" and (length > 0)))
			and (.applicability.disabled_scanners | type == "array"
				and all(type == "string" and (length > 0)))
			and (.applicability.approved_non_applicability_reasons | type == "array"
				and all(type == "string" and (length > 0)))
		) else true end)
	' "$1" >/dev/null 2>&1 || { log_error "sp_validate_policy: '$1' does not conform to production-security-policy.schema.json"; return 1; }
	return 0
}

# --- normalized summary validation -------------------------------------------
# sp_validate_summary <path> — fail-closed structural conformance for the normalized
# security summary that the acceptance gate consumes. Requires the v1.11 scanners[],
# findings[] and targets object. Missing/empty/malformed => non-zero (a MALFORMED report
# must never read as a clean zero).
sp_validate_summary() {
	command_exists jq || { log_error "sp_validate_summary: jq is required"; return 2; }
	[ -n "${1:-}" ] && [ -s "$1" ] || { log_error "sp_validate_summary: missing/empty summary '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "sp_validate_summary: invalid JSON in '$1'"; return 1; }
	jq -e '
		(.version | type == "string")
		and (.generated_at | type == "string")
		and (.targets | type == "object")
		and (.targets.expected | type == "number")
		and (.targets.scanned | type == "number")
		and (.scanners | type == "array")
		and (.scanners | all(
			(.name | type == "string" and (length > 0))
			and (.category | type == "string" and (length > 0))
			and (.applicable | type == "boolean")
			and (.status | . == "success" or . == "error" or . == "not-applicable")))
		and (.findings | type == "array")
		and (.findings | all(
			(.id | type == "string" and (length > 0))
			and (.scanner | type == "string" and (length > 0))
			and (.category | type == "string" and (length > 0))
			and (.severity | . == "critical" or . == "high" or . == "medium" or . == "low" or . == "info")))
	' "$1" >/dev/null 2>&1 || { log_error "sp_validate_summary: '$1' is not a conformant normalized security summary"; return 1; }
	return 0
}

# --- acceptance report validation --------------------------------------------
# sp_validate_acceptance <path> — fail-closed conformance to
# schemas/security-acceptance.schema.json. The enforcer refuses to emit a report it
# cannot validate.
sp_validate_acceptance() {
	command_exists jq || { log_error "sp_validate_acceptance: jq is required"; return 2; }
	[ -n "${1:-}" ] && [ -s "$1" ] || { log_error "sp_validate_acceptance: missing/empty report '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "sp_validate_acceptance: invalid JSON in '$1'"; return 1; }
	jq -e '
		(.schema_version == "1")
		and (.generated_at | type == "string" and (length > 0))
		and (.policy_version | type == "string" and (length > 0))
		and (.decision | . == "accepted" or . == "accepted-emergency" or . == "rejected" or . == "error")
		and (.exit_code | . == 0 or . == 1 or . == 2 or . == 4)
		and (.scanners | type == "array")
		and (.coverage | type == "object")
		and (.findings | type == "object")
		and (.waivers.applied | type == "array")
		and (.waivers.rejected | type == "array")
		and (.regression | type == "object")
		and (.violations | type == "array")
	' "$1" >/dev/null 2>&1 || { log_error "sp_validate_acceptance: '$1' does not conform to security-acceptance.schema.json"; return 1; }
	return 0
}

# --- waiver validation (production) ------------------------------------------
# sp_validate_waivers <path> <policy> [today] — fail-closed STRUCTURAL validation of the
# accepted-risks file for the PRODUCTION path. Enforces the policy waiver requirements
# that JSON Schema cannot: mandatory owner, mandatory approver (review+approval),
# mandatory issue reference, mandatory finding scope (no blanket scanner/package
# suppression), real created_at/expires_at dates, and max waiver lifetime. Emergency
# records additionally require an incident reference. Expiry is checked at APPLY time
# (sp_waiver_matches), not here. Returns:
#   0 valid (or file absent/empty — no waivers is valid)
#   2 malformed file / record violating a mandatory waiver requirement (fail closed)
sp_validate_waivers() {
	_wvf="${1:-}"; _wvpol="${2:-}"
	[ -n "$_wvf" ] && [ -f "$_wvf" ] && [ -s "$_wvf" ] || return 0
	command_exists jq || { log_error "sp_validate_waivers: jq is required"; return 2; }
	jq -e . "$_wvf" >/dev/null 2>&1 || { log_error "sp_validate_waivers: invalid JSON: $_wvf"; return 2; }
	jq -e 'type == "object" and has("risks") and (.risks | type == "array")' "$_wvf" >/dev/null 2>&1 \
		|| { log_error "sp_validate_waivers: must be an object with a 'risks' array: $_wvf"; return 2; }

	_wvmax=$(jq -r '.waivers.max_lifetime_days' "$_wvpol" 2>/dev/null)
	_wvemax=$(jq -r '.emergency_release.max_lifetime_days' "$_wvpol" 2>/dev/null)
	_wvprohibited=$(jq -r '(.waivers.prohibited_scopes // []) | join(" ")' "$_wvpol" 2>/dev/null)
	case "$_wvmax" in ''|*[!0-9]*) log_error "sp_validate_waivers: policy max_lifetime_days invalid"; return 2 ;; esac
	case "$_wvemax" in ''|*[!0-9]*) log_error "sp_validate_waivers: policy emergency max_lifetime_days invalid"; return 2 ;; esac

	# Field-completeness + scope checks (structural). Emitted as a tab-delimited stream so a
	# per-record failure flips _rc in THIS shell (a here-doc, not a pipe subshell).
	_wvbad=$(jq -r '
		.risks | to_entries[]
		| .key as $i | .value as $w
		| [ "id","owner","approved_by","issue","scanner","category","finding_id","reason","created_at","expires_at","status" ] as $req
		| ( [ $req[] | select((($w[.]?) // "") | (type != "string") or (length == 0)) ] ) as $missing
		| ($w.scope // "finding") as $scope
		| ($w.emergency // false) as $emg
		| if ($w | type != "object") then "record \($i): not an object"
		  elif (($missing | length) > 0) then "record \($i): missing/empty \($missing | join(","))"
		  elif ($w.owner == $w.approved_by) then "record \($i): owner == approved_by (self-approval prohibited)"
		  elif ($scope != "finding") then "record \($i): scope \"\($scope)\" is blanket suppression (only finding scope allowed)"
		  elif ($emg == true and (($w.incident // "") | (type != "string") or (length == 0))) then "record \($i): emergency record missing incident reference"
		  else empty end
	' "$_wvf" 2>/dev/null) || {
		# Fail closed: a jq evaluation crash must not be read as "no structural problems".
		log_error "sp_validate_waivers: structural validation could not be evaluated (jq error): $_wvf"
		return 2
	}
	if [ -n "$_wvbad" ]; then
		printf '%s\n' "$_wvbad" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "sp_validate_waivers: $_l"; done
		return 2
	fi

	# Prohibited-scope keyword guard (belt-and-braces against future scope tokens).
	if [ -n "$_wvprohibited" ]; then
		for _ps in $_wvprohibited; do
			if jq -e --arg s "$_ps" 'any(.risks[]; (.scope // "finding") == $s)' "$_wvf" >/dev/null 2>&1; then
				log_error "sp_validate_waivers: prohibited blanket scope '$_ps' present (blanket package/scanner suppression is not allowed)"
				return 2
			fi
		done
	fi

	# Date validity + max-lifetime, per record (finite loop over a here-doc).
	_wvrecs=$(jq -r '.risks[] | "\(.id)\t\(.created_at)\t\(.expires_at)\t\(.emergency // false)"' "$_wvf" 2>/dev/null) || {
		# Fail closed: an unparseable date stream from a jq crash must not skip lifetime checks.
		log_error "sp_validate_waivers: date extraction could not be evaluated (jq error): $_wvf"
		return 2
	}
	_wvrc=0
	_wvtab="$(printf '\t')"
	while IFS="$_wvtab" read -r _wid _wcre _wexp _wemg; do
		[ -n "$_wid" ] || continue
		if ! sp_valid_date "$_wcre"; then log_error "sp_validate_waivers: invalid created_at '$_wcre' (id $_wid)"; _wvrc=2; continue; fi
		if ! sp_valid_date "$_wexp"; then log_error "sp_validate_waivers: invalid expires_at '$_wexp' (id $_wid)"; _wvrc=2; continue; fi
		_wlife=$(sp_lifetime_days "$_wcre" "$_wexp") || { log_error "sp_validate_waivers: cannot compute lifetime (id $_wid)"; _wvrc=2; continue; }
		if [ "$_wlife" -lt 0 ]; then log_error "sp_validate_waivers: created_at after expires_at (id $_wid)"; _wvrc=2; continue; fi
		if [ "$_wemg" = "true" ]; then _wcap=$_wvemax; else _wcap=$_wvmax; fi
		if [ "$_wlife" -gt "$_wcap" ]; then
			log_error "sp_validate_waivers: waiver lifetime ${_wlife}d exceeds max ${_wcap}d (id $_wid)"; _wvrc=2
		fi
	done <<EOF
$_wvrecs
EOF
	return "$_wvrc"
}
