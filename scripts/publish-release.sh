#!/bin/sh
# Sentinel Shield — one-command release publisher.
#
# HUMAN-RUN ONLY — this is the deliberate signing airlock. It creates and pushes a
# GPG/SSH-SIGNED tag with YOUR key and publishes the GitHub Release. The engine's other
# release tools never do this (they verify evidence and PRINT the commands); this one
# executes that manual sequence for a release owner running it interactively on their own
# machine. It weakens no gate — it re-runs verify-candidate (must be READY), requires a
# configured signing key, and requires an authorization record — then performs the publish.
#
# Prerequisite: the release's candidate + evidence are already prepared (scripts/prepare-release.sh)
# and merged to the default branch, and docs/<tag>-release-notes.md exists.
#
# Usage:
#   publish-release.sh --version X.Y.Z [--sole-maintainer-waive] [--yes] [--remote origin]
#
#   --version                 the release to publish (e.g. 2.2.0)
#   --sole-maintainer-waive   record the documented sole-maintainer authorization waiver
#                             (waived_by = your git identity) when no authorization record
#                             exists — with a single maintainer the two-person control is
#                             structurally unsatisfiable. Omit to require a pre-existing record.
#   --yes                     skip the interactive confirmation
#   --remote                  git remote to push to (default: origin)
#
# Exit: 0 published (or already published); 1 a gate/precondition failed; 2 invalid invocation.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT"

VERSION=""; WAIVE=0; ASSUME_YES=0; REMOTE="origin"
usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '[publish-release] ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
say() { printf '[publish-release] %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--sole-maintainer-waive) WAIVE=1; shift ;;
		--yes) ASSUME_YES=1; shift ;;
		--remote) REMOTE="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" 2 ;;
	esac
done
[ -n "$VERSION" ] || die "--version X.Y.Z is required" 2
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required and must be authenticated"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

EVID="evidence/releases"
CANDIDATE="$EVID/v$VERSION-ga-candidate.json"
MANIFEST="evidence/manifests/v$VERSION-ga.manifest.json"
ARTIFACTS="$EVID/v$VERSION-ga-artifacts.json"
WAIVER="$EVID/v$VERSION-authorization-waiver.json"
NOTES="docs/v$VERSION-release-notes.md"

[ -f "$CANDIDATE" ] || die "candidate not found: $CANDIDATE — run scripts/prepare-release.sh and merge its evidence first"
[ -f "$NOTES" ] || die "release notes not found: $NOTES"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

SRC=$(jq -r '.source_commit' "$CANDIDATE")
TAG=$(jq -r '.tag' "$CANDIDATE")
STAGE=$(jq -r '.stage' "$CANDIDATE")
SCOPE=$(jq -r '.release_scope' "$CANDIDATE")
case "$SRC" in *[!0-9a-f]* | "") die "candidate source_commit is not a 40-hex sha: '$SRC'" ;; esac
[ "${#SRC}" -eq 40 ] || die "candidate source_commit must be a full 40-hex sha"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || jq -r '.repository // empty' config/release-required-workflows.json)

# --- precondition: a signing key must be configured (we will NOT publish unsigned) -----
if [ -z "$(git config --get user.signingkey 2>/dev/null || true)" ]; then
	die "no git signing key configured (git config user.signingkey). A release tag MUST be signed."
fi

# --- gate: candidate must be verify-candidate READY ------------------------------------
say "verifying candidate is READY (re-deriving every GA gate)..."
sh "$SCRIPT_DIR/authorize-production-release.sh" verify-candidate \
	--candidate "$CANDIDATE" --source-commit "$SRC" >/dev/null \
	|| die "verify-candidate did NOT return READY — refusing to publish (fail closed)"
say "candidate READY."

# --- authorization: DECIDE now (read-only); RECORD only after confirmation -------------
AUTH_PLAN=""
if [ -f "$WAIVER" ]; then
	AUTH_PLAN="use existing authorization record ($WAIVER)"
elif [ "$WAIVE" -eq 1 ]; then
	AUTH_PLAN="record a NEW sole-maintainer authorization waiver ($WAIVER)"
else
	die "no authorization record ($WAIVER). Create a two-person authorization, or pass --sole-maintainer-waive."
fi

