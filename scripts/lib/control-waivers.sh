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
# A waiver file is VALID only when ALL hold:
#   - the file is valid JSON shaped { version: "2", waivers:[...] }
#   - every record has non-empty id/tool/justification/owner/approved_by/
#     created_at/expires_at/tracking_issue (schema parity), free of control
#     characters
#   - `id` matches CW_ID_RE and is UNIQUE across the file (#225): a waiver is an
#     approval record, and an approval you cannot name is one you cannot audit,
#     revoke or supersede
#   - created_at and expires_at are REAL calendar dates (YYYY-MM-DD, UTC), with
#     created_at <= expires_at
#   - created_at is not in the future beyond CW_MAX_CLOCK_SKEW_DAYS, and the
#     validity window is at most CW_MAX_WAIVER_DAYS long (#226): "has an expiry
#     date" does not make a waiver temporary if the date is 2099
#   - owner != approved_by   (no self-approval — Part B1)
#   - supersession is explicit and acyclic: `supersedes` names an EXISTING record
#     for the SAME tool with a STRICTLY EARLIER created_at, no record is
#     superseded twice, and no two records that nothing supersedes have
#     OVERLAPPING validity windows for one tool (#225)
#
# A valid record additionally APPLIES (downgrades a control) only while it is
# EFFECTIVE and not superseded: created_at <= today <= expires_at (UTC); a waiver
# expiring today is valid through the end of that UTC day, and a waiver created
# tomorrow does not apply today. Effectiveness is checked at apply time, not
# validation time.
#
# Malformed file / record => cw_validate_file returns 2 (callers fail closed).
# No top-level `set -eu`: this file is sourced and defines functions only; it must not
# mutate the sourcing shell's options. Every caller sets its own `set -eu`.

