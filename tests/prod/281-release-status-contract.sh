#!/bin/sh
# Sentinel Shield prod test — release-status contract (issues #81, #82, #83).
#
# config/release-status.json is the ONE machine-readable statement of "which release is
# current, is it actually published, and which ref do shipped templates pin". This suite
# proves the validator enforcing it actually detects the drift classes that occurred:
#
#   * README / CHANGELOG intro / product-status claiming a superseded release is latest
#     while a newer one had already shipped;
#   * shipped consumer workflow templates pinning the superseded engine;
#   * a release documented as "published" with no GitHub Release behind it.
#
# Every negative control constructs an isolated fake repository so the real tree is never
# mutated. Positive controls run against the real repository.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
VALIDATOR="$ROOT/scripts/validate-release-status.sh"
STATUS="$ROOT/config/release-status.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$VALIDATOR" ] || { fail "missing scripts/validate-release-status.sh"; exit 1; }
[ -f "$STATUS" ] || { fail "missing config/release-status.json"; exit 1; }

TMPROOT=$(mktemp -d)
# Clean up on success, failure, interrupt and termination alike.
trap 'rm -rf -- "$TMPROOT"' EXIT INT TERM HUP

# rc <args...> — run the validator quietly and echo its exit code.
rc() { _c=0; sh "$VALIDATOR" "$@" >/dev/null 2>&1 || _c=$?; printf '%s' "$_c"; }

# ---------------------------------------------------------------------------
# 1. Positive: the real repository satisfies every mode, offline.
# ---------------------------------------------------------------------------
check "real repo: contract mode passes"   "$(rc contract)"   0
check "real repo: docs mode passes"       "$(rc docs)"       0
check "real repo: changelog mode passes"  "$(rc changelog)"  0
check "real repo: templates mode passes"  "$(rc templates)"  0
check "real repo: published mode passes (offline, self-consistency)" "$(rc published)" 0
check "real repo: all modes pass"         "$(rc all)"        0
# Idempotency: a read-only auditor must return the same verdict on a rerun and must not
# have written anything into the tree.
_before=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
check "real repo: rerun is identical (idempotent)" "$(rc all)" 0
_after=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
check "validator is read-only (no tree changes)" "$_after" "$_before"

# The contract itself must validate against its published JSON Schema shape essentials.
check "schema file exists" "$([ -f "$ROOT/schemas/release-status.schema.json" ] && echo yes || echo no)" yes
check "schema is valid JSON" "$(jq -e . "$ROOT/schemas/release-status.schema.json" >/dev/null 2>&1 && echo yes || echo no)" yes

# `show` is the accessor other scripts/tests use; it must not invent values.
check "show --field .current.tag" "$(sh "$VALIDATOR" show --field .current.tag)" "$(jq -r .current.tag "$STATUS")"
check "show rejects a non-jq-path field" "$(rc show --field current.tag)" 2
check "show rejects a missing --field" "$(rc show)" 2

# The declared consumer ref must be what the shipped templates actually contain — proven
# against the real files, not against another copy of the literal.
_ref=$(jq -r '.consumer_ref.value' "$STATUS")
_bad=0
for _t in $(jq -r '.active_workflow_templates[]' "$STATUS"); do
	grep -Eq "^[[:space:]]*SENTINEL_SHIELD_REF:[[:space:]]*${_ref}([[:space:]]|#|\$)" "$ROOT/$_t" || _bad=1
done
check "every active template pins the contract ref ($_ref)" "$_bad" 0

# ---------------------------------------------------------------------------
# 2. Malformed / missing input: exit 2, never a pass.
# ---------------------------------------------------------------------------
check "missing status file is exit 2" "$(rc all --status "$TMPROOT/nope.json")" 2
printf 'not json' > "$TMPROOT/bad.json"
check "malformed status file is exit 2" "$(rc all --status "$TMPROOT/bad.json")" 2
check "unknown mode is exit 2" "$(rc frobnicate)" 2
check "unknown argument is exit 2" "$(rc all --wat)" 2

