#!/bin/sh
# Sentinel Shield — generate-release-manifest: a canonical, reproducible release
# fingerprint (Task 06.3).
#
# Emits a release manifest (schemas/release-manifest.schema.json) that fingerprints
# exactly WHAT a release ships: source commit + git tree hash, tag target, release
# scope, CI workflow runs, verified artifact digests, workflow action pins, tool
# versions, and profile-policy + schema digests. The document splits a HASHED `body`
# (reproducible content) from a NON-hashed `metadata` section (generated_at, generator)
# so timestamps never perturb the reproducibility hash. reproducibility.hash is the
# SHA-256 of the canonical serialization of `body` (jq -S -c: recursively key-sorted,
# compact). Regenerating from the same repository state yields an IDENTICAL hash.
#
# `--body-only` prints just the canonical body (used by verify-release-manifest.sh to
# reconstruct and compare); the default prints the full manifest.
#
# Usage:
#   generate-release-manifest.sh --evidence <file> [--repo-root <dir>]
#       [--artifacts <verify-report.json>] [--source-commit <40hex>]
#       [--tree-hash <40hex>] [--tag-target <40hex>] [--body-only] [--output <path>]
#
# Exit: 0 ok; 2 invalid invocation / malformed input; 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	printf 'Usage: generate-release-manifest.sh --evidence <file> [--repo-root <dir>] [--artifacts <verify-report.json>] [--source-commit <40hex>] [--tree-hash <40hex>] [--tag-target <40hex>] [--body-only] [--output <path>]\n'
}

EVIDENCE=""
ROOTDIR="$REPO_ROOT"
ARTIFACTS=""
SRC_OVERRIDE=""
TREE_OVERRIDE=""
TAG_OVERRIDE=""
BODY_ONLY=0
OUTPUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--evidence) EVIDENCE="${2:?--evidence requires a value}"; shift 2 ;;
		--repo-root) ROOTDIR="${2:?--repo-root requires a value}"; shift 2 ;;
		--artifacts) ARTIFACTS="${2:?--artifacts requires a value}"; shift 2 ;;
		--source-commit) SRC_OVERRIDE="${2:?--source-commit requires a value}"; shift 2 ;;
		--tree-hash) TREE_OVERRIDE="${2:?--tree-hash requires a value}"; shift 2 ;;
		--tag-target) TAG_OVERRIDE="${2:?--tag-target requires a value}"; shift 2 ;;
		--body-only) BODY_ONLY=1; shift ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
ss_have_sha256 || { log_error "a SHA-256 tool (sha256sum or shasum) is required"; exit 3; }
[ -n "$EVIDENCE" ] || { log_error "--evidence is required"; usage >&2; exit 2; }
[ -f "$EVIDENCE" ] || { log_error "evidence file not found: $EVIDENCE"; exit 2; }
jq -e . "$EVIDENCE" >/dev/null 2>&1 || { log_error "evidence is not valid JSON: $EVIDENCE"; exit 2; }
[ -d "$ROOTDIR" ] || { log_error "--repo-root not a directory: $ROOTDIR"; exit 2; }
if [ -n "$ARTIFACTS" ]; then
	[ -f "$ARTIFACTS" ] || { log_error "artifacts report not found: $ARTIFACTS"; exit 2; }
	jq -e . "$ARTIFACTS" >/dev/null 2>&1 || { log_error "artifacts report is not valid JSON: $ARTIFACTS"; exit 2; }
fi

# --- resolve core identity ---------------------------------------------------
VERSION=$(jq -r '.version // ""' "$EVIDENCE")
STAGE=$(jq -r '.stage // ""' "$EVIDENCE")
SCOPE=$(jq -r '.release_scope // "framework-validated"' "$EVIDENCE")
SOURCE_COMMIT="${SRC_OVERRIDE:-$(jq -r '.engine_commit // "unknown"' "$EVIDENCE")}"
TAG_TARGET="$TAG_OVERRIDE"
[ -n "$TAG_TARGET" ] || TAG_TARGET=$(jq -r '.release_commit // .engine_commit // "unknown"' "$EVIDENCE")

# tree_hash: explicit override, else derive from git when the commit is resolvable,
# else 'unknown' (fail soft: an unresolved tree hash is recorded honestly).
TREE_HASH="$TREE_OVERRIDE"
if [ -z "$TREE_HASH" ]; then
	if [ "$SOURCE_COMMIT" != unknown ] && command_exists git && git -C "$ROOTDIR" rev-parse --git-dir >/dev/null 2>&1; then
		TREE_HASH=$(git -C "$ROOTDIR" rev-parse "$SOURCE_COMMIT^{tree}" 2>/dev/null || printf 'unknown')
	else
		TREE_HASH=unknown
	fi
fi
case "$TREE_HASH" in ''|*[!0-9a-f]*) TREE_HASH=unknown ;; *) [ "${#TREE_HASH}" = 40 ] || TREE_HASH=unknown ;; esac

