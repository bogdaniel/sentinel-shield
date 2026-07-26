#!/bin/sh
# Sentinel Shield — release-status contract validator.
#
# config/release-status.json is the SINGLE machine-readable source of truth for
# "what is the current release, is it actually published, and which ref do shipped
# consumer templates pin". Everything else (README, CHANGELOG intro, product status,
# release process, workflow templates) is a RENDERING of that file and is checked
# against it here. This exists because the same release literal used to be hand-copied
# into ~30 documents and seven workflow templates, and drifted: README/CHANGELOG/product
# status claimed `v2.0.1` was latest while the repository had already released `v2.2.0`,
# and every shipped template pinned consumers to the superseded engine.
#
# Modes:
#   contract    Shape + internal consistency of config/release-status.json itself.
#   docs        Every declared status surface names the current tag; no ACTIVE document
#               presents a superseded release as the latest one. Frozen historical
#               documents are exempt by declaration (they record what was true then).
#   changelog   The CHANGELOG introduction agrees with its newest released section.
#   templates   Every active workflow template pins consumer_ref (never a superseded
#               tag, never a moving branch).
#   published   A release declared `published` must be a real GitHub Release, not just a
#               pushed tag. Offline this proves the local declaration is self-consistent
#               (release_url + notes + tag target); --verify-github additionally proves
#               the GitHub Release object exists and is not a draft/prerelease.
#   show        Print one field (jq path, e.g. `.current.tag`) for other scripts/tests.
#   all         contract + docs + changelog + templates + published (default).
#
# READ-ONLY: never writes, never mutates a tag or release, never fabricates evidence.
#
# Exit: 0 ok; 1 contract violated (fail closed); 2 invalid invocation / malformed
#       status file; 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	cat <<'EOF'
Usage:
  validate-release-status.sh [contract|docs|changelog|templates|published|all] \
      [--status <file>] [--repo-root <dir>] [--verify-github] [--repo <owner/name>]
  validate-release-status.sh show --field <jq-path> [--status <file>]

READ-ONLY. Fails closed: a missing/malformed status file is exit 2, a violated
contract is exit 1.
EOF
}

MODE="all"
case "${1:-}" in
	contract | docs | changelog | templates | published | show | all) MODE="$1"; shift ;;
	-h | --help) usage; exit 0 ;;
	-*) ;;
	"") ;;
	*) log_error "unknown mode: $1"; usage >&2; exit 2 ;;
esac

STATUS_FILE=""
FIELD=""
VERIFY_GITHUB=0
REPO_OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--status) STATUS_FILE="${2:?--status requires a value}"; shift 2 ;;
		--repo-root) REPO_ROOT=$(CDPATH= cd -- "${2:?--repo-root requires a value}" && pwd); shift 2 ;;
		--field) FIELD="${2:?--field requires a value}"; shift 2 ;;
		--verify-github) VERIFY_GITHUB=1; shift ;;
		--repo) REPO_OVERRIDE="${2:?--repo requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }

[ -n "$STATUS_FILE" ] || STATUS_FILE="$REPO_ROOT/config/release-status.json"
[ -f "$STATUS_FILE" ] || { log_error "release-status contract not found: $STATUS_FILE"; exit 2; }
jq -e . "$STATUS_FILE" >/dev/null 2>&1 || { log_error "release-status contract is not valid JSON: $STATUS_FILE"; exit 2; }

# `q <jq-path>` — read a scalar from the contract. Empty output means absent, which
# every caller below treats as a failure rather than a default.
q() { jq -r "$1 // \"\"" "$STATUS_FILE"; }
qa() { jq -r "$1 // empty | .[]" "$STATUS_FILE"; }

if [ "$MODE" = show ]; then
	[ -n "$FIELD" ] || { log_error "show: --field <jq-path> is required"; exit 2; }
	case "$FIELD" in
		.*) ;;
		*) log_error "show: --field must be a jq path starting with '.'"; exit 2 ;;
	esac
	jq -r "$FIELD // empty" "$STATUS_FILE"
	exit 0
