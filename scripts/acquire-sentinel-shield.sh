#!/bin/sh
# Sentinel Shield — immutable source acquisition (v2.0.0).
#
# The single canonical mechanism every install/update prompt and doc uses to obtain an
# IMMUTABLE Sentinel Shield checkout. It clones a repository at a TAG or a full 40-hex
# commit SHA only — moving branches (main/master, or any non-tag/non-SHA ref) are REFUSED
# so an installed version can never silently drift. Credentials are NEVER embedded in URLs
# or printed; authentication is delegated out-of-band (public HTTPS, the `gh` CLI's git
# credential helper, or SSH keys).
#
# Output contract:
#   exit 0  -> success; the resolved immutable commit SHA is printed to stdout
#   exit 1  -> generic error (reserved)
#   exit 2  -> invalid invocation / bad args / MOVING-BRANCH (non-immutable ref) rejected
#   exit 3  -> required tool unavailable (git, or `gh` for --transport gh)
#   exit 4  -> clone / ref-resolution / verification failure (fails CLOSED)
#
# Usage: sh scripts/acquire-sentinel-shield.sh --repository <owner/repo|url|path>
#            --ref <tag|40-hex-sha> --destination <dir>
#            [--transport https|ssh|gh] [--verify] [--reuse-existing] [--cleanup]
#   --repository  owner/repo shorthand (resolved per --transport), OR an explicit remote
#                 (https://, ssh://, git@host:..., or a local path) used verbatim.
#   --ref         An IMMUTABLE ref: an annotated/lightweight tag, or a full 40-hex commit
#                 SHA. Branch names and short SHAs are REJECTED (exit 2).
#   --destination The checkout directory (the ONLY path mutated in the consumer project).
#   --transport   Remote scheme for owner/repo shorthand: https (default), ssh, or gh.
#   --verify      Assert the checkout HEAD equals the requested ref's resolved commit;
#                 a mismatch FAILS CLOSED (exit 4).
#   --reuse-existing  Reuse a present checkout whose HEAD already matches instead of cloning.
#   --cleanup     Remove the destination first (may be used alone to just clean up).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# usage — print CLI usage/help to stdout (lists every flag).
usage() {
	cat <<'EOF'
Usage: acquire-sentinel-shield.sh --repository <owner/repo|url|path> --ref <tag|40-hex-sha> --destination <dir>
                                  [--transport https|ssh|gh] [--verify] [--reuse-existing] [--cleanup]
  --repository <owner/repo|url|path>  Source repo: owner/repo shorthand or an explicit remote/local path.
  --ref <tag|40-hex-sha>              Immutable ref (tag or full 40-hex SHA); moving branches are refused.
  --destination <dir>                 Checkout directory (the only path mutated).
  --transport https|ssh|gh            Remote scheme for owner/repo shorthand (default: https).
  --verify                            Assert checkout HEAD == resolved commit; fail closed on mismatch.
  --reuse-existing                    Reuse a present matching checkout instead of re-cloning.
  --cleanup                           Remove the destination first (or alone, just clean up).
  -h, --help                          Print this help and exit 0.
EOF
}

# write_ref_record <dest> <repo_kind> <repository|""> <ref> <commit> <ref_kind> — record the
# resolved ref in the NORMALIZED, privacy-preserving shape (SHARED CONTRACT 1). NO credentials
# and NO local/home paths are ever persisted: a local-path source records repository=null.
# repository_kind is github|url|local; ref_kind is the authoritative tag|sha classification
# doctor.sh relies on to prove immutability.
write_ref_record() {
	_rkind=$(json_escape "$2"); _rf=$(json_escape "$4"); _kind=$(json_escape "$6")
	if [ -n "$3" ]; then
		_repo="\"$(json_escape "$3")\""
	else
		_repo="null"
	fi
	printf '{"repository_kind":"%s","repository":%s,"ref":"%s","resolved_commit":"%s","ref_kind":"%s"}\n' \
		"$_rkind" "$_repo" "$_rf" "$5" "$_kind" > "$1/.sentinel-shield-ref" || {
		log_error "acquire: cannot write ref record to $1/.sentinel-shield-ref"; return 1
	}
}

