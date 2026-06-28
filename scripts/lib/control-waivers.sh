#!/bin/sh
# Sentinel Shield — shared control-waiver validation (v2).
#
# THE single validator for control-waiver files (schemas/control-waiver.schema.json).
# Every waiver consumer (effective-profile resolver, bootstrap-profile-tools.sh,
# doctor.sh, build-security-summary.sh, enforce-gates.sh, maturity-report.sh,
# plan-upgrade.sh) MUST go through here — no consumer parses waivers itself
# (Part A4 / C1). A control-waiver lets a REQUIRED tool be temporarily ABSENT;
# it never suppresses findings produced by a tool that did run (Part C3).
#
# Source this file; it defines functions only. jq required.
#
# A waiver is VALID only when ALL hold:
#   - the file is valid JSON shaped { version, waivers:[...] }
#   - every record has non-empty tool/justification/owner/approved_by/
#     created_at/expires_at/tracking_issue (schema parity)
#   - created_at and expires_at are REAL calendar dates (YYYY-MM-DD, UTC)
#   - owner != approved_by   (no self-approval — Part B1)
# A valid record additionally APPLIES (downgrades a control) only while it is
# UNEXPIRED: expires_at >= today (UTC); a waiver expiring today is valid through
# the end of that UTC day. Expiry is checked at apply time, not validation time.
#
# Malformed file / record => cw_validate_file returns 2 (callers fail closed).
set -eu

if [ "${__SENTINEL_SHIELD_CONTROL_WAIVERS_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_CONTROL_WAIVERS_LOADED=1

if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_cw_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_cw_d/sentinel-shield-common.sh" ]; then . "$_cw_d/sentinel-shield-common.sh"
	elif [ -f "$_cw_d/lib/sentinel-shield-common.sh" ]; then . "$_cw_d/lib/sentinel-shield-common.sh"
	else printf '%s\n' "[sentinel-shield][error] control-waivers: cannot locate sentinel-shield-common.sh" >&2; exit 2
	fi
fi

# cw_today_utc — current date as YYYY-MM-DD in UTC.
cw_today_utc() { date -u +%Y-%m-%d; }

# cw__valid_date <YYYY-MM-DD> — 0 if it is a REAL calendar date (pure shell, no
# date(1) parsing — portable + deterministic). Rejects 2026-99-99, 2026-02-31, etc.
cw__valid_date() {
	_d="${1:-}"
	# strict shape first
	case "$_d" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	_y=${_d%%-*}; _rest=${_d#*-}; _m=${_rest%%-*}; _day=${_rest#*-}
	# strip leading zeros for arithmetic (base-10), guard empty
	_yn=$((10#$_y)); _mn=$((10#$_m)); _dn=$((10#$_day))
	[ "$_mn" -ge 1 ] && [ "$_mn" -le 12 ] || return 1
	[ "$_dn" -ge 1 ] || return 1
	case "$_mn" in
		1|3|5|7|8|10|12) _max=31 ;;
		4|6|9|11) _max=30 ;;
		2)
			# leap year: divisible by 4 and (not by 100 or by 400)
			if { [ $((_yn % 4)) -eq 0 ] && [ $((_yn % 100)) -ne 0 ]; } || [ $((_yn % 400)) -eq 0 ]; then
				_max=29
			else
				_max=28
			fi ;;
		*) return 1 ;;
	esac
	[ "$_dn" -le "$_max" ] || return 1
	return 0
}

# cw_validate_file <file> — full structural validation (NOT expiry). Returns:
#   0 valid (or file absent/empty — no waivers is valid)
#   2 malformed JSON / shape / missing field / bad date / self-approval
cw_validate_file() {
	_f="${1:-}"
	[ -n "$_f" ] && [ -f "$_f" ] && [ -s "$_f" ] || return 0   # absent = no waivers
	command_exists jq || { log_error "control-waivers: jq is required."; return 2; }
	jq -e . "$_f" >/dev/null 2>&1 || { log_error "control-waivers: not valid JSON: $_f"; return 2; }
	# top-level shape
	jq -e 'type=="object" and has("waivers") and (.waivers|type=="array")' "$_f" >/dev/null 2>&1 \
		|| { log_error "control-waivers: must be an object with a 'waivers' array: $_f"; return 2; }
	# every record: required non-empty fields + self-approval check (cross-field —
	# JSON Schema can't express owner!=approved_by, so enforce it here, Part B1).
	_bad=$(jq -r '
		.waivers | to_entries[]
		| .key as $i | .value as $w
		| [ "tool","justification","owner","approved_by","created_at","expires_at","tracking_issue" ]
		  as $req
		| ( [ $req[] | select((($w[.]?) // "") | (type!="string") or (length==0)) ] ) as $missing
		| if ($missing|length) > 0 then "record \($i): missing/empty \($missing|join(","))"
		  elif ($w.owner == $w.approved_by) then "record \($i): owner == approved_by (self-approval) for tool \($w.tool)"
		  else empty end' "$_f" 2>/dev/null || true)
	if [ -n "$_bad" ]; then
		printf '%s\n' "$_bad" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "control-waivers: $_l"; done
		return 2
	fi
	# date reality (created_at + expires_at) — pure-shell calendar check.
	_dates=$(jq -r '.waivers[] | "\(.tool)\t\(.created_at)\t\(.expires_at)"' "$_f" 2>/dev/null || true)
	_rc=0
	# read in a here-doc (not a pipe) so a failure flips _rc in this shell.
	while IFS="$(printf '\t')" read -r _tool _cre _exp; do
		[ -n "$_tool" ] || continue
		cw__valid_date "$_cre" || { log_error "control-waivers: invalid created_at '$_cre' for tool '$_tool'"; _rc=2; }
		cw__valid_date "$_exp" || { log_error "control-waivers: invalid expires_at '$_exp' for tool '$_tool'"; _rc=2; }
	done <<EOF
$_dates
EOF
	return "$_rc"
}

# cw_valid_keys <file> [today] — print newline-delimited tool keys whose waiver is
# VALID and UNEXPIRED. Validates first; on malformed file returns 2 (no output).
cw_valid_keys() {
	_f="${1:-}"; _today="${2:-$(cw_today_utc)}"
	cw_validate_file "$_f" || return 2
	[ -n "$_f" ] && [ -f "$_f" ] && [ -s "$_f" ] || return 0
	jq -r --arg today "$_today" '
		.waivers[] | select(.expires_at >= $today) | .tool' "$_f" 2>/dev/null || true
}

# cw_is_waived <file> <tool> [today] — 0 if <tool> has a valid, unexpired waiver.
# Fails closed: a malformed file makes this return non-zero (tool NOT waived) AND
# the caller should have already run cw_validate_file to hard-fail.
cw_is_waived() {
	_wf="${1:-}"; _t="${2:?cw_is_waived: tool required}"; _td="${3:-$(cw_today_utc)}"
	_keys=$(cw_valid_keys "$_wf" "$_td") || return 1
	case "
$_keys
" in *"
$_t
"*) return 0 ;; *) return 1 ;; esac
}