# --- workflow_runs (from evidence.engine_ci), sorted by run_id ---------------
WORKFLOW_RUNS=$(jq -c '
	[ (.engine_ci // [])[] | { workflow_name, run_id: .workflow_run_id, commit, result } ]
	| sort_by(.run_id | tostring)' "$EVIDENCE")

# --- artifact_digests (from a verify-release-artifacts report), sorted -------
if [ -n "$ARTIFACTS" ]; then
	ARTIFACT_DIGESTS=$(jq -c '
		[ (.artifacts // [])[]
		  | select((.sha256 // "") | test("^[0-9a-f]{64}$"))
		  | { run_id, artifact_id, name, sha256 } ]
		| sort_by([ (.run_id|tostring), (.artifact_id|tostring) ])' "$ARTIFACTS")
else
	ARTIFACT_DIGESTS="[]"
fi

# --- action_pins: every `uses:` ref across engine CI + templates, sorted -----
ACTION_PINS="[]"
_pin_lines=$(
	for _d in "$ROOTDIR/.github/workflows" "$ROOTDIR/templates/workflows"; do
		[ -d "$_d" ] || continue
		find "$_d" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
			_rel=${_f#"$ROOTDIR"/}
			grep -nE '^[[:space:]]*uses:[[:space:]]' "$_f" 2>/dev/null \
				| sed -E 's/^[0-9]+:[[:space:]]*uses:[[:space:]]*//; s/[[:space:]].*$//; s/^["'\'']//; s/["'\'']$//' \
				| while IFS= read -r _ref; do
					[ -n "$_ref" ] || continue
					printf '%s\t%s\n' "$_rel" "$_ref"
				done
		done
	done
)
if [ -n "$_pin_lines" ]; then
	ACTION_PINS=$(printf '%s\n' "$_pin_lines" | LC_ALL=C sort -u | jq -R 'split("\t") | { source: .[0], uses: .[1] }' | jq -sc 'sort_by([.source, .uses])')
fi

# --- digest helper: emit sorted [{path,sha256}] for a set of files -----------
# digest_set <glob-root> <find-args...> — prints a compact JSON array.
digest_paths() { # digest_paths <newline-separated relative paths>
	_dp_in="$1"
	if [ -z "$_dp_in" ]; then printf '[]'; return; fi
	printf '%s\n' "$_dp_in" | LC_ALL=C sort | while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_abs="$ROOTDIR/$_rel"
		[ -f "$_abs" ] || continue
		_sha=$(ss_sha256_file "$_abs" || printf 'unknown')
		jq -n --arg p "$_rel" --arg s "$_sha" '{path:$p, sha256:$s}'
	done | jq -sc 'sort_by(.path)'
}

# profile-policy digests: every shipped profile.manifest.json.
_profile_rel=$(
	if [ -d "$ROOTDIR/profiles" ]; then
		( cd "$ROOTDIR" && find profiles -type f -name 'profile.manifest.json' 2>/dev/null )
	fi
)
PROFILE_DIGESTS=$(digest_paths "$_profile_rel")

# schema digests: every shipped schemas/*.json.
_schema_rel=$(
	if [ -d "$ROOTDIR/schemas" ]; then
		( cd "$ROOTDIR" && find schemas -maxdepth 1 -type f -name '*.json' 2>/dev/null )
	fi
)
SCHEMA_DIGESTS=$(digest_paths "$_schema_rel")

# --- tool_versions (part of the provenance fingerprint) ----------------------
TOOL_VERSIONS=$(
	_jqv=$(jq --version 2>/dev/null || printf 'unknown')
	_ghv="null"; command_exists "${GH_BIN:-gh}" && _ghv=$("${GH_BIN:-gh}" --version 2>/dev/null | head -n1)
	_yqv="null"; command_exists yq && _yqv=$(yq --version 2>/dev/null | head -n1)
	jq -n --arg jq "$_jqv" --arg gh "$_ghv" --arg yq "$_yqv" '
		{ jq: $jq }
		+ (if $gh == "null" or $gh == "" then {} else { gh: $gh } end)
		+ (if $yq == "null" or $yq == "" then {} else { yq: $yq } end)')

# --- assemble canonical body -------------------------------------------------
BODY=$(jq -n \
	--arg version "$VERSION" --arg stage "$STAGE" --arg scope "$SCOPE" \
	--arg source_commit "$SOURCE_COMMIT" --arg tree_hash "$TREE_HASH" --arg tag_target "$TAG_TARGET" \
	--argjson workflow_runs "$WORKFLOW_RUNS" --argjson artifact_digests "$ARTIFACT_DIGESTS" \
	--argjson action_pins "$ACTION_PINS" --argjson tool_versions "$TOOL_VERSIONS" \
	--argjson profile_policy_digests "$PROFILE_DIGESTS" --argjson schema_digests "$SCHEMA_DIGESTS" '
	{ version: $version, stage: $stage, release_scope: $scope,
	  source_commit: $source_commit, tree_hash: $tree_hash, tag_target: $tag_target,
	  workflow_runs: $workflow_runs, artifact_digests: $artifact_digests,
	  action_pins: $action_pins, tool_versions: $tool_versions,
	  profile_policy_digests: $profile_policy_digests, schema_digests: $schema_digests }')

# Canonical serialization: recursively key-sorted, compact.
CANON=$(printf '%s' "$BODY" | jq -S -c .)
HASH=$(printf '%s' "$CANON" | ss_sha256_stdin)

if [ "$BODY_ONLY" = 1 ]; then
	# The canonical body is the exact string that is hashed.
	if [ -n "$OUTPUT" ]; then printf '%s\n' "$CANON" > "$OUTPUT"; else printf '%s\n' "$CANON"; fi
	exit 0
fi

MANIFEST=$(jq -n \
	--argjson body "$CANON" --arg hash "$HASH" \
	--arg at "$(timestamp_utc)" --arg gen "generate-release-manifest.sh" '
	{ schema_version: "1",
	  metadata: { generated_at: $at, generator: $gen },
	  body: $body,
	  reproducibility: { hash_algorithm: "sha256", canonicalization: "jq -S -c over .body", hash: $hash } }')

if [ -n "$OUTPUT" ]; then printf '%s\n' "$MANIFEST" > "$OUTPUT"; else printf '%s\n' "$MANIFEST"; fi
log_info "release manifest generated (body sha256=$HASH)"
exit 0
