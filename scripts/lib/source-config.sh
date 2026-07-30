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
# GitHub Enterprise: `actions/checkout` resolves `owner/name` against the RUNNER's GitHub
# host, and this installer does not render a `github-server-url`. Reducing a GHE URL to
# `owner/name` would therefore silently retarget the request to whatever server the runner
# uses, so a non-github.com host is REFUSED. A GHE consumer passes the bare `owner/name` and
# runs on the matching server, which is the only form the action can honour.
# sc__single_line <value> — 0 only when the value is exactly ONE line.
#
# `grep -Eq '^…$'` is LINE-oriented: with an embedded newline the anchors match per line, so a
# two-line value passes whenever ANY line matches while the validator hands the caller back the
# WHOLE multi-line string. `sc_render_workflow` then substitutes it verbatim and the extra line
# becomes a new key in the installed workflow YAML — the exact thing this file promises cannot
# happen. Every validator below rejects a multi-line value before any grep sees it.
sc__single_line() {
	# `$(printf '\n')` cannot be used as a case pattern: command substitution strips trailing
	# newlines, so the pattern collapses to `**` and matches everything. Count the newlines
	# instead — a single-line value has none — and reject a carriage return separately.
	[ "$(printf '%s' "${1:-}" | wc -l | tr -d ' ')" = "0" ] || return 1
	case "${1:-}" in *"$(printf '\r')"*) return 1 ;; esac
	return 0
}

sc_normalize_repository() {
	_sc_in="${1:-}"
	[ -n "$_sc_in" ] || return 1
	sc__single_line "$_sc_in" || return 1
	# Reject anything that could escape the YAML scalar or reach a shell/expression context.
	case "$_sc_in" in
		*'$'* | *'`'* | *'{'* | *'}'* | *'"'* | *"'"* | *'\'* | *' '* | *"$(printf '\t')"* | *'#'* | *'&'* | *';'* | *'|'* | *'<'* | *'>'* | *'('* | *')'* | *'!'* | *'*'* | *'?'* | *'['* | *']'*)
			return 1 ;;
	esac
	case "$_sc_in" in *..*) return 1 ;; esac
	# Strip a recognised transport prefix, then a trailing .git.
	#
	# THE HOST IS NOT COSMETIC. `actions/checkout` resolves a bare `owner/name` against the
	# RUNNER's GitHub server, so silently discarding the host turns
	# `https://ghe.example/acme/engine` into `github.com/acme/engine` on a github.com runner —
	# a different repository than the caller asked for. A URL whose host is not a GitHub.com
	# host is therefore REFUSED rather than retargeted; pass the bare `owner/name` (and run on
	# the matching server) if that is what you mean. Plain `http://` is refused outright.
	_sc_v="$_sc_in"
	_sc_host=""
	case "$_sc_v" in
		http://*) return 1 ;;
		https://*) _sc_v="${_sc_v#https://}"; _sc_host="${_sc_v%%/*}"; _sc_v="${_sc_v#*/}" ;;
		ssh://*) _sc_v="${_sc_v#ssh://}"; _sc_v="${_sc_v#*@}"; _sc_host="${_sc_v%%/*}"; _sc_v="${_sc_v#*/}" ;;
		git@*:*) _sc_host="${_sc_v#git@}"; _sc_host="${_sc_host%%:*}"; _sc_v="${_sc_v#*:}" ;;
		*@*) return 1 ;;
	esac
	if [ -n "$_sc_host" ]; then
		_sc_host="${_sc_host%%:*}"   # drop a :port
		case "$_sc_host" in
			github.com | www.github.com | ssh.github.com) : ;;
			*) return 1 ;;
		esac
	fi
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
	sc__single_line "$_sc_r" || return 1
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

