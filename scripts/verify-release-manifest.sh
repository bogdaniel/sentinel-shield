#!/bin/sh
# Sentinel Shield — verify-release-manifest: prove a release manifest is intact and,
# optionally, that it still matches the repository state (Task 06.3).
#
# Two independent checks:
#   1. SELF-CONSISTENCY (always): recompute the SHA-256 over the manifest's OWN
#      canonicalized body (jq -S -c) and require it to equal the stored
#      reproducibility.hash. This detects any tamper to `body` that did not also
#      forge the hash.
#   2. RECONSTRUCTION (when --evidence is given): regenerate the canonical body from
#      the same inputs via generate-release-manifest.sh --body-only and require both
#      the reconstructed hash AND the reconstructed body to equal the manifest's.
#      This detects drift between the manifest and the actual repo/evidence state.
#
# Usage:
#   verify-release-manifest.sh --manifest <file>
#       [--evidence <file>] [--repo-root <dir>] [--artifacts <verify-report.json>]
#       [--source-commit <40hex>] [--tree-hash <40hex>] [--tag-target <40hex>]
#
# Exit: 0 verified; 1 tamper/drift detected; 2 malformed/invalid; 3 tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
GENERATOR="$SCRIPT_DIR/generate-release-manifest.sh"

usage() {
	printf 'Usage: verify-release-manifest.sh --manifest <file> [--evidence <file>] [--repo-root <dir>] [--artifacts <verify-report.json>] [--source-commit <40hex>] [--tree-hash <40hex>] [--tag-target <40hex>]\n'
}

MANIFEST=""
EVIDENCE=""
ROOTDIR=""
ARTIFACTS=""
SRC_OVERRIDE=""
TREE_OVERRIDE=""
TAG_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
		--evidence) EVIDENCE="${2:?--evidence requires a value}"; shift 2 ;;
		--repo-root) ROOTDIR="${2:?--repo-root requires a value}"; shift 2 ;;
		--artifacts) ARTIFACTS="${2:?--artifacts requires a value}"; shift 2 ;;
		--source-commit) SRC_OVERRIDE="${2:?--source-commit requires a value}"; shift 2 ;;
		--tree-hash) TREE_OVERRIDE="${2:?--tree-hash requires a value}"; shift 2 ;;
		--tag-target) TAG_OVERRIDE="${2:?--tag-target requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
ss_have_sha256 || { log_error "a SHA-256 tool (sha256sum or shasum) is required"; exit 3; }
[ -n "$MANIFEST" ] || { log_error "--manifest is required"; usage >&2; exit 2; }
[ -f "$MANIFEST" ] || { log_error "manifest file not found: $MANIFEST"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "manifest is not valid JSON: $MANIFEST"; exit 2; }

# Structural sanity: the fields we depend on must exist.
STORED_HASH=$(jq -r '.reproducibility.hash // ""' "$MANIFEST")
printf '%s' "$STORED_HASH" | grep -Eq '^[0-9a-f]{64}$' || { log_error "manifest reproducibility.hash missing or malformed"; exit 2; }
jq -e '.body | type == "object"' "$MANIFEST" >/dev/null 2>&1 || { log_error "manifest body missing or not an object"; exit 2; }

# --- (1) self-consistency ----------------------------------------------------
OWN_CANON=$(jq -c -S '.body' "$MANIFEST")
OWN_HASH=$(printf '%s' "$OWN_CANON" | ss_sha256_stdin)
if [ "$OWN_HASH" != "$STORED_HASH" ]; then
	log_error "manifest SELF-CONSISTENCY FAILED: body hashes to $OWN_HASH but reproducibility.hash claims $STORED_HASH (body was tampered)"
	exit 1
fi
log_info "manifest self-consistency OK (body sha256=$OWN_HASH)"

# --- (2) reconstruction (optional) -------------------------------------------
if [ -n "$EVIDENCE" ]; then
	[ -f "$GENERATOR" ] || { log_error "generator not found: $GENERATOR"; exit 2; }
	set -- --evidence "$EVIDENCE" --body-only
	[ -n "$ROOTDIR" ] && set -- "$@" --repo-root "$ROOTDIR"
	[ -n "$ARTIFACTS" ] && set -- "$@" --artifacts "$ARTIFACTS"
	[ -n "$SRC_OVERRIDE" ] && set -- "$@" --source-commit "$SRC_OVERRIDE"
	[ -n "$TREE_OVERRIDE" ] && set -- "$@" --tree-hash "$TREE_OVERRIDE"
	[ -n "$TAG_OVERRIDE" ] && set -- "$@" --tag-target "$TAG_OVERRIDE"
	_recon=$(sh "$GENERATOR" "$@") || { log_error "reconstruction failed (generator error)"; exit 2; }
	_recon_canon=$(printf '%s' "$_recon" | jq -c -S .)
	_recon_hash=$(printf '%s' "$_recon_canon" | ss_sha256_stdin)
	if [ "$_recon_hash" != "$STORED_HASH" ]; then
		log_error "manifest RECONSTRUCTION MISMATCH: repo/evidence state hashes to $_recon_hash but manifest records $STORED_HASH (the release changed since the manifest was generated)"
		# Show the first differing top-level field to aid triage.
		_diff=$(jq -n --argjson a "$OWN_CANON" --argjson b "$_recon_canon" '
			[ ($a | keys_unsorted[]) as $k | select(($a[$k]) != ($b[$k])) | $k ] | join(",")')
		[ -n "$_diff" ] && log_error "differing body fields: $_diff"
		exit 1
	fi
	log_info "manifest reconstruction OK: repo/evidence state reproduces the recorded hash"
fi

log_info "release manifest verified: $MANIFEST"
exit 0