# acquire_sanitize_url <url> — strip userinfo, query, and fragment from an explicit remote
# URL so no secret/identity is persisted in the ref record (privacy). Path is preserved.
acquire_sanitize_url() {
	_u=$1
	_u=${_u%%#*}    # drop #fragment
	_u=${_u%%\?*}   # drop ?query
	case "$_u" in
		*://*)
			_sch=${_u%%://*}
			_rest=${_u#*://}
			_host=${_rest%%/*}
			_path=${_rest#"$_host"}
			case "$_host" in *@*) _host=${_host#*@} ;; esac   # drop userinfo@
			_u="$_sch://$_host$_path"
			;;
		*@*:*)
			_u=${_u#*@}   # scp-form git@host:path -> host:path
			;;
	esac
	printf '%s' "$_u"
}

# acquire_canonical <path> — canonical absolute path WITHOUT requiring <path> to exist:
# resolve the (existing) parent dir, then append the basename. Echoes nothing and returns
# 1 when the parent cannot be resolved, so the caller can fail closed.
acquire_canonical() {
	_ap=$1
	_par=$(dirname -- "$_ap")
	_bas=$(basename -- "$_ap")
	_cpar=$(CDPATH= cd -- "$_par" 2>/dev/null && pwd -P) || return 1
	case "$_cpar" in
		/) printf '/%s' "$_bas" ;;
		*) printf '%s/%s' "$_cpar" "$_bas" ;;
	esac
}

# acquire_validate_destination <path> — the SINGLE destructive-destination guard called
# before EVERY `rm -rf "$DEST"`. It deletes NOTHING; on any unsafe path it logs and
# exit 2. Refuses: empty; '/'; '.'/'..'; a path with a '..' component; a symlink (never
# followed — at most the symlink itself, which we still refuse here); the CWD; $HOME; the
# Sentinel Shield SOURCE repo root (SCRIPT_DIR/..); a known consumer TARGET root
# (SENTINEL_SHIELD_TARGET_ROOT); and any ancestor of the CWD. PERMITS only a dedicated
# tools dir, proven by CANONICAL CONTAINMENT (never basename matching alone): a canonical
# path whose basename is '.sentinel-shield-tools' or that sits under a 'tools/' dir.
acquire_validate_destination() {
	_d=$1
	[ -n "$_d" ] || { log_error "acquire: refusing to remove an empty destination"; exit 2; }
	case "/$_d/" in
		*/../*) log_error "acquire: refusing destination with unresolved '..' traversal: $_d"; exit 2 ;;
	esac
	case "$_d" in
		/ | . | ..) log_error "acquire: refusing unsafe destination: $_d"; exit 2 ;;
	esac
	if [ -L "$_d" ]; then
		log_error "acquire: refusing to delete a symlink destination (will not follow): $_d"; exit 2
	fi
	_canon=$(acquire_canonical "$_d") || {
		log_error "acquire: cannot resolve destination parent — refusing: $_d"; exit 2; }
	[ "$_canon" != "/" ] || { log_error "acquire: refusing to remove '/'"; exit 2; }

	_cwd=$(pwd -P)
	_home=""
	if [ -n "${HOME:-}" ]; then
		_home=$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")
	fi
	_src=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P || printf '')
	_tgt=""
	if [ -n "${SENTINEL_SHIELD_TARGET_ROOT:-}" ]; then
		_tgt=$(CDPATH= cd -- "$SENTINEL_SHIELD_TARGET_ROOT" 2>/dev/null && pwd -P \
			|| printf '%s' "$SENTINEL_SHIELD_TARGET_ROOT")
	fi
	for _bad in "$_cwd" "$_home" "$_src" "$_tgt"; do
		[ -n "$_bad" ] || continue
		if [ "$_canon" = "$_bad" ]; then
			log_error "acquire: refusing to remove a protected path: $_d"; exit 2
		fi
	done
	# An ancestor of the CWD (DEST physically contains the current directory).
	case "$_cwd/" in
		"$_canon"/*) log_error "acquire: refusing to remove an ancestor of the current directory: $_d"; exit 2 ;;
	esac

	# PERMIT only a dedicated tools dir (canonical containment).
	_base=$(basename -- "$_canon")
	[ "$_base" = ".sentinel-shield-tools" ] && return 0
	case "$_canon" in
		*/tools/*) return 0 ;;
	esac
	log_error "acquire: refusing to delete a non-tools destination (only '.sentinel-shield-tools' or a path under a 'tools/' dir may be removed): $_d"
	exit 2
}

REPO=""
REF=""
DEST=""
TRANSPORT="https"
VERIFY=0
REUSE=0
CLEANUP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--repository) REPO="${2:?--repository requires a value}"; shift 2 ;;
		--ref) REF="${2:?--ref requires a value}"; shift 2 ;;
		--destination)
			[ $# -ge 2 ] || { log_error "acquire: --destination requires a value"; exit 2; }
			DEST="$2"; shift 2 ;;
		--transport) TRANSPORT="${2:?--transport requires a value}"; shift 2 ;;
		--verify) VERIFY=1; shift ;;
		--reuse-existing) REUSE=1; shift ;;
		--cleanup) CLEANUP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "acquire: unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

case "$TRANSPORT" in
	https | ssh | gh) ;;
	*) log_error "acquire: invalid --transport '$TRANSPORT' (https|ssh|gh)"; exit 2 ;;
esac
[ -n "$DEST" ] || { log_error "acquire: --destination is required"; usage >&2; exit 2; }

# --cleanup may be used ALONE (no repo/ref) to just remove the destination and exit.
if [ "$CLEANUP" = 1 ] && [ -z "$REPO" ] && [ -z "$REF" ]; then
	acquire_validate_destination "$DEST"
	rm -rf -- "$DEST"
	log_info "acquire: removed destination: $DEST"
	exit 0
fi

[ -n "$REPO" ] || { log_error "acquire: --repository is required"; usage >&2; exit 2; }
[ -n "$REF" ] || { log_error "acquire: --ref is required"; usage >&2; exit 2; }
command_exists git || { log_error "acquire: git not found (required)"; exit 3; }

# --- resolve the remote URL (NO credentials are ever embedded) ----------------
# An explicit remote (scheme://, git@host:..., or a local/relative path) is used verbatim;
# an owner/repo shorthand is expanded per --transport.
USE_GH=0
# Refuse credential-bearing http(s) remotes (userinfo: token@ or user:token@) BEFORE
# any branch accepts them — a secret must never be embedded, logged, or persisted.
case "$REPO" in
	http://*@* | https://*@*)
		log_error "acquire: refusing credential-bearing remote URL (userinfo not allowed; authenticate out-of-band)"; exit 2 ;;
	http://*[?#]* | https://*[?#]*)
		log_error "acquire: refusing http(s) remote URL with query/fragment (strip ?query/#fragment from the remote)"; exit 2 ;;
esac
# REPO_KIND/REPO_NORM are the NORMALIZED provenance recorded in .sentinel-shield-ref:
#   github -> owner/repo ; url -> sanitized URL ; local -> null (path is NEVER persisted).
REPO_KIND=""
REPO_NORM=""
case "$REPO" in
	*://* | git@*:*)
		URL="$REPO"; REPO_KIND="url"; REPO_NORM=$(acquire_sanitize_url "$REPO") ;;
	/* | ./* | ../*)
		URL="$REPO"; REPO_KIND="local"; REPO_NORM="" ;;
	*/*)
		# A path-like input that exists on disk is a LOCAL path (e.g. tmp/remote.git),
		# used verbatim; never rewrite it to a GitHub URL. Otherwise it is owner/repo.
		if [ -e "$REPO" ]; then
			URL="$REPO"; REPO_KIND="local"; REPO_NORM=""
		else
			case "$TRANSPORT" in
				ssh) URL="git@github.com:$REPO.git" ;;
				gh) URL="https://github.com/$REPO.git"; USE_GH=1 ;;
				*) URL="https://github.com/$REPO.git" ;;
			esac
			REPO_KIND="github"; REPO_NORM="$REPO"
		fi ;;
	*)
		log_error "acquire: invalid --repository '$REPO' (expected owner/repo, a URL, or a path)"; exit 2 ;;