# sc__restore_traps — put the caller INT/TERM/HUP handlers back exactly as they were.
# Ours are cleared first: `trap` only PRINTS the signals that are actually set, so a caller
# with no INT handler produces no INT line and a bare re-input would leave ours installed.
sc__restore_traps() {
	trap - INT TERM HUP
	[ -z "${_sc_prev_traps:-}" ] || eval "$_sc_prev_traps"
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
	# Substitute the CANONICAL value, not the caller's input. The docstring puts normalisation
	# on the caller, and a caller that only validated (sync-baseline's effective_source) would
	# otherwise write a raw URL into SENTINEL_SHIELD_REPOSITORY, which actions/checkout cannot
	# consume. Capturing it here makes this the single safety net for every caller.
	_sc_repo=$(sc_normalize_repository "$_sc_repo") || return 1
	sc_ref_kind "$_sc_ref" >/dev/null 2>&1 || return 1
	# EXACTLY ONE of each key IN THE WORKFLOW-LEVEL `env:` MAPPING, before anything is written.
	# Counting every indentation was textual cardinality, not semantic: a key nested under a
	# job or step `env:` satisfied the precondition while the top-level configuration was
	# absent, an unrelated nested key could be rewritten as though it were the canonical
	# setting, and one canonical key plus one nested key was rejected as a duplicate. Scope is
	# tracked structurally instead: the top-level `env:` block starts at column 0 and its
	# DIRECT children are exactly two spaces in; any less-indented non-blank, non-comment line
	# ends it.
	_sc_counts=$(awk '
		BEGIN { inenv = 0; nrepo = 0; nref = 0 }
		/^[ \t]*#/ { next }
		/^env:[ \t]*$/ { inenv = 1; next }
		{
			if (inenv) {
				# A direct child of the top-level mapping is indented exactly two spaces.
				if ($0 ~ /^  [^ \t]/) {
					if ($0 ~ /^  SENTINEL_SHIELD_REPOSITORY:/) nrepo++
					else if ($0 ~ /^  SENTINEL_SHIELD_REF:/) nref++
					next
				}
				# Deeper lines belong to a nested value; blank lines do not end the block.
				if ($0 ~ /^   / || $0 ~ /^[ \t]*$/) next
				inenv = 0
			}
		}
		END { printf "%d %d", nrepo, nref }
	' "$_sc_f" 2>/dev/null || printf '0 0')
	_sc_nrepo=${_sc_counts%% *}
	_sc_nref=${_sc_counts##* }
	case "$_sc_nrepo" in '' | *[!0-9]*) _sc_nrepo=0 ;; esac
	case "$_sc_nref" in '' | *[!0-9]*) _sc_nref=0 ;; esac
	if [ "$_sc_nrepo" -ne 1 ] || [ "$_sc_nref" -ne 1 ]; then
		log_error "source-config: the workflow-level env: mapping in $_sc_f declares SENTINEL_SHIELD_REPOSITORY x$_sc_nrepo and SENTINEL_SHIELD_REF x$_sc_nref; exactly one of each is required THERE. Zero means the rendered workflow cannot check the engine out (a key nested under a job or step env: is not the source configuration); more than one is an ambiguous mapping whose value depends on the YAML parser."
		return 1
	fi
	# SECURELY-CREATED temp file. `$_sc_f.sc.tmp.$$` is predictable, so anyone able to write
	# in that directory could pre-create it as a SYMLINK and the render would be written
	# through the link before the final `mv` — defeating the atomic-render guarantee this
	# function exists to provide. mktemp creates the file itself, with a private mode, and
	# refuses to follow an existing path; the result is re-checked as a regular non-symlink
	# file before anything is written into it.
	_sc_tmp=$(mktemp "$_sc_f.sc.tmp.XXXXXX") || return 1
	if [ -L "$_sc_tmp" ] || [ ! -f "$_sc_tmp" ]; then rm -f -- "$_sc_tmp"; return 1; fi
	chmod 600 "$_sc_tmp" 2>/dev/null || { rm -f -- "$_sc_tmp"; return 1; }
	# Clean up on every exit path, including a signal between create and rename — WITHOUT
	# destroying the handlers the caller installed. install-baseline.sh arms a transaction
	# rollback on INT/TERM; replacing it here and then clearing it with `trap -` left the rest
	# of the installation running with NO rollback on interrupt. POSIX `trap` with no operands
	# prints the current handlers in a form that can be re-input, so they are saved and
	# restored around the window.
	_sc_prev_traps=$(trap)
	trap 'rm -f -- "$_sc_tmp" 2>/dev/null || true' INT TERM HUP
	# The REWRITE is scoped identically: only direct children of the top-level env: mapping are
	# replaced, so a same-named key under a job/step env: (or any other mapping) is left exactly
	# as it was rather than being rewritten as if it were the source configuration.
	awk -v repo="$_sc_repo" -v ref="$_sc_ref" '
		BEGIN { inenv = 0 }
		/^[ \t]*#/ { print; next }
		/^env:[ \t]*$/ { inenv = 1; print; next }
		{
			if (inenv) {
				if ($0 ~ /^  [^ \t]/) {
					if ($0 ~ /^  SENTINEL_SHIELD_REPOSITORY:/) { print "  SENTINEL_SHIELD_REPOSITORY: " repo; next }
					if ($0 ~ /^  SENTINEL_SHIELD_REF:/)        { print "  SENTINEL_SHIELD_REF: " ref;         next }
					print; next
				}
				if ($0 ~ /^   / || $0 ~ /^[ \t]*$/) { print; next }
				inenv = 0
			}
			print
		}
	' "$_sc_f" > "$_sc_tmp" || { sc__restore_traps; rm -f -- "$_sc_tmp"; return 1; }
	# A render that produced nothing, or that failed to place the values, must not replace the
	# original file: fail closed and leave the workflow as it was.
	[ -s "$_sc_tmp" ] || { sc__restore_traps; rm -f -- "$_sc_tmp"; return 1; }
	# POST-RENDER PROOF, for BOTH keys. The repository check used to be conditional on the
	# original already containing the key, and the ref was never checked at all — so a render
	# that silently failed to place a value still returned success.
	_sc_okrepo=$(grep -cE "^  SENTINEL_SHIELD_REPOSITORY: ${_sc_repo}\$" "$_sc_tmp" 2>/dev/null || printf '0')
	_sc_okref=$(grep -cE "^  SENTINEL_SHIELD_REF: ${_sc_ref}\$" "$_sc_tmp" 2>/dev/null || printf '0')
	case "$_sc_okrepo" in '' | *[!0-9]*) _sc_okrepo=0 ;; esac
	case "$_sc_okref" in '' | *[!0-9]*) _sc_okref=0 ;; esac
	if [ "$_sc_okrepo" -ne 1 ] || [ "$_sc_okref" -ne 1 ]; then
		log_error "source-config: the render did not place exactly one canonical value in $_sc_f (repository x$_sc_okrepo, ref x$_sc_okref) — refusing to publish a workflow whose source configuration is incomplete."
		sc__restore_traps; rm -f -- "$_sc_tmp"; return 1
	fi
	# Preserve the destination's mode deliberately: mktemp made the staging file private, and
	# a workflow file the runner cannot read is useless. Copy the original mode when it can be
	# read, else fall back to the conventional 0644.
	_sc_mode=$(ls -l "$_sc_f" 2>/dev/null | cut -c2-10)
	if [ -n "$_sc_mode" ]; then
		chmod "$(printf '%s' "$_sc_mode" | awk '{
			s = $0; m = 0
			if (substr(s,1,1) == "r") m += 400; if (substr(s,2,1) == "w") m += 200; if (substr(s,3,1) == "x") m += 100
			if (substr(s,4,1) == "r") m += 40;  if (substr(s,5,1) == "w") m += 20;  if (substr(s,6,1) == "x") m += 10
			if (substr(s,7,1) == "r") m += 4;   if (substr(s,8,1) == "w") m += 2;   if (substr(s,9,1) == "x") m += 1
			printf "%04d", m }')" "$_sc_tmp" 2>/dev/null || chmod 644 "$_sc_tmp" 2>/dev/null || true
	else
		chmod 644 "$_sc_tmp" 2>/dev/null || true
	fi
	mv -- "$_sc_tmp" "$_sc_f" || { sc__restore_traps; rm -f -- "$_sc_tmp"; return 1; }
	sc__restore_traps
	return 0
}