# ---------------------------------------------------------------------------
# 3. Negative controls — an isolated fake repository per defect class.
# ---------------------------------------------------------------------------
# mkrepo <name> — create a minimal, CLEAN fake repository that PASSES every check, so a
# later single-field mutation proves that field is what the check detects.
mkrepo() {
	_d="$TMPROOT/$1"
	mkdir -p "$_d/config" "$_d/docs" "$_d/templates/workflows"
	cat > "$_d/config/release-status.json" <<'JSON'
{
  "contract": "sentinel-shield/release-status@1",
  "repository": "acme/shield",
  "current": {
    "version": "3.1.0",
    "tag": "v3.1.0",
    "commit": "1111111111111111111111111111111111111111",
    "stage": "ga",
    "scope": "engine-only",
    "published": true,
    "published_at": "2026-07-24",
    "release_url": "https://github.com/acme/shield/releases/tag/v3.1.0",
    "notes": "docs/v3.1.0-release-notes.md"
  },
  "superseded": [
    {
      "version": "3.0.0",
      "tag": "v3.0.0",
      "commit": "2222222222222222222222222222222222222222",
      "published": true
    }
  ],
  "consumer_ref": { "kind": "tag", "value": "v3.1.0" },
  "status_surfaces": ["README.md"],
  "historical_documents": ["CHANGELOG.md", "docs/v3.0.0-*.md"],
  "historical_trees": ["evidence/"],
  "active_workflow_templates": ["templates/workflows/shield.yml"]
}
JSON
	printf '# Fake\n\nLatest release: `v3.1.0`.\n' > "$_d/README.md"
	printf '# Changelog\n\n`v3.1.0` is the latest published release.\n\n## [Unreleased]\n\n## [3.1.0] — 2026-07-24\n\n## [3.0.0] — 2026-07-01\n' > "$_d/CHANGELOG.md"
	printf '# v3.1.0 notes\n' > "$_d/docs/v3.1.0-release-notes.md"
	printf 'env:\n  SENTINEL_SHIELD_REF: v3.1.0\n' > "$_d/templates/workflows/shield.yml"
	# The docs sweep enumerates tracked markdown via `git ls-files`; the fake repo must be
	# a real (throwaway, local-only) git repository for the sweep to have anything to scan.
	git -C "$_d" init -q 2>/dev/null || return 1
	git -C "$_d" add -A >/dev/null 2>&1 || return 1
	printf '%s' "$_d"
}

# mutate <dir> <jq-filter> — rewrite the fake contract atomically.
mutate() {
	jq "$2" "$1/config/release-status.json" > "$1/config/.rs.tmp" && mv -- "$1/config/.rs.tmp" "$1/config/release-status.json"
}

# frc <dir> <mode...> — run the validator against a fake repo, echo the exit code.
frc() {
	_fd="$1"; shift
	_c=0
	sh "$VALIDATOR" "$@" --repo-root "$_fd" --status "$_fd/config/release-status.json" >/dev/null 2>&1 || _c=$?
	printf '%s' "$_c"
}

if ! command -v git >/dev/null 2>&1; then
	printf 'SKIP: git is unavailable — the fake-repository negative controls did not run\n'
