#!/bin/sh
# Sentinel Shield — finalize-release-evidence: decide and (only on explicit request)
# create the release TAG, using the two-commit model (Task 06.4).
#
# The release-evidence model separates the CI-validated SOURCE commit (engine_commit)
# from an optional later metadata-only RELEASE commit (release_commit) that carries the
# evidence — this breaks the circular self-reference of recording a commit's own CI
# evidence inside that same commit. Finalization is finite and non-circular: it reads
# the evidence, computes ONE tag target, verifies the target is legitimate, prints the
# exact target, and creates the tag ONLY when --execute is supplied.
#
# Modes:
#   --mode source-tag     Tag the CI-proven engine_commit directly (source == release).
#                         Target = engine_commit. No diff to verify.
#   --mode metadata-tag   Tag a later metadata-only release_commit. Target = release_commit.
#                         REQUIRES that release_commit is a DESCENDANT of engine_commit and
#                         that the diff engine_commit..release_commit changes ONLY approved
#                         release metadata (evidence/releases/*.json, CHANGELOG.md, release
#                         notes/evidence docs). ANY executable/schema/workflow/test/policy/
#                         profile change is a VIOLATION and is rejected.
#
# SAFETY: this never creates a tag unless --execute is passed. Without it, the tool is a
# read-only planner that prints the exact target it WOULD tag and exits 0.
#
# Usage:
#   finalize-release-evidence.sh --evidence <file> --mode <source-tag|metadata-tag>
#       --tag <name> [--repo-root <dir>] [--execute]
#
# Exit:
#   0 = target computed (and tag created when --execute); prints the exact target
#   1 = could not verify (unknown/unresolvable commit, or release_commit is not a
#       descendant of engine_commit) — fail closed
#   2 = invalid invocation OR metadata-only VIOLATION (a non-metadata file changed)
#   3 = required tool unavailable (git)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# Metadata allowlist — MUST match validate-release-evidence.sh verify_commit_binding
# (extension-anchored so a script dropped under evidence/releases/ or docs/ cannot pass).
META_ALLOW='^$|^evidence/releases/[^/]+\.json$|^CHANGELOG\.md$|^docs/[^/]*release-evidence[^/]*\.md$|^docs/[^/]*release-notes[^/]*\.md$|^docs/v2-merge-commit-ci-evidence[^/]*\.md$'

usage() {
	printf 'Usage: finalize-release-evidence.sh --evidence <file> --mode <source-tag|metadata-tag> --tag <name> [--repo-root <dir>] [--execute]\n'
}

EVIDENCE=""
MODE=""
TAG=""
ROOTDIR="$REPO_ROOT"
EXECUTE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--evidence) EVIDENCE="${2:?--evidence requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--tag) TAG="${2:?--tag requires a value}"; shift 2 ;;
		--repo-root) ROOTDIR="${2:?--repo-root requires a value}"; shift 2 ;;
		--execute) EXECUTE=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 2; }
[ -n "$EVIDENCE" ] || { log_error "--evidence is required"; usage >&2; exit 2; }
[ -f "$EVIDENCE" ] || { log_error "evidence file not found: $EVIDENCE"; exit 2; }
jq -e . "$EVIDENCE" >/dev/null 2>&1 || { log_error "evidence is not valid JSON: $EVIDENCE"; exit 2; }
[ -n "$TAG" ] || { log_error "--tag is required"; usage >&2; exit 2; }
case "$MODE" in source-tag | metadata-tag) ;; *) log_error "--mode must be source-tag or metadata-tag"; usage >&2; exit 2 ;; esac
command_exists git || { log_error "git is required but was not found"; exit 3; }
git -C "$ROOTDIR" rev-parse --git-dir >/dev/null 2>&1 || { log_error "--repo-root is not a git repository: $ROOTDIR"; exit 2; }

ENGINE_COMMIT=$(jq -r '.engine_commit // ""' "$EVIDENCE")
RELEASE_COMMIT=$(jq -r '.release_commit // ""' "$EVIDENCE")

