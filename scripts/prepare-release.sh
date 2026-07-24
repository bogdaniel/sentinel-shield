#!/bin/sh
# Sentinel Shield — release-prep orchestrator (v2).
#
# ONE command runs the read-only, fail-closed evidence pipeline that a release owner
# otherwise hand-chains across eight generator/verifier scripts. It collects the engine
# CI evidence, verifies the CI artifacts, pulls the three CI-proven gate reports
# (security-acceptance / compatibility-matrix / adopter-scorecard) from the same green
# runs, builds the release manifest, generates the upgrade+rollback lifecycle reports,
# cross-checks manifest+evidence+readiness, prepares the release candidate, and finally
# runs `verify-candidate` — printing READY or BLOCKED.
#
# It is deliberately NON-destructive: it never creates/moves/deletes a tag, never pushes,
# and never publishes a GitHub Release. The signed-tag airlock stays human — when this
# prints READY, run `authorize-production-release.sh print-tag-commands` for the exact
# manual publish sequence. Every underlying script stays fail-closed; this is only the glue.
#
# Usage:
#   prepare-release.sh --version X.Y.Z --prev A.B.C
#       [--source-commit <40hex>]   (default: current origin/master tip)
#       [--tag vX.Y.Z]              (default: vX.Y.Z)
#       [--scope engine-only]       (default: engine-only)
#       [--stage ga]                (default: ga)
#       [--repo owner/name]         (default: .repository in the required-workflows config)
#       [--profile <name>]          (upgrade/rollback lifecycle profile; default: laravel)
#
# Requires: gh (authenticated), jq, git. All evidence lands under evidence/releases/ and
# evidence/manifests/. Exit 0 = candidate READY; non-zero = a gate failed (fail-closed).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REQ_WF_CONFIG="$ROOT/config/release-required-workflows.json"

VERSION=""; PREV=""; SOURCE_COMMIT=""; TAG=""; SCOPE="engine-only"; STAGE="ga"; REPO=""; PROFILE="laravel"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf '[prepare-release] ERROR: %s\n' "$*" >&2; exit 2; }
step() { printf '\n[prepare-release] === %s ===\n' "$*" >&2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--prev) PREV="${2:?}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?}"; shift 2 ;;
		--tag) TAG="${2:?}"; shift 2 ;;
		--scope) SCOPE="${2:?}"; shift 2 ;;
		--stage) STAGE="${2:?}"; shift 2 ;;
		--repo) REPO="${2:?}"; shift 2 ;;
		--profile) PROFILE="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) die "unknown argument: $1 (try --help)" ;;
	esac
done

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required and must be authenticated"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"
[ -n "$VERSION" ] || die "--version X.Y.Z is required"
[ -n "$PREV" ] || die "--prev A.B.C is required (the previous released version, for upgrade validation)"
[ -f "$REQ_WF_CONFIG" ] || die "required-workflows config not found: $REQ_WF_CONFIG"

[ -n "$TAG" ] || TAG="v$VERSION"
[ -n "$REPO" ] || REPO=$(jq -r '.repository' "$REQ_WF_CONFIG")
[ -n "$SOURCE_COMMIT" ] || SOURCE_COMMIT=$(git -C "$ROOT" rev-parse origin/master)
case "$SOURCE_COMMIT" in
	*[!0-9a-f]* | "") die "source commit must be a full 40-hex sha: '$SOURCE_COMMIT'" ;;
esac
[ "${#SOURCE_COMMIT}" -eq 40 ] || die "source commit must be a full 40-hex sha (got ${#SOURCE_COMMIT} chars)"

EVID="$ROOT/evidence/releases"
MAN="$ROOT/evidence/manifests"
mkdir -p "$EVID" "$MAN"
PFX="$EVID/v$VERSION-$STAGE"
MANIFEST="$MAN/v$VERSION-$STAGE.manifest.json"
CANDIDATE="$PFX-candidate.json"

