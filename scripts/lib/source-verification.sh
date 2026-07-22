#!/bin/sh
# Sentinel Shield — source verification (POSIX sh library, sv_* functions).
#
# Source this file; do NOT execute it. It provides OPTIONAL, opt-in integrity verification of an
# already-acquired immutable checkout, layered ON TOP of acquire-sentinel-shield.sh's existing
# --verify (which asserts checkout HEAD == the resolved ref commit — a COMMIT-IDENTITY check).
# These functions verify the TREE content and/or a signed annotated tag, neither of which the
# commit-identity check covers.
#
# EXPLICIT verification contract (no calculated-but-uncompared value is ever called "verified"):
#   tree-record            — compute HEAD^{tree} and RECORD it. This is a RECORD, not a check;
#                            it compares against nothing and therefore proves nothing on its own.
#   tree-checksum          — REQUIRE a caller-supplied expected tree id; compute HEAD^{tree};
#                            compare EXACTLY; FAIL CLOSED on mismatch; record BOTH ids.
#   signature              — verify a SIGNED annotated tag (git verify-tag; GPG or SSH per Git
#                            config) AND that the tag peels to the expected commit. FAILS CLOSED.
#   tree-checksum+signature — both of the above.
#   (deprecated alias) checksum -> tree-record (record-only; never labelled "verified").
#
# EVERY mode ALSO independently asserts the checkout HEAD commit equals the caller's expected
# 40-hex commit FIRST (sv_assert_commit), so sv_verify is safe and meaningful even when called
# on its own — a signature or tree check can NEVER bypass commit identity.
#
# All functions are POSIX sh: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
# This library does NOT enable `set -eu`. It logs to STDERR only and records NO secrets and NO
# local key paths.
#
# Requires scripts/lib/sentinel-shield-common.sh (log_*) to be sourced first, and git.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_SOURCE_VERIFICATION_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_SOURCE_VERIFICATION_LOADED=1

# sv_is_hex40 <value> — return 0 iff <value> is EXACTLY 40 hexadecimal characters
# (upper or lower case). Empty or any non-hex character fails.
sv_is_hex40() {
	_sv_v=${1:-}
	case "$_sv_v" in
		"" | *[!0-9A-Fa-f]*) return 1 ;;
	esac
	[ "${#_sv_v}" -eq 40 ]
}

# sv_tree_checksum <repo_dir> — print the deterministic git TREE object id of HEAD
# (git rev-parse HEAD^{tree}). This is a content hash of the whole checked-out tree, stable
# across re-clones and independent of commit metadata. Returns 1 (prints nothing) on failure.
sv_tree_checksum() {
	command_exists git || { log_error "sv_tree_checksum: git is required"; return 1; }
	[ -d "${1:-}/.git" ] || { log_error "sv_tree_checksum: '$1' is not a git checkout"; return 1; }
	_sv_tree=$(git -C "$1" rev-parse 'HEAD^{tree}' 2>/dev/null) || {
		log_error "sv_tree_checksum: cannot resolve HEAD tree in '$1'"; return 1; }
	[ -n "$_sv_tree" ] || return 1
	printf '%s' "$_sv_tree"
}