esac
if [ "$USE_GH" = 1 ]; then
	command_exists gh || { log_error "acquire: gh not found (required for --transport gh)"; exit 3; }
fi

# --- classify the ref: SHA, tag, or rejected (moving branch / unknown) --------
# Resolution uses anonymous `git ls-remote`; for owner/repo over gh the configured git
# credential helper authorizes it. KIND in {sha,tag}; EXPECTED is the immutable commit.
KIND=""
EXPECTED=""
if printf '%s' "$REF" | grep -qE '^[0-9a-fA-F]{40}$'; then
	KIND="sha"
	EXPECTED=$(printf '%s' "$REF" | tr 'A-F' 'a-f')
else
	TAG_OUT=$(git ls-remote "$URL" "refs/tags/$REF" "refs/tags/$REF^{}" 2>/dev/null) || {
		log_error "acquire: cannot reach remote to resolve ref '$REF' at $URL"; exit 4
	}
	# Prefer the peeled (^{}) commit for annotated tags; fall back to the direct line.
	EXPECTED=$(printf '%s\n' "$TAG_OUT" | awk -v r="refs/tags/$REF" '
		$2 == r "^{}" { peeled = $1 }
		$2 == r { direct = $1 }
		END { if (peeled != "") print peeled; else print direct }')
	if [ -n "$EXPECTED" ]; then
		KIND="tag"
	else
		# Not a tag. If it is a branch, name it explicitly; either way it is non-immutable.
		if [ -n "$(git ls-remote --heads "$URL" "$REF" 2>/dev/null)" ]; then
			log_error "acquire: ref '$REF' is a moving branch — refusing (use an immutable tag or full 40-hex SHA)"
		else
			log_error "acquire: ref '$REF' is not a tag and not a full 40-hex SHA — refusing (immutable refs only)"
		fi
		exit 2
	fi
fi

# --- reuse / cleanup of an existing destination -------------------------------
if [ "$CLEANUP" = 1 ]; then
	acquire_validate_destination "$DEST"
	rm -rf -- "$DEST"
fi
if [ -e "$DEST" ]; then
	if [ "$REUSE" = 1 ] && [ -d "$DEST/.git" ]; then
		CUR=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)
		# Reuse only when HEAD already matches the resolved immutable commit AND the
		# worktree is clean — a dirty checkout is not the immutable source, re-acquire.
		if [ -n "$CUR" ] && [ "$CUR" = "$EXPECTED" ] && [ -z "$(git -C "$DEST" status --porcelain 2>/dev/null)" ]; then
			log_info "acquire: reusing existing checkout at $DEST (HEAD=$CUR)"
			write_ref_record "$DEST" "$REPO_KIND" "$REPO_NORM" "$REF" "$CUR" "$KIND"
			printf '%s\n' "$CUR"
			exit 0
		fi
		log_warn "acquire: existing checkout HEAD does not match resolved commit; re-acquiring"
		acquire_validate_destination "$DEST"
		rm -rf -- "$DEST"
	else
		log_error "acquire: destination exists: $DEST (pass --reuse-existing or --cleanup)"
		exit 2
	fi