fi

FAILURES=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$*"; }

CUR_TAG=$(q '.current.tag')
CUR_VERSION=$(q '.current.version')
CUR_COMMIT=$(q '.current.commit')
CUR_PUBLISHED=$(jq -r 'if (.current.published // false) then "true" else "false" end' "$STATUS_FILE")
REPO_NAME=$(q '.repository')
[ -n "$REPO_OVERRIDE" ] && REPO_NAME="$REPO_OVERRIDE"
REF_KIND=$(q '.consumer_ref.kind')
REF_VALUE=$(q '.consumer_ref.value')

[ -n "$CUR_TAG" ] && [ -n "$CUR_VERSION" ] && [ -n "$CUR_COMMIT" ] || {
	log_error "release-status contract is missing current.tag/version/commit (fail closed)"; exit 2; }

# is_hex40 <value>
is_hex40() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# tag_token_re <tag> — an ERE matching this tag as a WHOLE TOKEN. `grep -F` was a plain
# substring match, so the superseded tag `v2.0.0` also matched `v2.0.0-beta.1`,
# `v2.0.0-rc.1` and `v2.0.0-alpha.1` — tags this repository legitimately names in historical
# prose. A true sentence about a pre-release would have been reported as a stale-latest claim.
tag_token_re() {
	printf '(^|[^0-9A-Za-z.-])%s([^0-9A-Za-z.-]|$)' "$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')"
}

# is_historical <repo-relative-path> — true when the path is declared frozen.
#
# `set -f` is essential: the declared patterns are split into words here, and without it
# the shell would PATHNAME-EXPAND `docs/v1-*.md` against the working directory before the
# match ever happened — silently turning a pattern list into whatever files happen to
# exist. Inside `case`, an unquoted variable is a glob PATTERN, which is what we want.
is_historical() {
	_path="$1"
	_hit=1
	set -f
	for _tree in $HISTORICAL_TREES; do
		case "$_path" in "$_tree"*) _hit=0; break ;; esac
	done
	if [ "$_hit" -ne 0 ]; then
		for _pat in $HISTORICAL_DOCS; do
			# shellcheck disable=SC2254 # intentional glob match against a declared pattern
			case "$_path" in $_pat) _hit=0; break ;; esac
		done
	fi
	set +f
	return "$_hit"
}

HISTORICAL_DOCS=$(qa '.historical_documents' | tr '\n' ' ')
HISTORICAL_TREES=$(qa '.historical_trees' | tr '\n' ' ')
SUPERSEDED_TAGS=$(jq -r '[.superseded[]?.tag] | .[]' "$STATUS_FILE" | tr '\n' ' ')