# sc_has_placeholder <file> — true when the workflow's declared engine source is NOT a value
# this installer would write, and the workflow therefore cannot check the engine out.
#
# This used to pattern-match the two shipped placeholder spellings (`YOUR_ORG/` and `<…>`), so
# the fail-closed preflight it feeds only recognised the values we happened to ship. Every
# OTHER unusable value passed it: `TODO`, an empty assignment, a value with a space in it, a
# GitHub Enterprise URL that sc_normalize_repository refuses precisely because reducing it to
# `owner/name` would retarget the checkout to the runner's host. "Not the placeholder we ship"
# is not the same question as "usable", and the preflight needs the second one.
#
# So the question is now asked of the canonical validator rather than a second pattern kept in
# step with it by hand: whatever sc_normalize_repository refuses, this reports.
sc_has_placeholder() {
	[ -f "${1:-}" ] || return 1
	# A file that does not declare the key at all is not what this check is about — a missing
	# key is a separate contract, and answering "yes, placeholder" here would misreport it.
	grep -qE "^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:" "$1" 2>/dev/null || return 1
	_sc_hp=$(sc_workflow_value "$1" SENTINEL_SHIELD_REPOSITORY)
	sc_normalize_repository "$_sc_hp" >/dev/null 2>&1 && return 1
	return 0
}
