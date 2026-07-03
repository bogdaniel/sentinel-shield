#!/bin/sh
# Sentinel Shield — verify a PUBLISHED release (MACRO-TASK 4).
#
# Post-publication verification of a release that already exists. It is READ-ONLY: it inspects
# a tag / GitHub Release / published artifacts and NEVER creates, deletes, or moves any of them.
#
# Modes:
#   verify-tag             Prove a published tag targets the exact CI-proven source commit AND
#                          (by default) carries a good signature. A tag that peels to a DIFFERENT
#                          commit (a moved/mis-targeted tag) or whose signature is unverifiable is
#                          REJECTED (fail closed). --allow-unsigned downgrades to identity-only and
#                          says so loudly (signature NOT proven).
#   verify-github-release  Prove the GitHub Release metadata is sane: tag matches, not a draft, and
#                          (for GA) not a prerelease; optional commit cross-check. Metadata may be
#                          supplied offline via --release-json or fetched via $GH_BIN.
#   smoke                  Post-release smoke: re-verify the manifest is self-consistent and the
#                          published artifact digests still reproduce the manifest fingerprint.
#
# Exit: 0 verified; 1 REJECTED (moved/mis-targeted/unsigned/draft/mismatch); 2 invalid invocation /
#       malformed input; 3 required tool unavailable; 4 timeout.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/source-verification.sh
. "$SCRIPT_DIR/lib/source-verification.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$SCRIPT_DIR/lib/release-authz.sh"

VERIFY_MANIFEST="$SCRIPT_DIR/verify-release-manifest.sh"
BOUND_SECS="${RA_BOUND_SECS:-120}"

usage() {
	cat <<'EOF'
Usage:
  verify-published-release.sh verify-tag --repo-root <dir> --tag <name> --commit <40hex> [--allow-unsigned]
  verify-published-release.sh verify-github-release --tag <name> [--expected-commit <40hex>] [--stage <beta|rc|ga>] \
      (--release-json <file> | --repo <owner/name>)
  verify-published-release.sh smoke --manifest <file> --artifacts <verify-report.json>

READ-ONLY. Never creates, deletes, or moves a tag or release.
EOF
}

MODE="${1:-}"
[ -n "$MODE" ] || { log_error "a mode is required"; usage >&2; exit 2; }
case "$MODE" in
	verify-tag | verify-github-release | smoke) ;;
	-h | --help) usage; exit 0 ;;
	*) log_error "unknown mode: $MODE"; usage >&2; exit 2 ;;
esac
shift

# Refuse destructive tag/release operations in every mode.
ra_guard_destructive "$@" || exit 2

command_exists jq || { log_error "jq is required but was not found"; exit 3; }

ROOTDIR=""; TAG=""; COMMIT=""; EXPECTED_COMMIT=""; STAGE=""; RELEASE_JSON=""; REPO=""
MANIFEST=""; ARTIFACTS=""; ALLOW_UNSIGNED=0
while [ $# -gt 0 ]; do
	case "$1" in
		--repo-root) ROOTDIR="${2:?}"; shift 2 ;;
		--tag) TAG="${2:?}"; shift 2 ;;
		--commit) COMMIT="${2:?}"; shift 2 ;;
		--expected-commit) EXPECTED_COMMIT="${2:?}"; shift 2 ;;
		--stage) STAGE="${2:?}"; shift 2 ;;
		--release-json) RELEASE_JSON="${2:?}"; shift 2 ;;
		--repo) REPO="${2:?}"; shift 2 ;;
		--manifest) MANIFEST="${2:?}"; shift 2 ;;
		--artifacts) ARTIFACTS="${2:?}"; shift 2 ;;
		--allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