# sv_assert_commit <repo_dir> <expected_commit> — INDEPENDENT commit-identity assertion.
# Rejects a missing or non-40-hex expected value, then asserts the checkout's HEAD commit
# (git rev-parse HEAD^{commit}) equals expected_commit. Returns 0 on match; non-zero (logging
# to STDERR) otherwise. Case-insensitive on the expected input.
sv_assert_commit() {
	command_exists git || { log_error "sv_assert_commit: git is required"; return 1; }
	[ -d "${1:-}/.git" ] || { log_error "sv_assert_commit: '$1' is not a git checkout"; return 1; }
	if ! sv_is_hex40 "${2:-}"; then
		log_error "sv_assert_commit: expected commit is missing or not a 40-hex SHA"
		return 1
	fi
	_sv_exp=$(printf '%s' "$2" | tr 'A-F' 'a-f')
	_sv_head=$(git -C "$1" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || {
		log_error "sv_assert_commit: cannot resolve HEAD commit in '$1'"; return 1; }
	if [ "$_sv_head" != "$_sv_exp" ]; then
		log_error "sv_assert_commit: HEAD commit ($_sv_head) != expected commit ($_sv_exp)"
		return 1
	fi
	return 0
}

# sv_ref_is_annotated_tag <repo_dir> <ref> — return 0 iff <ref> names an ANNOTATED tag object
# present in the checkout (a lightweight tag or an absent ref returns non-zero).
sv_ref_is_annotated_tag() {
	command_exists git || return 1
	_sv_t=$(git -C "$1" cat-file -t "refs/tags/$2" 2>/dev/null || true)
	[ "$_sv_t" = "tag" ]
}

# sv_tag_object <repo_dir> <ref> — print the annotated tag OBJECT id (refs/tags/<ref>), or nothing.
sv_tag_object() {
	git -C "$1" rev-parse --verify --quiet "refs/tags/$2" 2>/dev/null || true
}

# sv_tag_peeled_commit <repo_dir> <ref> — print the COMMIT the tag peels to (refs/tags/<ref>^{commit}).
sv_tag_peeled_commit() {
	git -C "$1" rev-parse --verify --quiet "refs/tags/$2^{commit}" 2>/dev/null || true
}

# sv_signature_mechanism <repo_dir> <ref> — best-effort classification of the signature
# mechanism git used to verify the tag: 'gpg', 'ssh', or 'unknown'. Derived from the STATUS
# lines of `git verify-tag --raw` (GPG emits [GNUPG:] GOODSIG/VALIDSIG). The raw output is
# classified only — it is NEVER echoed — so no signer identity or local key path can leak.
sv_signature_mechanism() {
	command_exists git || { printf 'unknown'; return 0; }
	_sv_raw=$(git -C "$1" verify-tag --raw "$2" 2>&1 || true)
	case "$_sv_raw" in
		*GNUPG:* | *GOODSIG* | *VALIDSIG* | *EXPKEYSIG* | *BADSIG*) printf 'gpg' ;;
		*'Good "'* | *ssh* | *SSH*) printf 'ssh' ;;
		*) printf 'unknown' ;;
	esac
	unset _sv_raw 2>/dev/null || true
}

# sv_verify_signature <repo_dir> <ref> <expected_commit> — verify a SIGNED annotated tag and
# confirm it PEELS to <expected_commit>. `git verify-tag` validates GPG *or* SSH signatures
# according to the repository/user Git configuration (gpg.format / verifying keyring or
# allowedSignersFile); it is NOT restricted to GnuPG. Returns 0 ONLY when git confirms a good
# signature AND the signed tag targets the expected commit. Returns non-zero when the ref is
# not an annotated tag (lightweight/absent), when the tag is unsigned or the signature is
# bad/unverifiable, or when the signed tag targets a DIFFERENT commit — i.e. it FAILS CLOSED,
# and a good signature can never bypass commit identity. Logs the tag object id, peeled commit,
# and (where determinable) the mechanism to STDERR; it NEVER logs a signer identity or key path.
sv_verify_signature() {
	command_exists git || { log_error "sv_verify_signature: git is required"; return 1; }
	sv_ref_is_annotated_tag "$1" "$2" || {
		log_error "sv_verify_signature: '$2' is not an annotated tag in the checkout (lightweight, unsigned-as-such, or absent refs cannot be signature-verified)"; return 1; }
	_sv_tagobj=$(sv_tag_object "$1" "$2")
	_sv_peeled=$(sv_tag_peeled_commit "$1" "$2")
	# BOUNDED where bounded-process is available: a wedged gpg-agent/ssh signing helper can make
	# `git verify-tag` hang forever, stalling acquire/verify. Cap it via the git-verify category
	# (a timeout is non-zero rc -> treated as no-good-signature, i.e. fail closed). When the
	# bounded-process lib is not sourced, fall back to a direct call (contract unchanged).
	if command -v bp_run >/dev/null 2>&1; then
		_sv_vto=$(bp_timeout git-verify 2>/dev/null) || _sv_vto=60
		_sv_vout=$(mktemp); _sv_verr=$(mktemp)
		bp_run git-verify "$_sv_vto" "$_sv_vout" "$_sv_verr" -- git -C "$1" verify-tag "$2"
		_sv_vrc=$?
		rm -f "$_sv_vout" "$_sv_verr"
		unset _sv_vto _sv_vout _sv_verr
	else
		git -C "$1" verify-tag "$2" >/dev/null 2>&1
		_sv_vrc=$?
	fi
	if [ "$_sv_vrc" -ne 0 ]; then
		log_error "sv_verify_signature: no good signature for annotated tag '$2' (unsigned, bad signature, unverifiable, or verification timed out) [tag_object=${_sv_tagobj:-unknown} peeled_commit=${_sv_peeled:-unknown}]"
		unset _sv_vrc
		return 1
	fi
	unset _sv_vrc
	# The signature is good; it MUST also target the expected commit (identity is never bypassed).
	if [ -n "${3:-}" ]; then
		if ! sv_is_hex40 "$3"; then
			log_error "sv_verify_signature: expected commit is not a 40-hex SHA"
			return 1
		fi
		_sv_exp=$(printf '%s' "$3" | tr 'A-F' 'a-f')
		if [ "$_sv_peeled" != "$_sv_exp" ]; then
			log_error "sv_verify_signature: signed tag '$2' targets commit ${_sv_peeled:-unknown} but expected $_sv_exp — commit-identity mismatch (fail closed)"
			return 1
		fi
	fi
	_sv_mech=$(sv_signature_mechanism "$1" "$2")
	log_info "source-verification: good ${_sv_mech} signature on annotated tag '$2' (tag_object=${_sv_tagobj:-unknown} peeled_commit=${_sv_peeled:-unknown})"
	return 0
}