printf '[prepare-release] version=%s tag=%s stage=%s scope=%s\n' "$VERSION" "$TAG" "$STAGE" "$SCOPE" >&2
printf '[prepare-release] repo=%s source_commit=%s prev=%s\n' "$REPO" "$SOURCE_COMMIT" "$PREV" >&2

# The canonical required-workflow set (kept in lockstep with config/required-checks.json).
WF_ARGS=""
for _wf in $(jq -r '.required_workflows[].workflow_name' "$REQ_WF_CONFIG"); do
	WF_ARGS="$WF_ARGS --workflow $_wf"
done
[ -n "$WF_ARGS" ] || die "no required workflows in config"

# --- 1. engine CI evidence ---------------------------------------------------
step "1/8 collect engine CI evidence"
# shellcheck disable=SC2086
sh "$SCRIPT_DIR/collect-release-evidence.sh" --repo "$REPO" --commit "$SOURCE_COMMIT" \
	$WF_ARGS --version "$VERSION" --stage "$STAGE" --scope "$SCOPE" --output "$PFX.json"

# --- 2. verify the CI artifacts ---------------------------------------------
step "2/8 verify CI artifacts (ownership / expiry / archive-safety / digests)"
sh "$SCRIPT_DIR/verify-release-artifacts.sh" --evidence "$PFX.json" --output "$PFX-artifacts.json"
# Fold the verified artifacts back into the evidence so each engine_ci run records its
# artifacts[] + artifacts_verified — the exact state ra_check_evidence_source gates on for
# artifacts_required workflows. verify-release-artifacts only emits the report; nothing else
# writes this back, so the collector's honest empty artifacts[] would otherwise fail the gate.
_embed_tmp=$(mktemp)
jq --slurpfile rep "$PFX-artifacts.json" '
	($rep[0].artifacts) as $recs
	| .engine_ci |= map(
		.workflow_run_id as $rid
		| ($recs | map(select(.run_id == $rid) | {id: .artifact_id, name: .name, verified: .verified})) as $a
		| .artifacts = $a
		| .artifacts_verified = (($a | length) > 0 and (all($a[]; .verified == true)))
	)' "$PFX.json" > "$_embed_tmp" && mv "$_embed_tmp" "$PFX.json"

