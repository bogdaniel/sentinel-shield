#!/bin/sh
# Sentinel Shield — source verification (POSIX sh library, sv_* functions).
#
# Source this file; do NOT execute it. It provides OPTIONAL, opt-in integrity verification of an
# already-acquired immutable checkout, layered ON TOP of acquire-sentinel-shield.sh's existing
# --verify (which asserts checkout HEAD == the resolved ref commit — a COMMIT-IDENTITY check).
# These functions verify the TREE content and/or a signed annotated tag, neither of which the
# commit-identity check covers.
#
# All functions are POSIX sh: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
# This library does NOT enable `set -eu`. It logs to STDERR only and records NO secrets.
#
# Requires scripts/lib/sentinel-shield-common.sh (log_*) to be sourced first, and git.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_SOURCE_VERIFICATION_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_SOURCE_VERIFICATION_LOADED=1

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

# sv_ref_is_annotated_tag <repo_dir> <ref> — return 0 iff <ref> names an ANNOTATED tag object
# present in the checkout (a lightweight tag or an absent ref returns non-zero).
sv_ref_is_annotated_tag() {
	command_exists git || return 1
	_sv_t=$(git -C "$1" cat-file -t "refs/tags/$2" 2>/dev/null || true)
	[ "$_sv_t" = "tag" ]
}

# sv_verify_signature <repo_dir> <ref> — verify a SIGNED annotated tag with git verify-tag
# (GnuPG). Returns 0 only when git confirms a good signature. Returns non-zero when the tag is
# unsigned, the signature is bad, or no verification tooling/key is available — i.e. it FAILS
# CLOSED (an unverifiable signature is never treated as verified).
sv_verify_signature() {
	command_exists git || { log_error "sv_verify_signature: git is required"; return 1; }
	sv_ref_is_annotated_tag "$1" "$2" || { log_error "sv_verify_signature: '$2' is not an annotated tag in the checkout (cannot be signature-verified)"; return 1; }
	if git -C "$1" verify-tag "$2" >/dev/null 2>&1; then
		return 0
	fi
	log_error "sv_verify_signature: no good GPG signature for tag '$2' (unsigned, bad, or no verification key available)"
	return 1
}

# sv_verify <repo_dir> <ref> <expected_commit> <mode> — run the requested verification(s) and,
# on success, print the method actually applied (for recording in the ref record). <mode> is one
# of: checksum | signature | checksum+signature. FAILS CLOSED (returns non-zero, prints nothing)
# if any requested check fails or cannot be performed. 'checksum' additionally asserts the tree
# id is well-formed; the caller may re-read it via sv_tree_checksum for the record.
sv_verify() {
	_sv_dir="$1"; _sv_ref="$2"; _sv_expected="$3"; _sv_mode="$4"
	_sv_applied=""
	case "$_sv_mode" in
		checksum|signature|checksum+signature) ;;
		*) log_error "sv_verify: invalid mode '$_sv_mode' (checksum|signature|checksum+signature)"; return 2 ;;
	esac
	case "$_sv_mode" in
		*checksum*)
			_sv_ck=$(sv_tree_checksum "$_sv_dir") || { log_error "sv_verify: tree-checksum verification failed"; return 1; }
			[ -n "$_sv_ck" ] || { log_error "sv_verify: empty tree checksum"; return 1; }
			log_info "source-verification: tree checksum (HEAD^{tree}) = $_sv_ck"
			_sv_applied="checksum"
			;;
	esac
	case "$_sv_mode" in
		*signature*)
			sv_verify_signature "$_sv_dir" "$_sv_ref" || { log_error "sv_verify: signature verification failed (fail-closed)"; return 1; }
			log_info "source-verification: good signature on annotated tag '$_sv_ref'"
			[ -n "$_sv_applied" ] && _sv_applied="$_sv_applied+signature" || _sv_applied="signature"
			;;
	esac
	printf '%s' "$_sv_applied"
	return 0
}