# sv_verify <repo_dir> <ref> <expected_commit> <mode> [expected_tree] — run the requested
# verification(s) and, on success, print the NORMALIZED method actually applied (for recording).
# <mode> is one of: tree-record | tree-checksum | signature | tree-checksum+signature
#   (deprecated alias: checksum -> tree-record).
# Return codes: 0 success (prints method); 1 a requested check FAILED / could not be performed
# (fail closed, prints nothing); 2 invalid invocation (unknown mode, or tree-checksum requested
# without a valid expected tree). EVERY mode first asserts HEAD == expected_commit.
sv_verify() {
	_sv_dir="$1"; _sv_ref="$2"; _sv_expected="$3"; _sv_mode="$4"; _sv_exptree="${5:-}"
	case "$_sv_mode" in
		checksum) _sv_mode="tree-record" ;; # deprecated compatibility alias (record-only)
	esac
	case "$_sv_mode" in
		tree-record | tree-checksum | signature | tree-checksum+signature) ;;
		*) log_error "sv_verify: invalid mode '$4' (tree-record|tree-checksum|signature|tree-checksum+signature)"; return 2 ;;
	esac

	# (0) INDEPENDENT commit-identity assertion — ALWAYS, before any tree/signature check.
	sv_assert_commit "$_sv_dir" "$_sv_expected" || {
		log_error "sv_verify: commit-identity assertion failed (fail closed)"; return 1; }

	_sv_applied=""
	case "$_sv_mode" in
		tree-record)
			_sv_ck=$(sv_tree_checksum "$_sv_dir") || { log_error "sv_verify: cannot record HEAD tree"; return 1; }
			log_info "source-verification: RECORDED HEAD tree (tree-record; NOT compared to any expectation) = $_sv_ck"
			_sv_applied="tree-record"
			;;
		tree-checksum | tree-checksum+signature)
			if ! sv_is_hex40 "$_sv_exptree"; then
				log_error "sv_verify: tree-checksum mode REQUIRES a 40-hex expected tree id (none/invalid supplied)"
				return 2
			fi
			_sv_expl=$(printf '%s' "$_sv_exptree" | tr 'A-F' 'a-f')
			_sv_ck=$(sv_tree_checksum "$_sv_dir") || { log_error "sv_verify: cannot compute HEAD tree"; return 1; }
			if [ "$_sv_ck" != "$_sv_expl" ]; then
				log_error "sv_verify: tree-checksum MISMATCH (expected $_sv_expl, calculated $_sv_ck) — fail closed"
				return 1
			fi
			log_info "source-verification: tree-checksum MATCH (expected == calculated == $_sv_ck)"
			_sv_applied="tree-checksum"
			;;
	esac
	case "$_sv_mode" in
		*signature*)
			sv_verify_signature "$_sv_dir" "$_sv_ref" "$_sv_expected" || {
				log_error "sv_verify: signature verification failed (fail closed)"; return 1; }
			if [ -n "$_sv_applied" ]; then
				_sv_applied="$_sv_applied+signature"
			else
				_sv_applied="signature"
			fi
			;;
	esac
	printf '%s' "$_sv_applied"
	return 0
}