# ============================================================================
# mode: contract — the status file must be internally consistent.
# ============================================================================
check_contract() {
	printf 'release-status: contract\n'
	_c=$(q '.contract')
	if [ "$_c" = "sentinel-shield/release-status@1" ]; then pass "contract identifier"
	else fail "CONTRACT_UNKNOWN — contract='$_c' (expected sentinel-shield/release-status@1)"; fi

	case "$REPO_NAME" in
		*/*) pass "repository '$REPO_NAME' is owner/name" ;;
		*) fail "REPOSITORY_MALFORMED — repository='$REPO_NAME' (expected owner/name)" ;;
	esac

	if [ "$CUR_TAG" = "v$CUR_VERSION" ]; then pass "current.tag matches current.version"
	else fail "TAG_VERSION_MISMATCH — tag='$CUR_TAG' version='$CUR_VERSION'"; fi

	if is_hex40 "$CUR_COMMIT"; then pass "current.commit is a full 40-hex SHA"
	else fail "COMMIT_NOT_FULL_SHA — current.commit='$CUR_COMMIT' (short/ambiguous SHAs are rejected)"; fi

	_stage=$(q '.current.stage')
	case "$_stage" in
		alpha | beta | rc | ga) pass "current.stage='$_stage'" ;;
		*) fail "STAGE_INVALID — current.stage='$_stage'" ;;
	esac

	_scope=$(q '.current.scope')
	case "$_scope" in
		engine-only | framework-validated | full-platform) pass "current.scope='$_scope'" ;;
		*) fail "SCOPE_INVALID — current.scope='$_scope'" ;;
	esac

	# Every superseded entry must be a real, older release of the same shape.
	_n=$(jq '[.superseded[]?] | length' "$STATUS_FILE")
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_t=$(jq -r ".superseded[$_i].tag // \"\"" "$STATUS_FILE")
		_v=$(jq -r ".superseded[$_i].version // \"\"" "$STATUS_FILE")
		_sc=$(jq -r ".superseded[$_i].commit // \"\"" "$STATUS_FILE")
		if [ "$_t" != "v$_v" ]; then fail "SUPERSEDED_TAG_MISMATCH — superseded[$_i] tag='$_t' version='$_v'"; fi
		if ! is_hex40 "$_sc"; then fail "SUPERSEDED_COMMIT_NOT_FULL_SHA — superseded[$_i] commit='$_sc'"; fi
		if [ "$_t" = "$CUR_TAG" ]; then fail "SUPERSEDED_IS_CURRENT — '$_t' cannot be both current and superseded"; fi
		# The current release must sort ABOVE every superseded one; a "current" that is
		# older than something it supersedes is a mis-edit, not a release.
		_newest=$(printf '%s\n%s\n' "$_v" "$CUR_VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
		if [ "$_newest" != "$CUR_VERSION" ]; then
			fail "SUPERSEDED_NEWER_THAN_CURRENT — superseded '$_v' sorts above current '$CUR_VERSION'"
		fi
		_i=$((_i + 1))
	done
	[ "$_n" -gt 0 ] && pass "$_n superseded release(s) are older than current and well-formed"

	# The consumer ref must be immutable and must not point at a superseded release.
	case "$REF_KIND" in
		tag)
			if [ "$REF_VALUE" = "$CUR_TAG" ]; then pass "consumer_ref pins the current tag '$CUR_TAG'"
			else fail "CONSUMER_REF_STALE — consumer_ref='$REF_VALUE' but current tag is '$CUR_TAG'"; fi ;;
		commit)
			if [ "$REF_VALUE" = "$CUR_COMMIT" ]; then pass "consumer_ref pins the current commit"
			else fail "CONSUMER_REF_STALE — consumer_ref commit='$REF_VALUE' but current commit is '$CUR_COMMIT'"; fi ;;
		*) fail "CONSUMER_REF_KIND_INVALID — kind='$REF_KIND' (tag|commit; a moving branch is never valid)" ;;
	esac

	# Declared surfaces/templates must exist — a renamed file must not silently drop coverage.
	for _f in $(qa '.status_surfaces') $(qa '.active_workflow_templates'); do
		[ -f "$REPO_ROOT/$_f" ] || fail "DECLARED_FILE_MISSING — $_f is declared in the contract but does not exist"
	done
	pass "declared status surfaces and workflow templates exist"
}

# ============================================================================
# mode: docs — active documents agree with the contract.
# ============================================================================
check_docs() {
	printf 'release-status: docs\n'
	for _f in $(qa '.status_surfaces'); do
		if [ ! -f "$REPO_ROOT/$_f" ]; then fail "STATUS_SURFACE_MISSING — $_f"; continue; fi
		if grep -Fq "$CUR_TAG" "$REPO_ROOT/$_f"; then pass "$_f names the current release $CUR_TAG"
		else fail "STATUS_SURFACE_STALE — $_f never mentions the current release $CUR_TAG"; fi
	done

	# Stale-latest sweep: no ACTIVE document may pair a "latest release" claim with a
	# superseded tag. Historical documents are exempt by declaration; the CHANGELOG is
	# swept intro-only (its release sections are history) by check_changelog.
	_swept=0
	for _f in $(cd "$REPO_ROOT" && git ls-files '*.md' 2>/dev/null); do
		is_historical "$_f" && continue
		_swept=$((_swept + 1))
		for _tag in $SUPERSEDED_TAGS; do
			_hits=$(grep -in 'latest release\|latest published release\|latest stable release' "$REPO_ROOT/$_f" 2>/dev/null |
				grep -E "$(tag_token_re "$_tag")" | grep -Fv "$CUR_TAG" || true)
			if [ -n "$_hits" ]; then
				fail "STALE_LATEST_CLAIM — $_f presents superseded $_tag as the latest release:"
				printf '%s\n' "$_hits" | sed 's/^/          /'
			fi
		done
	done
	if [ "$_swept" -eq 0 ]; then
		fail "SWEEP_EMPTY — no active markdown documents were swept (exclusions are too broad)"
	else
		pass "stale-latest sweep over $_swept active document(s)"
	fi
}

# ============================================================================
# mode: changelog — the introduction agrees with the newest released section.
# ============================================================================
check_changelog() {
	printf 'release-status: changelog\n'
	_cl="$REPO_ROOT/CHANGELOG.md"
	if [ ! -f "$_cl" ]; then fail "CHANGELOG_MISSING — $_cl"; return; fi

	# Intro = everything before the first version heading. `## [Unreleased]` is not a release.
	_intro=$(awk '/^## \[/ { exit } { print }' "$_cl")
	if printf '%s' "$_intro" | grep -Fq "$CUR_TAG"; then pass "CHANGELOG intro names $CUR_TAG"
	else fail "CHANGELOG_INTRO_STALE — the introduction never mentions the current release $CUR_TAG"; fi
	for _tag in $SUPERSEDED_TAGS; do
		if printf '%s' "$_intro" | grep -i 'latest release\|latest published release' | grep -E "$(tag_token_re "$_tag")" | grep -Fvq "$CUR_TAG"; then
			fail "CHANGELOG_INTRO_STALE_LATEST — the introduction presents superseded $_tag as latest"
		fi
	done

	_newest=$(grep -E '^## \[[0-9]' "$_cl" | head -n1 | sed -E 's/^## \[([^]]+)\].*/\1/')
	if [ "$_newest" = "$CUR_VERSION" ]; then pass "newest released CHANGELOG section is [$CUR_VERSION]"
	else fail "CHANGELOG_SECTION_MISMATCH — newest released section is [$_newest] but current release is $CUR_VERSION"; fi
}