else
	BASE=$(mkrepo base) || { fail "could not build the fake repository"; BASE=""; }
	if [ -n "$BASE" ]; then
		# NEGATIVE CONTROL BASELINE: the clean fake repo must PASS, otherwise every
		# "mutation detected" result below could be an artifact of the fixture.
		check "fake repo baseline passes all modes" "$(frc "$BASE" all)" 0

		# --- contract-shape defects -------------------------------------------
		D=$(mkrepo c1); mutate "$D" '.current.commit = "1111111"'
		check "detects a short/ambiguous current commit" "$(frc "$D" contract)" 1

		D=$(mkrepo c2); mutate "$D" '.current.tag = "v9.9.9"'
		check "detects tag/version disagreement" "$(frc "$D" contract)" 1

		D=$(mkrepo c3); mutate "$D" '.superseded[0].version = "4.0.0" | .superseded[0].tag = "v4.0.0"'
		check "detects a superseded release newer than current" "$(frc "$D" contract)" 1

		# An EMPTY superseded array is schema-valid: the very first release has nothing to
		# supersede. It used to abort the validator mid-run (a trailing `[ … ] && pass` as a
		# function's last command returns the test's status, and `set -e` killed the script
		# before the summary and before every remaining check).
		D=$(mkrepo c3b); mutate "$D" '.superseded = [] | .consumer_ref = {kind: "tag", value: "v3.1.0"}'
		check "an empty superseded array is accepted" "$(frc "$D" contract)" 0
		_out=$(cd "$D" && sh "$VALIDATOR" contract 2>&1 || true)
		case "$_out" in
			*"validate-release-status: contract PASSED"*) pass "  the run reaches its summary (no set -e abort)" ;;
			*) fail "  the run did not reach its summary: $_out" ;;
		esac

		D=$(mkrepo c4); mutate "$D" '.consumer_ref.value = "v3.0.0"'
		check "detects a consumer ref pinned to a superseded release" "$(frc "$D" contract)" 1

		D=$(mkrepo c5); mutate "$D" '.consumer_ref.kind = "branch" | .consumer_ref.value = "master"'
		check "rejects a moving-branch consumer ref" "$(frc "$D" contract)" 1

		D=$(mkrepo c6); mutate "$D" '.status_surfaces += ["docs/does-not-exist.md"]'
		check "detects a declared status surface that does not exist" "$(frc "$D" contract)" 1

		D=$(mkrepo c7); mutate "$D" '.contract = "sentinel-shield/release-status@99"'
		check "detects an unknown contract version" "$(frc "$D" contract)" 1

		# --- documentation drift (the #82 regression) --------------------------
		D=$(mkrepo d1)
		printf '# Fake\n\nThe latest release is `v3.0.0`.\n' > "$D/README.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "detects README presenting a superseded release as latest" "$(frc "$D" docs)" 1

		D=$(mkrepo d2)
		printf '# Guide\n\nThe latest release remains `v3.0.0`.\n' > "$D/docs/adoption.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "detects a NON-surface active doc presenting a superseded release as latest" "$(frc "$D" docs)" 1

		D=$(mkrepo d3)
		printf '# Frozen\n\nThe latest release is `v3.0.0` (historical record).\n' > "$D/docs/v3.0.0-release-notes.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "declared HISTORICAL documents keep their historical claim" "$(frc "$D" docs)" 0

		D=$(mkrepo d4)
		mkdir -p "$D/evidence"
		printf '# Evidence\n\nlatest release `v3.0.0` at capture time\n' > "$D/evidence/run.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "declared HISTORICAL trees are exempt from the sweep" "$(frc "$D" docs)" 0

		D=$(mkrepo d5); mutate "$D" '.historical_documents = ["*.md", "docs/*.md"]'
		check "detects an over-broad exclusion that empties the sweep" "$(frc "$D" docs)" 1

		D=$(mkrepo d6); rm -f "$D/README.md"; git -C "$D" add -A >/dev/null 2>&1
		check "detects a missing status surface" "$(frc "$D" docs)" 1

		# --- CHANGELOG self-consistency ---------------------------------------
		D=$(mkrepo g1)
		printf '# Changelog\n\n`v3.0.0` is the latest published release.\n\n## [3.1.0] — 2026-07-24\n' > "$D/CHANGELOG.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "detects a CHANGELOG intro contradicting its newest section" "$(frc "$D" changelog)" 1

		D=$(mkrepo g2)
		printf '# Changelog\n\n`v3.1.0` released.\n\n## [Unreleased]\n\n## [3.0.0] — 2026-07-01\n' > "$D/CHANGELOG.md"
		git -C "$D" add -A >/dev/null 2>&1
		check "detects a newest CHANGELOG section older than the current release" "$(frc "$D" changelog)" 1

		# --- shipped-template staleness (the #83 regression) -------------------
		D=$(mkrepo t1)
		printf 'env:\n  SENTINEL_SHIELD_REF: v3.0.0\n' > "$D/templates/workflows/shield.yml"
		check "detects a template pinned to a superseded release" "$(frc "$D" templates)" 1

		D=$(mkrepo t2)
		printf 'env:\n  SENTINEL_SHIELD_REF: master\n' > "$D/templates/workflows/shield.yml"
		check "detects a template pinned to a moving branch" "$(frc "$D" templates)" 1

		D=$(mkrepo t3)
		printf 'env:\n  SOMETHING_ELSE: 1\n' > "$D/templates/workflows/shield.yml"
		check "detects a template with no SENTINEL_SHIELD_REF at all" "$(frc "$D" templates)" 1

		D=$(mkrepo t4)
		printf 'env:\n  SENTINEL_SHIELD_REF: "v3.1.0"   # quoted + trailing comment\n' > "$D/templates/workflows/shield.yml"
		check "accepts a quoted ref with a trailing comment" "$(frc "$D" templates)" 0

		D=$(mkrepo t5); rm -f "$D/templates/workflows/shield.yml"
		check "detects a declared template that is missing" "$(frc "$D" templates)" 1

		# --- publication integrity (the #81 regression) ------------------------
		D=$(mkrepo p1); mutate "$D" '.current.release_url = "https://github.com/someone-else/shield/releases/tag/v3.1.0"'
		check "detects a release_url bound to the wrong repository" "$(frc "$D" published)" 1

		D=$(mkrepo p2); mutate "$D" '.current.release_url = "https://github.com/acme/shield/releases/tag/v3.0.0"'
		check "detects a release_url bound to the wrong tag" "$(frc "$D" published)" 1

		D=$(mkrepo p3); rm -f "$D/docs/v3.1.0-release-notes.md"; git -C "$D" add -A >/dev/null 2>&1
		check "detects published release notes that do not exist" "$(frc "$D" published)" 1

		D=$(mkrepo p4); mutate "$D" 'del(.current.release_url)'
		check "detects a published release with no release URL" "$(frc "$D" published)" 1

		D=$(mkrepo p5); mutate "$D" '.current.published = false | del(.current.release_url) | del(.current.published_at)'
		check "an explicitly UNPUBLISHED release claims no publication" "$(frc "$D" published)" 0

		D=$(mkrepo p6); mutate "$D" '.current.published = false'
		check "detects an unpublished release still carrying a release URL" "$(frc "$D" published)" 1
	fi