# resolve_target — set TARGET and, for metadata-tag, verify the metadata-only diff.
# Returns via exit codes described above.
TARGET=""
if [ "$MODE" = source-tag ]; then
	[ "$ENGINE_COMMIT" != unknown ] && [ -n "$ENGINE_COMMIT" ] || {
		log_error "source-tag: engine_commit is unknown/empty — nothing proven to tag (fail closed)"; exit 1; }
	printf '%s' "$ENGINE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "source-tag: engine_commit is not a 40-hex SHA"; exit 1; }
	git -C "$ROOTDIR" rev-parse -q --verify "$ENGINE_COMMIT^{commit}" >/dev/null 2>&1 || {
		log_error "source-tag: engine_commit $ENGINE_COMMIT is not present in $ROOTDIR (fail closed)"; exit 1; }
	TARGET="$ENGINE_COMMIT"
	log_info "source-tag: target is the CI-validated engine_commit"
else
	# metadata-tag
	[ -n "$RELEASE_COMMIT" ] && [ "$RELEASE_COMMIT" != unknown ] || {
		log_error "metadata-tag: release_commit is absent/unknown — there is no metadata commit to tag (fail closed)"; exit 1; }
	printf '%s' "$RELEASE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "metadata-tag: release_commit is not a 40-hex SHA"; exit 1; }
	[ "$ENGINE_COMMIT" != unknown ] && [ -n "$ENGINE_COMMIT" ] || {
		log_error "metadata-tag: engine_commit is unknown — cannot prove a metadata-only diff (fail closed)"; exit 1; }
	printf '%s' "$ENGINE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
		log_error "metadata-tag: engine_commit is not a 40-hex SHA (both sides of the binding must be immutable commit IDs)"; exit 1; }
	for _c in "$ENGINE_COMMIT" "$RELEASE_COMMIT"; do
		git -C "$ROOTDIR" rev-parse -q --verify "$_c^{commit}" >/dev/null 2>&1 || {
			log_error "metadata-tag: commit $_c is not present in $ROOTDIR (fail closed)"; exit 1; }
	done
	if [ "$RELEASE_COMMIT" = "$ENGINE_COMMIT" ]; then
		log_info "metadata-tag: release_commit == engine_commit (no metadata diff)"
	else
		# release_commit must be a DESCENDANT of engine_commit (engine is its ancestor).
		git -C "$ROOTDIR" merge-base --is-ancestor "$ENGINE_COMMIT" "$RELEASE_COMMIT" 2>/dev/null || {
			log_error "metadata-tag: release_commit is NOT a descendant of engine_commit (must be ahead) — fail closed"; exit 1; }
		# The diff may change ONLY approved release metadata.
		_files=$(git -C "$ROOTDIR" diff --name-only "$ENGINE_COMMIT" "$RELEASE_COMMIT" 2>/dev/null) || {
			log_error "metadata-tag: could not diff engine_commit..release_commit (fail closed)"; exit 1; }
		_bad=$(printf '%s\n' "$_files" | grep -vE "$META_ALLOW" || true)
		if [ -n "$_bad" ]; then
			log_error "metadata-tag VIOLATION: the diff engine_commit..release_commit changes NON-metadata files (executable/script/workflow/schema/test/policy/profile are forbidden in a metadata commit):"
			printf '%s\n' "$_bad" | sed 's/^/  /' >&2
			exit 2
		fi
		log_info "metadata-tag: diff engine_commit..release_commit is metadata-only (approved)"
	fi
	TARGET="$RELEASE_COMMIT"
fi

# Refuse to clobber an existing tag.
if git -C "$ROOTDIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
	log_error "tag '$TAG' already exists in $ROOTDIR — refusing to overwrite"
	printf 'TAG TARGET: %s\n' "$TARGET"
	exit 2
fi

# Print the EXACT target unmistakably.
printf 'TAG TARGET: %s\n' "$TARGET"
printf 'TAG NAME:   %s\n' "$TAG"
printf 'MODE:       %s\n' "$MODE"

if [ "$EXECUTE" = 1 ]; then
	git -C "$ROOTDIR" tag "$TAG" "$TARGET" || { log_error "git tag failed"; exit 1; }
	log_info "created tag '$TAG' -> $TARGET"
	printf 'RESULT: created tag %s -> %s\n' "$TAG" "$TARGET"
else
	log_info "DRY-RUN: no tag created (pass --execute to create '$TAG' at $TARGET)"
	printf 'RESULT: dry-run (would create tag %s -> %s); re-run with --execute to create it\n' "$TAG" "$TARGET"
fi
exit 0