# ============================================================================
# mode: templates — shipped consumer templates pin the contract ref.
# ============================================================================
check_templates() {
	printf 'release-status: templates\n'
	for _f in $(qa '.active_workflow_templates'); do
		if [ ! -f "$REPO_ROOT/$_f" ]; then fail "TEMPLATE_MISSING — $_f"; continue; fi
		_refs=$(grep -E '^[[:space:]]*SENTINEL_SHIELD_REF:' "$REPO_ROOT/$_f" |
			sed -E 's/^[[:space:]]*SENTINEL_SHIELD_REF:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')
		if [ -z "$_refs" ]; then fail "TEMPLATE_REF_ABSENT — $_f declares no SENTINEL_SHIELD_REF"; continue; fi
		_bad=0
		for _r in $_refs; do
			[ "$_r" = "$REF_VALUE" ] || { fail "TEMPLATE_REF_STALE — $_f pins SENTINEL_SHIELD_REF='$_r' (contract requires '$REF_VALUE')"; _bad=1; }
		done
		[ "$_bad" -eq 0 ] && pass "$_f pins $REF_VALUE"
	done
}

# ============================================================================
# mode: published — a declared publication must be a real GitHub Release.
# ============================================================================
check_published() {
	printf 'release-status: published\n'
	if [ "$CUR_PUBLISHED" != true ]; then
		# An UNPUBLISHED release must not carry publication artefacts: a release URL or a
		# publication date for a release that was never published is a false claim, not an
		# incomplete record.
		_u=$(q '.current.release_url'); _d=$(q '.current.published_at')
		if [ -n "$_u" ] || [ -n "$_d" ]; then
			fail "UNPUBLISHED_WITH_PUBLICATION_FIELDS — $CUR_TAG is declared unpublished but carries release_url='$_u' published_at='$_d'"
		else
			pass "current release $CUR_TAG is declared UNPUBLISHED — no publication is claimed"
		fi
		return
	fi

	_url=$(q '.current.release_url')
	_expect="https://github.com/$REPO_NAME/releases/tag/$CUR_TAG"
	if [ "$_url" = "$_expect" ]; then pass "release_url binds $CUR_TAG to $REPO_NAME"
	else fail "RELEASE_URL_MISMATCH — release_url='$_url' expected='$_expect'"; fi

	_notes=$(q '.current.notes')
	if [ -n "$_notes" ] && [ -f "$REPO_ROOT/$_notes" ]; then pass "release notes present: $_notes"
	else fail "RELEASE_NOTES_MISSING — current.notes='$_notes' does not exist (the publisher cannot render this release)"; fi

	# Local tag identity: if the tag object is present in this checkout it must peel to
	# the declared commit. A tag that peels elsewhere is a moved/mis-targeted tag.
	# `-d .git` is not a checkout test: a git worktree has a .git FILE, and the tag
	# identity check would silently never run there.
	if command_exists git && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
		if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$CUR_TAG" >/dev/null 2>&1; then
			_peeled=$(git -C "$REPO_ROOT" rev-list -n1 "$CUR_TAG" 2>/dev/null || printf '')
			if [ "$_peeled" = "$CUR_COMMIT" ]; then pass "tag $CUR_TAG peels to the declared commit"
			else fail "TAG_TARGETS_WRONG_COMMIT — $CUR_TAG peels to ${_peeled:-unknown}, contract says $CUR_COMMIT"; fi
		else
			log_warn "tag $CUR_TAG is not present in this checkout (shallow clone / no tags fetched); tag identity NOT proven here"
		fi
	fi

	[ "$VERIFY_GITHUB" -eq 1 ] || {
		log_warn "offline: the GitHub Release object was NOT contacted; pass --verify-github to prove publication"
		return
	}

	: "${GH_BIN:=gh}"
	if ! command_exists "$GH_BIN"; then
		log_error "--verify-github requires '$GH_BIN'"
		exit 3
	fi
	_stage=$(q '.current.stage'); [ -n "$_stage" ] || _stage=ga
	if sh "$SCRIPT_DIR/verify-published-release.sh" verify-github-release \
		--tag "$CUR_TAG" --stage "$_stage" --repo "$REPO_NAME" >/dev/null 2>&1; then
		pass "GitHub Release exists and is published for $CUR_TAG"
	else
		fail "GITHUB_RELEASE_ABSENT_OR_INVALID — $REPO_NAME declares $CUR_TAG published but no valid GitHub Release was verified (a pushed tag is not a release; backfill with the release-publish workflow_dispatch recovery path)"
	fi
}

case "$MODE" in
	contract) check_contract ;;
	docs) check_docs ;;
	changelog) check_changelog ;;
	templates) check_templates ;;
	published) check_published ;;
	all) check_contract; check_docs; check_changelog; check_templates; check_published ;;
esac

printf '\n----\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'validate-release-status: %s PASSED (current release %s)\n' "$MODE" "$CUR_TAG"
	exit 0
fi
printf 'validate-release-status: %s FAILED (%d violation(s)); fail closed\n' "$MODE" "$FAILURES"
exit 1