fi

# ---------------------------------------------------------------------------
# 4. The readiness gate must consume the contract (issue #81 blocking check).
# ---------------------------------------------------------------------------
_wired=$(grep -c 'validate-release-status.sh' "$ROOT/scripts/check-release-readiness.sh" || true)
case "$_wired" in '' | *[!0-9]*) _wired=0 ;; esac
if [ "$_wired" -gt 0 ]; then
	pass "check-release-readiness.sh consumes the release-status contract"
else
	fail "check-release-readiness.sh does not consume the release-status contract — a missing GitHub Release would not block a release"
fi

# The publisher must expose the backfill recovery path and must NOT skip publication when
# notes are missing (that silence is what left tags without releases).
_wf="$ROOT/.github/workflows/release-publish.yml"
if [ -f "$_wf" ]; then
	grep -q 'workflow_dispatch' "$_wf" && pass "release-publish exposes a workflow_dispatch backfill path" \
		|| fail "release-publish has no workflow_dispatch backfill path for a missed tag event"
	if grep -q 'skipping auto-publish' "$_wf"; then
		fail "release-publish still SKIPS publication when release notes are absent (must fail closed)"
	else
		pass "release-publish fails closed when release notes are absent"
	fi
	grep -q 'this workflow never creates tags' "$_wf" && pass "release-publish refuses to create tags (airlock intact)" \
		|| fail "release-publish does not assert the never-create-a-tag guarantee"
else
	fail "missing .github/workflows/release-publish.yml"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '281-release-status-contract: ALL CHECKS PASSED\n'
	exit 0
fi
printf '281-release-status-contract: FAILURES PRESENT\n'
exit 1