# --- confirmation (BEFORE any git mutation) --------------------------------------------
KIND="--latest"; PRE=""
case "$TAG" in *-rc* | *-beta* | *-alpha*) KIND=""; PRE="--prerelease" ;; esac
TITLE=$(head -1 "$NOTES" | sed 's/^#\{1,\} *//')
[ -n "$TITLE" ] || TITLE="Sentinel Shield $TAG"
cat >&2 <<EOF

  Publish plan
  ------------
  version       : $VERSION   (stage=$STAGE scope=$SCOPE)
  tag           : $TAG  ->  $SRC  (SSH-signed with your key)
  repository    : $REPO
  release title : $TITLE
  notes         : $NOTES
  authorization : $AUTH_PLAN
EOF
if [ "$ASSUME_YES" -ne 1 ]; then
	printf '\n  Proceed? type "yes" to sign, push, and publish: ' >&2
	read -r _ans
	[ "$_ans" = "yes" ] || die "aborted by user (nothing changed)"
fi

# --- record the sole-maintainer waiver (only if we decided to, post-confirmation) ------
if [ ! -f "$WAIVER" ]; then
	_hash=$(jq -r '.reproducibility.hash' "$MANIFEST")
	_who=$(git config --get user.email 2>/dev/null || git config --get user.name 2>/dev/null || echo "release-owner")
	_today=$(date -u +%Y-%m-%d)
	say "recording sole-maintainer authorization waiver (waived_by=$_who)..."
	jq -n --arg v "$VERSION" --arg stage "$STAGE" --arg scope "$SCOPE" --arg src "$SRC" \
		--arg tag "$TAG" --arg hash "$_hash" --arg who "$_who" --arg day "$_today" '{
		schema_version: "1", kind: "release-authorization-waiver",
		version: $v, stage: $stage, release_scope: $scope, source_commit: $src, tag: $tag,
		candidate_hash: $hash, control_waived: "two-person-authorization", waived: true,
		waived_by: $who, waived_on: $day, published_on: $day,
		tag_signed: true, tag_signature_method: "ssh",
		rationale: "Single-maintainer repository: the two-person requested_by != approved_by control is structurally unsatisfiable and must not be met by fabricating a second identity. The release owner waived ONLY that identity control for this candidate and signed the tag at the CI-proven source commit directly. See docs/release-authorization-policy.md.",
		scope_of_waiver: "two-person identity control ONLY; no other release gate is waived"
	}' > "$WAIVER"
	git add "$WAIVER"
	git commit -q -m "release(v$VERSION): sole-maintainer authorization waiver"
	git push "$REMOTE" HEAD 2>/dev/null || say "note: push the waiver commit to the default branch when convenient"
fi

# --- create + verify + push the signed tag ---------------------------------------------
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
	_have=$(git rev-list -n1 "$TAG")
	[ "$_have" = "$SRC" ] || die "tag $TAG already exists but points to $_have, not $SRC — refusing"
	say "tag $TAG already exists locally at the correct commit; not re-creating."
else
	say "creating SSH-signed tag $TAG at $SRC..."
	git tag -s "$TAG" "$SRC" -m "$TITLE"
fi
say "verifying tag signature + target..."
git verify-tag "$TAG" >/dev/null 2>&1 || die "tag $TAG signature does NOT verify (e.g. a prior signing attempt failed) — refusing to push. Delete the local tag and re-run: git tag -d $TAG && sh scripts/publish-release.sh --version $VERSION"
[ "$(git rev-list -n1 "$TAG")" = "$SRC" ] || die "tag $TAG does not peel to $SRC"
say "pushing tag $TAG to $REMOTE..."
git push "$REMOTE" "refs/tags/$TAG"

# --- create the GitHub Release (idempotent) --------------------------------------------
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	say "GitHub Release $TAG already exists; leaving it as-is."
else
	say "creating GitHub Release $TAG..."
	# shellcheck disable=SC2086
	gh release create "$TAG" --repo "$REPO" --verify-tag \
		--title "$TITLE" --notes-file "$NOTES" $KIND $PRE
fi

# --- post-publish verification ---------------------------------------------------------
say "post-publish verification..."
sh "$SCRIPT_DIR/verify-published-release.sh" verify-tag --repo-root "$ROOT" --tag "$TAG" --commit "$SRC"
sh "$SCRIPT_DIR/verify-published-release.sh" verify-github-release --tag "$TAG" --stage "$STAGE" \
	--repo "$REPO" --expected-commit "$SRC"
[ -f "$ARTIFACTS" ] && sh "$SCRIPT_DIR/verify-published-release.sh" smoke \
	--manifest "$MANIFEST" --artifacts "$ARTIFACTS" || true

say "PUBLISHED: $TAG — https://github.com/$REPO/releases/tag/$TAG"