fi

# --- clone the immutable checkout (shallow where possible) --------------------
if [ "$KIND" = "tag" ]; then
	if [ "$USE_GH" = 1 ]; then
		gh repo clone "$REPO" "$DEST" -- --depth 1 --branch "$REF" --single-branch >&2 || {
			log_error "acquire: gh clone of tag '$REF' failed"; exit 4; }
	else
		git clone --quiet --depth 1 --branch "$REF" --single-branch "$URL" "$DEST" || {
			log_error "acquire: clone of tag '$REF' failed"; exit 4; }
	fi
else
	# A bare SHA cannot be shallow-fetched portably; full-clone then detach to the commit.
	if [ "$USE_GH" = 1 ]; then
		gh repo clone "$REPO" "$DEST" -- --no-checkout >&2 || {
			log_error "acquire: gh clone failed"; exit 4; }
	else
		git clone --quiet --no-checkout "$URL" "$DEST" || {
			log_error "acquire: clone failed"; exit 4; }
	fi
	git -C "$DEST" cat-file -e "$EXPECTED^{commit}" 2>/dev/null || {
		log_error "acquire: commit $EXPECTED not found in $REPO"; exit 4; }
	git -C "$DEST" checkout --quiet --detach "$EXPECTED" || {
		log_error "acquire: checkout of commit $EXPECTED failed"; exit 4; }
fi

RESOLVED=$(git -C "$DEST" rev-parse HEAD 2>/dev/null) || {
	log_error "acquire: cannot read checkout HEAD in $DEST"; exit 4; }

# --- verify (fail closed) -----------------------------------------------------
if [ "$VERIFY" = 1 ] && [ "$RESOLVED" != "$EXPECTED" ]; then
	log_error "acquire: verification FAILED — HEAD ($RESOLVED) != resolved ref commit ($EXPECTED)"
	exit 4
fi

write_ref_record "$DEST" "$REPO_KIND" "$REPO_NORM" "$REF" "$RESOLVED" "$KIND"
log_info "acquire: $REPO @ $REF -> $RESOLVED (checkout: $DEST)"
printf '%s\n' "$RESOLVED"
exit 0
