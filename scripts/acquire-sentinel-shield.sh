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

# write_ref_record <dest> <repo> <ref> <commit> — record the resolved ref (NO credentials).
write_ref_record() {
	_rep=$(json_escape "$2"); _rf=$(json_escape "$3")
	printf '{"repository":"%s","ref":"%s","resolved_commit":"%s"}\n' "$_rep" "$_rf" "$4" \
		> "$1/.sentinel-shield-ref" || {
		log_error "acquire: cannot write ref record to $1/.sentinel-shield-ref"; return 1
	}
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
		--destination) DEST="${2:?--destination requires a value}"; shift 2 ;;
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
case "$REPO" in
	*://* | git@*:* | /* | ./* | ../*)
		URL="$REPO" ;;
	*/*)
		case "$TRANSPORT" in
			ssh) URL="git@github.com:$REPO.git" ;;
			gh) URL="https://github.com/$REPO.git"; USE_GH=1 ;;
			*) URL="https://github.com/$REPO.git" ;;
		esac ;;
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
	rm -rf -- "$DEST"
fi
if [ -e "$DEST" ]; then
	if [ "$REUSE" = 1 ] && [ -d "$DEST/.git" ]; then
		CUR=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)
		# Reuse only when HEAD already matches the resolved immutable commit.
		if [ -n "$CUR" ] && [ "$CUR" = "$EXPECTED" ]; then
			log_info "acquire: reusing existing checkout at $DEST (HEAD=$CUR)"
			write_ref_record "$DEST" "$REPO" "$REF" "$CUR"
			printf '%s\n' "$CUR"
			exit 0
		fi
		log_warn "acquire: existing checkout HEAD does not match resolved commit; re-acquiring"
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

write_ref_record "$DEST" "$REPO" "$REF" "$RESOLVED"
log_info "acquire: $REPO @ $REF -> $RESOLVED (checkout: $DEST)"
printf '%s\n' "$RESOLVED"
exit 0