# ============================================================================
# mode: verify-tag
# ============================================================================
if [ "$MODE" = verify-tag ]; then
	command_exists git || { log_error "verify-tag: git is required"; exit 3; }
	[ -n "$ROOTDIR" ] && [ -d "$ROOTDIR/.git" ] || { log_error "verify-tag: --repo-root must be a git checkout"; exit 2; }
	[ -n "$TAG" ] || { log_error "verify-tag: --tag is required"; exit 2; }
	ra_is_hex40 "$COMMIT" || { log_error "verify-tag: --commit must be a 40-hex SHA"; exit 2; }
	COMMIT=$(printf '%s' "$COMMIT" | tr 'A-F' 'a-f')

	# (1) The tag must exist.
	if ! ra_bounded "$BOUND_SECS" git -C "$ROOTDIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
		[ "${RA_TIMEOUT}" = 1 ] && { log_error "verify-tag: git timed out"; exit 4; }
		log_error "verify-tag: TAG_ABSENT — tag '$TAG' does not exist in $ROOTDIR (fail closed)"
		exit 1
	fi

	# (2) INDEPENDENT commit-identity: the tag must peel to EXACTLY the expected source commit.
	#     This catches a moved or mis-targeted tag regardless of signature state.
	_peeled=$(git -C "$ROOTDIR" rev-list -n1 "$TAG" 2>/dev/null) || _peeled=""
	if [ "$_peeled" != "$COMMIT" ]; then
		log_error "verify-tag: TAG_TARGETS_WRONG_COMMIT — '$TAG' peels to ${_peeled:-unknown} but the release source commit is $COMMIT (fail closed)"
		exit 1
	fi
	log_info "verify-tag: identity OK — '$TAG' targets the CI-proven source commit $COMMIT"

	# (3) Signature: required by default. An unsigned/unverifiable annotated tag is REJECTED.
	if [ "$ALLOW_UNSIGNED" = 1 ]; then
		log_warn "verify-tag: --allow-unsigned set — signature NOT proven; result is IDENTITY-ONLY and must not be treated as a signed-tag verification."
		printf 'verify-tag: %s -> %s VERIFIED (identity-only; signature NOT checked)\n' "$TAG" "$COMMIT"
		exit 0
	fi
	if sv_verify_signature "$ROOTDIR" "$TAG" "$COMMIT" >/dev/null 2>&1; then
		printf 'verify-tag: %s -> %s VERIFIED (signed + identity)\n' "$TAG" "$COMMIT"
		exit 0
	fi
	log_error "verify-tag: TAG_SIGNATURE_UNVERIFIABLE — '$TAG' is not an annotated tag with a good, verifiable signature targeting $COMMIT (fail closed)"
	exit 1
fi