if [ "${__SENTINEL_SHIELD_CONTROL_WAIVERS_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_CONTROL_WAIVERS_LOADED=1

if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_cw_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	# $0-based locations work when this lib is EXECUTED or sourced by a scripts/ wrapper;
	# the PWD-relative fallbacks let it be sourced standalone from the repo root, e.g.
	#   sh -c '. scripts/lib/control-waivers.sh; cw_validate_file "$1"' sh <file>
	for _cw_c in "$_cw_d/sentinel-shield-common.sh" "$_cw_d/lib/sentinel-shield-common.sh" \
		"scripts/lib/sentinel-shield-common.sh" "./sentinel-shield-common.sh"; do
		# shellcheck source=scripts/lib/sentinel-shield-common.sh
		[ -f "$_cw_c" ] && { . "$_cw_c"; break; }
	done
	if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
		printf '%s\n' "[sentinel-shield][error] control-waivers: cannot locate sentinel-shield-common.sh" >&2; exit 2
	fi
fi

# Supported control-waiver schema version (fail closed on anything else — Issue 2).
# "2" adds the REQUIRED unique `id` and the optional `supersedes` relation (#225);
# a "1" file is refused with a migration message rather than silently accepted
# without the identity every applied output now reports.
CW_SCHEMA_VERSION="2"
# Safe waiver tool-key grammar — a single shell-safe token (Issue 3). No whitespace,
# tabs, newlines, slashes, path traversal, shell metacharacters or empty value, so a
# value can never split into multiple waived controls.
CW_TOOLKEY_RE='^[A-Za-z0-9_.-]+$'
# Waiver ID grammar — a stable, quotable, greppable token (3..64 chars). Same shape as
# the tool key so an ID is safe in a report, a log line and a shell word.
CW_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$'

# --- time policy (#226) -------------------------------------------------------
# CW_MAX_WAIVER_DAYS  — maximum expires_at - created_at, in days. A control-waiver is a
#   time-boxed exception; without a ceiling a single record disables a required control
#   for a decade. Callers may TIGHTEN it (enforce-gates.sh applies the regulated ceiling
#   in regulated mode). CW_MAX_WAIVER_DAYS_CEILING is the hard limit no caller or
#   environment can exceed, so a loosened environment cannot manufacture a permanent
#   waiver.
# The POLICY maximum. The environment may lower it (enforce-gates.sh applies the regulated
# value); it can never raise it, and an unusable value falls back here rather than to the
# most permissive number in the file.
CW_MAX_WAIVER_DAYS_DEFAULT=90
CW_MAX_WAIVER_DAYS_CEILING=365   # absolute upper bound, retained for reporting
CW_MAX_WAIVER_DAYS_REGULATED=30
# NO `: "${CW_MAX_WAIVER_DAYS:=…}"` HERE. `:=` substitutes for an UNSET *and* a SET-BUT-EMPTY
# value alike, so it destroyed the very distinction cw__max_days exists to police: an operator
# who wrote `CW_MAX_WAIVER_DAYS=` had it silently rewritten to the default before validation
# could refuse it, and the function comments and tests asserted a contract the library could
# not honour. cw__max_days is the ONLY resolver: unset gets the documented default, set-empty
# fails closed.
# CW_MAX_CLOCK_SKEW_DAYS — how far ahead of the trusted UTC date created_at may sit.
# Runners disagree about the date across a UTC midnight; a record dated next month is
# not skew, it is a pre-positioned approval.
# Same reasoning: cw__skew_days is the only resolver, so unset and set-empty stay
# distinguishable all the way to validation.
CW_MAX_CLOCK_SKEW_DAYS_DEFAULT=1

# cw_decimal <numeric-string> — strip leading zeros WITHOUT Bash base syntax
# ($((10#08)) is not POSIX and dash errors on 08/09). Returns the base-10 value as a
# plain decimal string ("0" for all-zeros/empty). Only call AFTER format validation.
cw_decimal() {
	_v=${1:-0}
	while [ "${_v#0}" != "$_v" ]; do _v=${_v#0}; done
	[ -n "$_v" ] || _v=0
	printf '%s' "$_v"
}

# cw__valid_date <YYYY-MM-DD> — 0 if it is a REAL calendar date (pure shell, no
# date(1) parsing — portable + deterministic). Rejects 2026-99-99, 2026-02-31,
# 0000-01-01, etc. POSIX /bin/sh safe (no $((10#..)) — Issue 1 / SC3052).
cw__valid_date() {
	_d="${1:-}"
	# strict shape first — guarantees the fields are 4/2/2 digits before arithmetic.
	case "$_d" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	_y=${_d%%-*}; _rest=${_d#*-}; _m=${_rest%%-*}; _day=${_rest#*-}
	# POSIX-safe base-10 normalization (no leading-zero octal/base pitfalls).
	_yn=$(cw_decimal "$_y"); _mn=$(cw_decimal "$_m"); _dn=$(cw_decimal "$_day")
	[ "$_yn" -ge 1 ] || return 1            # reject year 0000
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

# cw__days <YYYY-MM-DD> — days since 1970-01-01 (days-from-civil; exact, no date(1),
# leap years and centuries included). Only call on a date cw__valid_date accepted.
cw__days() {
	_dy=${1%%-*}; _dr=${1#*-}
	_y=$(cw_decimal "$_dy"); _m=$(cw_decimal "${_dr%%-*}"); _d=$(cw_decimal "${_dr#*-}")
	[ "$_m" -le 2 ] && _y=$((_y - 1))
	# cw__valid_date rejects year 0000, so _y >= 0 here and the negative-era branch of
	# the civil algorithm is unreachable (no POSIX-portable ternary needed).
	_era=$((_y / 400))
	_yoe=$((_y - _era * 400))
	_mp=$(((_m + 9) % 12))
	_doy=$(((153 * _mp + 2) / 5 + _d - 1))
	_doe=$((_yoe * 365 + _yoe / 4 - _yoe / 100 + _doy))
	printf '%s' $((_era * 146097 + _doe - 719468))
}

# cw_today_utc — current date as YYYY-MM-DD in UTC. FAIL CLOSED (rc 2, no output) when
# date(1) is unavailable or prints something that is not a real calendar date: an
# unreadable clock must never resolve to "no expiry check ran".
cw_today_utc() {
	_t=$(date -u +%Y-%m-%d 2>/dev/null || true)
	if ! cw__valid_date "$_t"; then
		log_error "control-waivers: no trusted UTC date available (date -u produced '$_t') — fail closed"
		return 2
	fi
	printf '%s' "$_t"
}

# cw__resolve_today <candidate> — echo a validated today; rc 2 if it cannot be trusted.
# Callers take `today` as an optional argument, and `${1:-$(cw_today_utc)}` swallows the
# clock failure's exit status — so the resolved value is re-validated here rather than
# allowed through as an empty string that compares "unexpired" against everything.
cw__resolve_today() {
	_td="${1:-}"
	[ -n "$_td" ] || _td=$(cw_today_utc) || return 2
	cw__valid_date "$_td" || { log_error "control-waivers: '$_td' is not a valid UTC date"; return 2; }
	printf '%s' "$_td"
}

# cw__max_days — the effective maximum waiver duration, clamped to the hard ceiling so a
# loosened environment cannot manufacture a permanent waiver. Non-numeric => ceiling.
cw__max_days() {
	# An INVALID setting FAILS CLOSED. It is not clamped, normalised, or replaced by a
	# fallback: a governance duration nobody can read is a configuration error, and quietly
	# substituting ANY number — the ceiling or the default — means the operator believes one
	# policy is in force while another is. Only an ABSENT setting uses the documented default.
	#
	# Returns 2 and prints nothing when the value is unusable; callers must treat that as fatal.
	# UNSET uses the documented default. Explicitly EMPTY does not: someone wrote
	# `CW_MAX_WAIVER_DAYS=` meaning something, and guessing which policy they meant is exactly
	# what this function refuses to do.
	if [ "${CW_MAX_WAIVER_DAYS+set}" != "set" ]; then
		printf '%s' "$CW_MAX_WAIVER_DAYS_DEFAULT"; return 0
	fi
	if [ -z "$CW_MAX_WAIVER_DAYS" ]; then
		log_error "control-waivers: CW_MAX_WAIVER_DAYS is set but empty. Unset it to use the ${CW_MAX_WAIVER_DAYS_DEFAULT}-day default, or give it a value — an empty policy is not a policy."
		return 2
	fi
	# An absurdly long digit string overflows shell arithmetic, and a silently wrapped
	# comparison would let it through as "in range". Bound the LENGTH before comparing.
	if [ "${#CW_MAX_WAIVER_DAYS}" -gt 9 ]; then
		log_error "control-waivers: CW_MAX_WAIVER_DAYS='$CW_MAX_WAIVER_DAYS' is out of range (the ceiling is ${CW_MAX_WAIVER_DAYS_CEILING} days)."
		return 2
	fi
	case "$CW_MAX_WAIVER_DAYS" in
		*[!0-9]*)
			log_error "control-waivers: CW_MAX_WAIVER_DAYS='$CW_MAX_WAIVER_DAYS' is not a whole number of days. A governance duration that cannot be read is a configuration error — it is never clamped or defaulted, because that would enforce a policy nobody chose. Set a positive integer no greater than ${CW_MAX_WAIVER_DAYS_DEFAULT}, or unset it to use the ${CW_MAX_WAIVER_DAYS_DEFAULT}-day default."
			return 2 ;;
	esac
	# Canonicalise leading zeros with the engine-wide helper, so `00090` and `90` are the same
	# policy and the value reported downstream is the canonical one.
	CW_MAX_WAIVER_DAYS=$(cw_decimal "$CW_MAX_WAIVER_DAYS")
	if [ "$CW_MAX_WAIVER_DAYS" -lt 1 ] 2>/dev/null; then
		log_error "control-waivers: CW_MAX_WAIVER_DAYS=$CW_MAX_WAIVER_DAYS is not a usable duration (must be >= 1). Refusing to guess a policy."
		return 2
	fi
	if [ "$CW_MAX_WAIVER_DAYS" -gt "$CW_MAX_WAIVER_DAYS_CEILING" ] 2>/dev/null; then
		log_error "control-waivers: CW_MAX_WAIVER_DAYS=$CW_MAX_WAIVER_DAYS exceeds the absolute ${CW_MAX_WAIVER_DAYS_CEILING}-day ceiling. Configuration may TIGHTEN the policy, never loosen it — refusing to run under an out-of-policy duration."
		return 2
	fi
	if [ "$CW_MAX_WAIVER_DAYS" -gt "$CW_MAX_WAIVER_DAYS_DEFAULT" ]; then
		log_error "control-waivers: CW_MAX_WAIVER_DAYS=$CW_MAX_WAIVER_DAYS exceeds the ${CW_MAX_WAIVER_DAYS_DEFAULT}-day policy maximum. Configuration may TIGHTEN the policy, never loosen it."
		return 2
	fi
	printf '%s' "$CW_MAX_WAIVER_DAYS"
}

# cw__skew_days — the effective future-clock tolerance, resolved with the SAME fail-closed
# contract as cw__max_days. Mapping an invalid value to 0 recreated exactly the ambiguity that
# was fixed for the waiver window: the operator configured one tolerance and the engine
# enforced another, silently. Absent uses the documented default; anything else that is not a
# usable whole number of days is a configuration error (return 2).
CW_MAX_CLOCK_SKEW_DAYS_CEILING=365
cw__skew_days() {
	if [ "${CW_MAX_CLOCK_SKEW_DAYS+set}" != "set" ]; then
		printf '%s' "$CW_MAX_CLOCK_SKEW_DAYS_DEFAULT"; return 0
	fi
	if [ -z "$CW_MAX_CLOCK_SKEW_DAYS" ]; then
		log_error "control-waivers: CW_MAX_CLOCK_SKEW_DAYS is set but empty. Unset it to use the documented default of $CW_MAX_CLOCK_SKEW_DAYS_DEFAULT day(s); an empty policy value is not a policy."
		return 2
	fi
	if [ "${#CW_MAX_CLOCK_SKEW_DAYS}" -gt 9 ]; then
		log_error "control-waivers: CW_MAX_CLOCK_SKEW_DAYS='$CW_MAX_CLOCK_SKEW_DAYS' is out of range."
		return 2
	fi
	case "$CW_MAX_CLOCK_SKEW_DAYS" in
		*[!0-9]*)
			log_error "control-waivers: CW_MAX_CLOCK_SKEW_DAYS='$CW_MAX_CLOCK_SKEW_DAYS' is not a whole number of days. Refusing to guess a tolerance."
			return 2 ;;
	esac
	_cw_skew=$(cw_decimal "$CW_MAX_CLOCK_SKEW_DAYS")
	if [ "$_cw_skew" -gt "$CW_MAX_CLOCK_SKEW_DAYS_CEILING" ] 2>/dev/null; then
		log_error "control-waivers: CW_MAX_CLOCK_SKEW_DAYS=$_cw_skew exceeds the $CW_MAX_CLOCK_SKEW_DAYS_CEILING-day ceiling. A tolerance that large is not clock skew."
		return 2
	fi
	printf '%s' "$_cw_skew"
}

# cw__records <file> — tab-delimited record projection, one line per waiver:
#   id \t tool \t created_at \t expires_at \t supersedes-or-"-" \t owner \t approved_by
# Free-text fields that could contain a tab are excluded (validation rejects control
# characters anyway, so the projection cannot be split by hostile input).
cw__records() {
	jq -r '.waivers[] | [ (.id // ""), (.tool // ""), (.created_at // ""), (.expires_at // ""),
		(if ((.supersedes // "") | length) > 0 then .supersedes else "-" end),
		(.owner // ""), (.approved_by // "") ] | @tsv' "$1" 2>/dev/null || true
}

# cw_validate_file <file> [known-keys-space-list] [today] — full structural validation
# (NOT effectiveness). With an optional space-separated list of effective tool/one-of
# keys, also rejects waivers for tools the active profile does not declare. `today`
# overrides the trusted UTC date for the creation-time policy (tests/replay); it is
# validated like any other date. Returns:
#   0 valid (or file absent/empty — no waivers is valid)
#   2 malformed JSON / shape / bad version / missing field / duplicate or unsafe id /
#     unsafe-or-unknown tool key / bad date / created_at>expires_at / future creation /
#     over-long validity window / self-approval / broken or ambiguous supersession /
#     overlapping active windows for one tool
cw_validate_file() {
	_f="${1:-}"; _known="${2:-}"; _vt="${3:-}"
	[ -n "$_f" ] && [ -f "$_f" ] && [ -s "$_f" ] || return 0   # absent = no waivers
	command_exists jq || { log_error "control-waivers: jq is required."; return 2; }
	jq -e . "$_f" >/dev/null 2>&1 || { log_error "control-waivers: not valid JSON: $_f"; return 2; }
	_vt=$(cw__resolve_today "$_vt") || return 2
	# top-level shape + REQUIRED version == "2" (string). Unknown/empty/numeric fail closed.
	jq -e 'type=="object" and has("waivers") and (.waivers|type=="array")' "$_f" >/dev/null 2>&1 \
		|| { log_error "control-waivers: must be an object with a 'waivers' array: $_f"; return 2; }
	if ! jq -e --arg v "$CW_SCHEMA_VERSION" '(.version|type=="string") and (.version==$v)' "$_f" >/dev/null 2>&1; then
		_gotv=$(jq -c '.version // "<missing>"' "$_f" 2>/dev/null)
		log_error "control-waivers: top-level 'version' must be the string \"$CW_SCHEMA_VERSION\" (got $_gotv): $_f"
		if [ "$_gotv" = '"1"' ]; then
			log_error "control-waivers: migrate a v1 file by giving every record a unique 'id' (${CW_ID_RE}) and setting version to \"$CW_SCHEMA_VERSION\"; a waiver without an identity cannot be reported, superseded or revoked."
		fi
		return 2
	fi
	# CLOSED OBJECTS, enforced at RUNTIME. The schema declares additionalProperties:false at
	# both levels, but a schema nobody applies is documentation: an unknown key was silently
	# ignored, so a typo in a narrowing or audit field (`aproved_by`, `expires`, `tracking`)
	# left the record meaning something other than what its author wrote — and the missing
	# real field was then reported as missing, or defaulted. Reject unknown keys here so the
	# runtime and the schema agree.
	_unknown=$(jq -r '
		def topok: ["version","waivers"];
		def recok: ["id","tool","justification","owner","approved_by","created_at",
			"expires_at","tracking_issue","supersedes"];
		( [ keys[] | select(. as $k | topok | index($k) | not)
			| "top-level: unknown field \"\(.)\"" ] )
		+ ( [ .waivers[]? | select(type == "object") | . as $w | ($w.id? // "?") as $rid
			| ($w | keys[]) | select(. as $k | recok | index($k) | not)
			| "waiver \($rid): unknown field \"\(.)\" — v2 records are closed; a mistyped field is not an ignorable one" ] )
		| .[]' "$_f" 2>/dev/null || true)
	if [ -n "$_unknown" ]; then
		printf '%s\n' "$_unknown" | while IFS= read -r _u; do
			[ -n "$_u" ] && log_error "control-waivers: $_u"
		done
		log_error "control-waivers: refusing $_f — the schema closes both objects and the runtime now enforces that."
		return 2
	fi
	# every record: required non-empty string fields, control-character-free values,
	# id/supersedes identity rules and the self-approval check (cross-field — JSON Schema
	# cannot express owner!=approved_by or a supersession relation, so enforce them here).
	_bad=$(jq -r --arg idre "$CW_ID_RE" '
		def ids: [ .waivers[]? | (.id? // "") ];
		def superseded_by($id): [ .waivers[]? | select((.supersedes? // "") == $id) ];
		. as $doc
		| ids as $ids
		| .waivers | to_entries[]
		| .key as $i | .value as $w
		| ( [ "id","tool","justification","owner","approved_by","created_at","expires_at","tracking_issue" ] ) as $req
		| ( [ $req[] | select((($w[.]?) // "") | (type!="string") or (length==0)) ] ) as $missing
		| ( [ $req[] | select((($w[.]?) // "") | (type=="string") and (explode | any(. < 32))) ] ) as $ctrl
		| if ($w|type != "object") then "record \($i): not an object"
		  elif ($missing|length) > 0 then "record \($i): missing/empty \($missing|join(","))"
		  elif ($ctrl|length) > 0 then "record \($i): control characters in \($ctrl|join(","))"
		  elif ($w.id | test($idre) | not) then "record \($i): id \($w.id|tojson) does not match \($idre)"
		  elif ([ $ids[] | select(. == $w.id) ] | length) > 1 then "record \($i): duplicate waiver id \($w.id|tojson) — an approval must have exactly one identity"
		  elif ($w.owner == $w.approved_by) then "waiver \($w.id): owner == approved_by (self-approval) for tool \($w.tool)"
		  elif (($w.supersedes? // "") | type != "string") then "waiver \($w.id): supersedes must be a string"
		  elif (($w.supersedes? // "") | length) > 0 and ($w.supersedes == $w.id) then "waiver \($w.id): supersedes itself"
		  elif (($w.supersedes? // "") | length) > 0 and ([ $ids[] | select(. == $w.supersedes) ] | length) == 0
		    then "waiver \($w.id): supersedes unknown waiver id \($w.supersedes|tojson)"
		  elif (($w.supersedes? // "") | length) > 0
		    and ([ $doc.waivers[] | select(.id == $w.supersedes) | .tool ] | first) != $w.tool
		    then "waiver \($w.id): supersedes \($w.supersedes|tojson), which waives a DIFFERENT tool"
		  elif (($doc | superseded_by($w.id)) | length) > 1
		    then "waiver \($w.id): superseded by more than one record — supersession must be unambiguous"
		  else empty end' "$_f" 2>/dev/null || true)
	if [ -n "$_bad" ]; then
		printf '%s\n' "$_bad" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "control-waivers: $_l"; done
		return 2
	fi
	# per-record: safe tool-key grammar, optional known-key membership, real calendar
	# dates, ordering, and the time-bound policy. Tab-delimited read in a here-doc (not a
	# pipe) so a failure flips _rc in THIS shell.
	_recs=$(cw__records "$_f")
	_rc=0
	_ktab="$(printf '\t')"
	# cw__max_days FAILS CLOSED on an unusable setting; a command substitution swallows its
	# exit status, so it is captured explicitly and the failure is propagated.
	_maxd=$(cw__max_days) || return 2
	[ -n "$_maxd" ] || return 2
	# Same contract as cw__max_days: the substitution swallows the exit status, so an
	# unusable skew setting is captured and propagated instead of silently becoming a
	# tolerance nobody configured.
	_skew=$(cw__skew_days) || return 2
	[ -n "$_skew" ] || return 2
	_todayn=$(cw__days "$_vt")
	# ACTIVE = every record nothing else supersedes; only those can conflict (below).
	_active=""
	_supd=$(printf '%s\n' "$_recs" | awk -F"$_ktab" '$5 != "-" && $5 != "" { print $5 }')
	while IFS="$_ktab" read -r _id _tool _cre _exp _sup _owner _appr; do
		[ -n "$_tool" ] || continue
		case "$_tool" in
			*[!A-Za-z0-9_.-]*|*..*|"") log_error "control-waivers: waiver $_id: unsafe tool key '$_tool' (must match $CW_TOOLKEY_RE, no whitespace/slash/metachar/traversal)"; _rc=2; continue ;;
		esac
		if [ -n "$_known" ]; then
			case " $_known " in *" $_tool "*) : ;; *) log_error "control-waivers: waiver $_id: targets unknown tool '$_tool' (not declared by the active profile)"; _rc=2; continue ;; esac
		fi
		if ! cw__valid_date "$_cre"; then
			log_error "control-waivers: waiver $_id: invalid created_at '$_cre' for tool '$_tool'"; _rc=2; continue
		fi
		if ! cw__valid_date "$_exp"; then
			log_error "control-waivers: waiver $_id: invalid expires_at '$_exp' for tool '$_tool'"; _rc=2; continue
		fi
		_cn=$(cw__days "$_cre"); _en=$(cw__days "$_exp")
		if [ "$_cn" -gt "$_en" ]; then
			log_error "control-waivers: waiver $_id: created_at '$_cre' is after expires_at '$_exp' for tool '$_tool'"; _rc=2; continue
		fi
		if [ "$_cn" -gt $((_todayn + _skew)) ]; then
			log_error "control-waivers: waiver $_id: created_at '$_cre' is in the future (today is $_vt UTC, clock-skew tolerance ${_skew}d) — a waiver cannot be pre-positioned"; _rc=2
		fi
		if [ $((_en - _cn)) -gt "$_maxd" ]; then
			log_error "control-waivers: waiver $_id: validity window $_cre..$_exp is $((_en - _cn)) days, over the ${_maxd}-day maximum — renew with a new, superseding record instead of a longer one"; _rc=2
		fi
		# a superseding record must be NEWER than what it replaces; strict ordering also
		# makes a supersession cycle unrepresentable.
		if [ "$_sup" != "-" ]; then
			_scre=$(printf '%s\n' "$_recs" | awk -F"$_ktab" -v id="$_sup" '$1 == id { print $3; exit }')
			if cw__valid_date "$_scre" && [ "$(cw__days "$_scre")" -ge "$_cn" ]; then
				log_error "control-waivers: waiver $_id: supersedes '$_sup', created '$_scre', which is not strictly older than '$_cre' — a replacement must be newer than what it replaces"; _rc=2
			fi
		fi
		case "
$_supd
" in
			*"
$_id
"*) : ;;   # superseded: shadowed, cannot conflict
			*) _active="${_active}${_id}${_ktab}${_tool}${_ktab}${_cn}${_ktab}${_en}
" ;;
		esac
	done <<EOF
$_recs
EOF
	[ "$_rc" -eq 0 ] || return "$_rc"
	# Two records that nothing supersedes must not cover the same tool at the same time:
	# otherwise one tool key has two owners, two approvers and two remediation tickets,
	# and no output can say which approval waived the control.
	# ponytail: O(n^2) over waiver records — a governance file holds tens of records, not
	# thousands; index by tool if that ever stops being true.
	_conflict=$(printf '%s' "$_active" | awk -F"$_ktab" '
		{ id[NR] = $1; tool[NR] = $2; s[NR] = $3; e[NR] = $4; n = NR }
		END {
			for (i = 1; i <= n; i++)
				for (j = i + 1; j <= n; j++)
					if (tool[i] == tool[j] && s[i] <= e[j] && s[j] <= e[i])
						printf "%s and %s both waive %s over overlapping windows\n", id[i], id[j], tool[i]
		}')
	if [ -n "$_conflict" ]; then
		printf '%s\n' "$_conflict" | while IFS= read -r _l; do
			[ -n "$_l" ] && log_error "control-waivers: $_l — supersede one of them (\"supersedes\": \"<id>\") so exactly one approval is authoritative"
		done
		return 2
	fi
	return 0
}

# cw_applied_records <file> [today] — print the records that APPLY today, tab-delimited:
#   id \t tool \t owner \t approved_by \t created_at \t expires_at \t tracking_issue
# A record applies only when it is not superseded and today is inside its validity
# window. Validates first; on a malformed file returns 2 (no output).
cw_applied_records() {
	_af="${1:-}"; _at="${2:-}"
	_at=$(cw__resolve_today "$_at") || return 2
	cw_validate_file "$_af" "" "$_at" || return 2
	[ -n "$_af" ] && [ -f "$_af" ] && [ -s "$_af" ] || return 0
	jq -r --arg today "$_at" '
		[ .waivers[] | .supersedes? // empty ] as $superseded
		| .waivers[]
		| . as $w
		| select([ $superseded[] | select(. == $w.id) ] | length == 0)
		| select($w.created_at <= $today and $w.expires_at >= $today)
		| [ .id, .tool, .owner, .approved_by, .created_at, .expires_at, .tracking_issue ] | @tsv' \
		"$_af" 2>/dev/null || true
}

# cw_valid_keys <file> [today] — print newline-delimited tool keys whose waiver APPLIES.
# Validates first; on malformed file returns 2 (no output).
cw_valid_keys() {
	_kf="${1:-}"; _kt="${2:-}"
	_krecs=$(cw_applied_records "$_kf" "$_kt") || return 2
	[ -n "$_krecs" ] || return 0
	printf '%s\n' "$_krecs" | cut -f2
}

# cw_record_for <records-blob> <tool> — the applied record line for <tool>, if any.
# Takes the blob (not the file) so a consumer reads and validates the file once.
cw_record_for() {
	printf '%s\n' "${1:-}" | awk -F'\t' -v t="${2:-}" '$2 == t { print; exit }'
}

# cw_describe <records-blob> <tool> — one-line audit identity for the APPLIED waiver:
# which approval authorised this control being waived. Empty when the tool is not waived.
cw_describe() {
	cw_record_for "${1:-}" "${2:-}" | awk -F'\t' '{
		printf "waiver=%s owner=%s approved_by=%s created=%s expires=%s tracking=%s", $1, $3, $4, $5, $6, $7
	}'
}

# cw_is_waived <file> <tool> [today] — 0 if <tool> has a valid, applying waiver.
# Fails closed: a malformed file makes this return non-zero (tool NOT waived) AND
# the caller should have already run cw_validate_file to hard-fail.
cw_is_waived() {
	_wf="${1:-}"; _t="${2:?cw_is_waived: tool required}"; _td="${3:-}"
	_keys=$(cw_valid_keys "$_wf" "$_td") || return 1
	case "
$_keys
" in *"
$_t
"*) return 0 ;; *) return 1 ;; esac
}
