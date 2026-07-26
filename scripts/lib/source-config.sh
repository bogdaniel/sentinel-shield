#!/bin/sh
# Sentinel Shield — engine source configuration (repository + ref) for managed workflows.
#
# Source this file; do not execute it. POSIX sh: no arrays, no `local`, no `[[ ]]`.
#
# The managed workflow checks Sentinel Shield out with:
#
#   SENTINEL_SHIELD_REPOSITORY: <owner/name>
#   SENTINEL_SHIELD_REF:        <immutable tag or full commit SHA>
#
# Until those are real values the installed workflow CANNOT check the engine out, so a
# successful `install-baseline.sh --apply` used to leave CI guaranteed to fail on its first
# run (the template shipped `YOUR_ORG/sentinel-shield` and the quickstart told the adopter to
# edit it by hand).
#
# These two values are CONFIGURATION DATA, not arbitrary YAML/shell text: they are validated
# against a strict grammar and then rendered by an exact, anchored line replacement. Nothing
# a caller supplies can introduce a new YAML key, a workflow expression, or a shell
# substitution into the installed workflow.
[ -n "${SS_SOURCE_CONFIG_SH_INCLUDED:-}" ] && return 0
SS_SOURCE_CONFIG_SH_INCLUDED=1

# The placeholder shipped in the templates. An installed workflow still carrying it is not
# runnable, and doctor/preflight treat it as a configuration failure.
SC_PLACEHOLDER_REPOSITORY="YOUR_ORG/sentinel-shield"

# sc_normalize_repository <value> — echo the canonical `owner/name` for a repository given as
# `owner/name`, `https://host/owner/name[.git]`, `git@host:owner/name[.git]` or
# `ssh://git@host/owner/name[.git]`. Returns 1 (and prints nothing) when the value is not a
# repository identifier this installer will write into a workflow.
#
# GitHub Enterprise: `actions/checkout` resolves `owner/name` against the runner's own GitHub
# host, so a GHE URL is accepted and reduced to `owner/name` — the host is not written into
# the workflow, because writing it there would be meaningless to the action.
sc_normalize_repository() {
	_sc_in="${1:-}"
	[ -n "$_sc_in" ] || return 1
	# Reject anything that could escape the YAML scalar or reach a shell/expression context.
	case "$_sc_in" in
		*'$'* | *'`'* | *'{'* | *'}'* | *'"'* | *"'"* | *'\'* | *' '* | *"$(printf '\t')"* | *'#'* | *'&'* | *';'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *'!'* | *'*'* | *'?'* | *'['* | *']'*)
			return 1 ;;
	esac
	case "$_sc_in" in *..*) return 1 ;; esac
	# Strip a recognised transport prefix, then a trailing .git.
	_sc_v="$_sc_in"
	case "$_sc_v" in
		https://* | http://*) _sc_v="${_sc_v#*://}"; _sc_v="${_sc_v#*/}" ;;
		ssh://*) _sc_v="${_sc_v#ssh://}"; _sc_v="${_sc_v#*@}"; _sc_v="${_sc_v#*/}" ;;
		git@*:*) _sc_v="${_sc_v#*:}" ;;
		*@*) return 1 ;;
	esac
	_sc_v="${_sc_v%.git}"
	_sc_v="${_sc_v%/}"
	# Exactly owner/name, both non-empty, GitHub's identifier charset.
	printf '%s' "$_sc_v" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' || return 1
	# The shipped placeholder is never a valid configured value.
	[ "$_sc_v" = "$SC_PLACEHOLDER_REPOSITORY" ] && return 1
	case "$_sc_v" in YOUR_ORG/* | your_org/* | ORG/* | '<'*) return 1 ;; esac
	printf '%s' "$_sc_v"
}

# sc_ref_kind <value> — echo `commit` for a full 40-hex SHA, `tag` for a tag-shaped ref,
# `branch` for anything else that is still a syntactically valid ref name, or return 1 when
# the value is not a ref this installer will write.
#
# "Tag-shaped" is a NAMING heuristic and is treated as such: it never proves immutability by
# itself. Production callers require either a commit SHA or a ref that the release-status
# contract lists as an approved immutable release tag.
sc_ref_kind() {
	_sc_r="${1:-}"
	[ -n "$_sc_r" ] || return 1
	case "$_sc_r" in
		*'$'* | *'`'* | *'{'* | *'}'* | *'"'* | *"'"* | *'\'* | *' '* | *"$(printf '\t')"* | *'#'* | *'&'* | *';'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *'~'* | *'^'* | *':'* | *'?'* | *'*'* | *'['* | *']'*)
			return 1 ;;
	esac
	case "$_sc_r" in *..* | /* | */ | .*) return 1 ;; esac
	printf '%s' "$_sc_r" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
	if printf '%s' "$_sc_r" | grep -Eq '^[0-9a-fA-F]{40}$'; then printf 'commit'; return 0; fi
	if printf '%s' "$_sc_r" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then printf 'tag'; return 0; fi
	printf 'branch'
}