# ============================================================================
# mode: verify-github-release
# ============================================================================
if [ "$MODE" = verify-github-release ]; then
	[ -n "$TAG" ] || { log_error "verify-github-release: --tag is required"; exit 2; }
	if [ -n "$RELEASE_JSON" ]; then
		[ -f "$RELEASE_JSON" ] || { log_error "verify-github-release: --release-json not found: $RELEASE_JSON"; exit 2; }
		jq -e . "$RELEASE_JSON" >/dev/null 2>&1 || { log_error "verify-github-release: --release-json is not valid JSON"; exit 2; }
		_meta=$(cat "$RELEASE_JSON")
	elif [ -n "$REPO" ]; then
		: "${GH_BIN:=gh}"
		command_exists "$GH_BIN" || { log_error "verify-github-release: '$GH_BIN' is required to fetch release metadata"; exit 3; }
		case "$REPO" in */*) ;; *) log_error "verify-github-release: --repo must be owner/name"; exit 2 ;; esac
		_meta=$(ra_bounded "$BOUND_SECS" "$GH_BIN" api "repos/$REPO/releases/tags/$TAG" 2>/dev/null) || {
			[ "${RA_TIMEOUT}" = 1 ] && { log_error "verify-github-release: gh timed out"; exit 4; }
			log_error "verify-github-release: could not fetch release for tag '$TAG' from $REPO (fail closed)"; exit 1; }
		printf '%s' "$_meta" | jq -e . >/dev/null 2>&1 || { log_error "verify-github-release: malformed release metadata from GitHub"; exit 2; }
	else
		log_error "verify-github-release: provide --release-json <file> or --repo <owner/name>"; exit 2
	fi

	_fails=0
	_pass() { printf '  PASS  %s\n' "$*"; }
	_fail() { _fails=$((_fails + 1)); printf '  FAIL  %s\n' "$*"; }

	_tag_name=$(printf '%s' "$_meta" | jq -r '.tag_name // ""')
	if [ "$_tag_name" = "$TAG" ]; then _pass "release tag_name matches '$TAG'"
	else _fail "TAG_NAME_MISMATCH — release tag_name='$_tag_name' expected='$TAG'"; fi

	_draft=$(printf '%s' "$_meta" | jq -r 'if (.draft // false) then "true" else "false" end')
	if [ "$_draft" = false ]; then _pass "release is published (draft=false)"
	else _fail "RELEASE_IS_DRAFT — a draft release is not a published release"; fi

	if [ "$STAGE" = ga ]; then
		_pre=$(printf '%s' "$_meta" | jq -r 'if (.prerelease // false) then "true" else "false" end')
		if [ "$_pre" = false ]; then _pass "GA release is not a prerelease"
		else _fail "GA_MARKED_PRERELEASE — a GA release must not be marked prerelease"; fi
	fi

	if [ -n "$EXPECTED_COMMIT" ]; then
		ra_is_hex40 "$EXPECTED_COMMIT" || { log_error "verify-github-release: --expected-commit must be a 40-hex SHA"; exit 2; }
		_ec=$(printf '%s' "$EXPECTED_COMMIT" | tr 'A-F' 'a-f')
		# GitHub's release object may not carry the tag's peeled commit; only compare a 40-hex field.
		_rc=$(printf '%s' "$_meta" | jq -r '(.commit // .sha // .target_commitish // "") | tostring')
		if printf '%s' "$_rc" | grep -Eq '^[0-9a-f]{40}$'; then
			if [ "$_rc" = "$_ec" ]; then _pass "release commit matches $_ec"
			else _fail "RELEASE_COMMIT_MISMATCH — release commit=$_rc expected=$_ec"; fi
		else
			log_warn "verify-github-release: release metadata carries no 40-hex commit (target_commitish='$_rc'); verify the pushed TAG target with verify-tag."
		fi
	fi

	printf '\n----\n'
	if [ "$_fails" -eq 0 ]; then
		printf 'verify-github-release: %s VERIFIED\n' "$TAG"
		exit 0
	fi
	printf 'verify-github-release: %s REJECTED (%d check(s) failed); fail closed\n' "$TAG" "$_fails"
	exit 1
fi

# ============================================================================
# mode: smoke — post-release smoke over the manifest + published artifacts
# ============================================================================
if [ "$MODE" = smoke ]; then
	[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { log_error "smoke: --manifest <file> is required"; exit 2; }
	[ -n "$ARTIFACTS" ] && [ -f "$ARTIFACTS" ] || { log_error "smoke: --artifacts <verify-report.json> is required"; exit 2; }
	[ -f "$VERIFY_MANIFEST" ] || { log_error "smoke: manifest verifier not found: $VERIFY_MANIFEST"; exit 3; }
	_fails=0
	_pass() { printf '  PASS  %s\n' "$*"; }
	_fail() { _fails=$((_fails + 1)); printf '  FAIL  %s\n' "$*"; }

	_rc=0; ra_bounded "$BOUND_SECS" sh "$VERIFY_MANIFEST" --manifest "$MANIFEST" >/dev/null 2>&1 || _rc=$?
	if [ "$_rc" = 124 ]; then log_error "smoke: manifest verification timed out"; exit 4; fi
	if [ "$_rc" = 0 ]; then _pass "manifest self-consistent"; else _fail "manifest self-consistency failed (exit $_rc)"; fi

	if ra_gate_ok "$ARTIFACTS"; then _pass "published artifact verification is green"; else _fail "artifact verification report is not green"; fi

	_rc=0; ra_artifacts_match_manifest "$ARTIFACTS" "$MANIFEST" || _rc=$?
	if [ "$_rc" = 0 ]; then _pass "published artifact digests reproduce the manifest fingerprint"
	elif [ "$_rc" = 2 ]; then _fail "artifact/manifest digest inputs malformed (fail closed)"
	else _fail "DIGEST_MISMATCH — published artifacts do not match the manifest fingerprint"; fi

	printf '\n----\n'
	if [ "$_fails" -eq 0 ]; then printf 'smoke: post-release verification PASSED\n'; exit 0; fi
	printf 'smoke: post-release verification FAILED (%d check(s)); fail closed\n' "$_fails"
	exit 1
fi

log_error "unhandled mode: $MODE"
exit 2