# --- 3. pull the three CI-proven gate reports from their green runs ----------
step "3/8 download CI-proven gate reports (security / compatibility / adopter)"
# dl_gate <workflow> <artifact-name> <target-file>: resolve the single authoritative
# push-event run at the source commit, download the artifact, copy out its JSON.
dl_gate() {
	_wf="$1"; _art="$2"; _dst="$3"
	_rid=$(gh run list --repo "$REPO" --workflow "$_wf.yml" --commit "$SOURCE_COMMIT" \
		--event push --status success --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
	[ -n "$_rid" ] || die "no green push-event run of $_wf at $SOURCE_COMMIT (gate evidence unavailable)"
	_tmp=$(mktemp -d)
	gh run download "$_rid" --repo "$REPO" -n "$_art" -D "$_tmp" 2>/dev/null \
		|| { rm -rf "$_tmp"; die "could not download artifact '$_art' from $_wf run $_rid"; }
	_json=$(find "$_tmp" -type f -name '*.json' | head -1)
	[ -n "$_json" ] || { rm -rf "$_tmp"; die "artifact '$_art' contained no .json report"; }
	cp "$_json" "$_dst"
	rm -rf "$_tmp"
	printf '[prepare-release]   %s -> %s\n' "$_wf" "$(basename "$_dst")" >&2
}
dl_gate ci-security            sentinel-shield-security-acceptance "$PFX-security-acceptance.json"
dl_gate ci-compatibility       sentinel-shield-compatibility-matrix "$PFX-compatibility-matrix.json"
dl_gate ci-adopter-validation  sentinel-shield-adopter-validation  "$PFX-adopter-scorecard.json"

# --- 4. release manifest -----------------------------------------------------
step "4/8 generate release manifest"
sh "$SCRIPT_DIR/generate-release-manifest.sh" --evidence "$PFX.json" \
	--artifacts "$PFX-artifacts.json" --source-commit "$SOURCE_COMMIT" \
	--tag-target "$SOURCE_COMMIT" --output "$MANIFEST"

# --- 5. lifecycle: upgrade + rollback ---------------------------------------
step "5/8 lifecycle validation (upgrade $PREV->$VERSION, rollback)"
sh "$SCRIPT_DIR/validate-release-lifecycle.sh" --kind upgrade --source-commit "$SOURCE_COMMIT" \
	--from "$PREV" --to "$VERSION" --profile "$PROFILE" --output "$PFX-upgrade-validation.json"
sh "$SCRIPT_DIR/validate-release-lifecycle.sh" --kind rollback --source-commit "$SOURCE_COMMIT" \
	--profile "$PROFILE" --output "$PFX-rollback-validation.json"

# --- 6. cross-checks ---------------------------------------------------------
step "6/8 cross-check manifest + evidence + structural readiness"
sh "$SCRIPT_DIR/verify-release-manifest.sh" --manifest "$MANIFEST" --evidence "$PFX.json" \
	--artifacts "$PFX-artifacts.json" --source-commit "$SOURCE_COMMIT" --tag-target "$SOURCE_COMMIT"
sh "$SCRIPT_DIR/validate-release-evidence.sh" --file "$PFX.json" --require-stage "$STAGE" \
	--scope "$SCOPE" --repo "$REPO" --verify-github
sh "$SCRIPT_DIR/check-release-readiness.sh" --version "$TAG" --stage "$STAGE" \
	--scope "$SCOPE" --evidence "$PFX.json" --verify-github

# --- 7. prepare candidate ----------------------------------------------------
step "7/8 prepare release candidate descriptor"
LIMITATIONS="$ROOT/docs/v$VERSION-known-limitations.md"
[ -f "$LIMITATIONS" ] || die "missing $LIMITATIONS (write the release's known-limitations doc first)"
sh "$SCRIPT_DIR/authorize-production-release.sh" prepare \
	--version "$VERSION" --stage "$STAGE" --scope "$SCOPE" \
	--source-commit "$SOURCE_COMMIT" --tag "$TAG" \
	--evidence "$PFX.json" --manifest "$MANIFEST" --artifacts "$PFX-artifacts.json" \
	--security-acceptance "$PFX-security-acceptance.json" \
	--compat-matrix "$PFX-compatibility-matrix.json" \
	--adopter-scorecard "$PFX-adopter-scorecard.json" \
	--upgrade-validation "$PFX-upgrade-validation.json" \
	--rollback-validation "$PFX-rollback-validation.json" \
	--limitations "$LIMITATIONS" \
	--support-policy "$ROOT/docs/support-policy.md" \
	--incident-response "$ROOT/docs/security-incident-response.md" \
	--output "$CANDIDATE"

# --- 8. verify candidate (all GA gates) -------------------------------------
step "8/8 verify candidate (re-derive every GA gate)"
if sh "$SCRIPT_DIR/authorize-production-release.sh" verify-candidate \
	--candidate "$CANDIDATE" --source-commit "$SOURCE_COMMIT"; then
	cat >&2 <<EOF

[prepare-release] ============================================================
[prepare-release] READY — candidate: $CANDIDATE
[prepare-release] Next (HUMAN, holds the signing key):
[prepare-release]   1. commit the evidence/** + CHANGELOG + release notes, open the evidence PR, merge it
[prepare-release]   2. record the sole-maintainer authorization waiver (or a two-person authorization)
[prepare-release]   3. sh scripts/authorize-production-release.sh print-tag-commands \\
[prepare-release]        --candidate $CANDIDATE --authorization <record>
[prepare-release]   4. run the printed signed-tag + push + gh release create commands
[prepare-release] ============================================================
EOF
	exit 0
else
	die "verify-candidate did NOT return READY — inspect the gate output above (fail-closed)"
fi