# sc_approved_ref <repo-root> — echo the ref the release-status contract says shipped
# templates pin (config/release-status.json), or nothing when the contract is unreadable.
sc_approved_ref() {
	_sc_c="${1:-}/config/release-status.json"
	[ -f "$_sc_c" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r '.consumer_ref.value // empty' "$_sc_c" 2>/dev/null || true
}

# sc_derive_repository <engine-root> — echo `owner/name` derived from the engine checkout's
# configured `origin` remote, or nothing when it is absent, ambiguous or unparseable.
# Deriving is a convenience; an UNCLEAR remote must never be guessed at.
sc_derive_repository() {
	_sc_root="${1:-}"
	[ -n "$_sc_root" ] || return 0
	command -v git >/dev/null 2>&1 || return 0
	git -C "$_sc_root" rev-parse --git-dir >/dev/null 2>&1 || return 0
	_sc_url=$(git -C "$_sc_root" remote get-url origin 2>/dev/null) || return 0
	[ -n "$_sc_url" ] || return 0
	sc_normalize_repository "$_sc_url" || return 0
}

# sc_workflow_value <file> <KEY> — echo the value currently assigned to a workflow env key.
sc_workflow_value() {
	[ -f "${1:-}" ] || return 0
	grep -E "^[[:space:]]*${2}:" "$1" 2>/dev/null | head -n1 |
		sed -E "s/^[[:space:]]*${2}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# sc_render_workflow <file> <repository> <ref> — rewrite the two source-configuration lines
# in place, atomically (temp + mv, so an interrupted render never leaves a half-written
# workflow). Both values MUST already be validated by the caller; this function re-validates
# and refuses rather than trusting them.
#
# The replacement is an anchored, whole-line substitution performed by awk with the values
# passed as VARIABLES (never interpolated into a program or a shell command), so a value can
# never introduce YAML structure or an expression.
sc_render_workflow() {
	_sc_f="${1:-}"; _sc_repo="${2:-}"; _sc_ref="${3:-}"
	[ -f "$_sc_f" ] || return 1
	sc_normalize_repository "$_sc_repo" >/dev/null 2>&1 || return 1
	sc_ref_kind "$_sc_ref" >/dev/null 2>&1 || return 1
	_sc_tmp="$_sc_f.sc.tmp.$$"
	awk -v repo="$_sc_repo" -v ref="$_sc_ref" '
		function indent(s,   m) { m = s; sub(/[^ \t].*$/, "", m); return m }
		/^[ \t]*SENTINEL_SHIELD_REPOSITORY:/ { print indent($0) "SENTINEL_SHIELD_REPOSITORY: " repo; next }
		/^[ \t]*SENTINEL_SHIELD_REF:/        { print indent($0) "SENTINEL_SHIELD_REF: " ref;         next }
		{ print }
	' "$_sc_f" > "$_sc_tmp" || { rm -f -- "$_sc_tmp"; return 1; }
	# A render that produced nothing, or that failed to place the values, must not replace the
	# original file: fail closed and leave the workflow as it was.
	[ -s "$_sc_tmp" ] || { rm -f -- "$_sc_tmp"; return 1; }
	if grep -qE '^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:' "$_sc_f"; then
		grep -qE "^[[:space:]]*SENTINEL_SHIELD_REPOSITORY: ${_sc_repo}\$" "$_sc_tmp" || { rm -f -- "$_sc_tmp"; return 1; }
	fi
	mv -- "$_sc_tmp" "$_sc_f" || { rm -f -- "$_sc_tmp"; return 1; }
	return 0
}

# sc_has_placeholder <file> — true when a workflow still carries the shipped placeholder and
# is therefore not runnable.
sc_has_placeholder() {
	[ -f "${1:-}" ] || return 1
	grep -qE "^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:[[:space:]]*(YOUR_ORG/|<)" "$1" 2>/dev/null
}
