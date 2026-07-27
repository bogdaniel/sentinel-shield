#!/bin/sh
# Sentinel Shield prod test — trusted cross-workflow evidence handoff (issue #88).
#
# Same-run `needs:` remains the recommended topology. This suite covers the OPT-IN
# cross-workflow path, whose whole reason to exist is that "download the latest successful
# artifact" is not a trust rule: that run can be a fork pull request, another branch, another
# commit, a re-run of an older commit, a failed or cancelled run, or a workflow nobody meant
# to trust — and the artifact itself can be substituted.
#
# Every case below is adversarial: the happy path is asserted once, and then each trust
# dimension is broken ONE at a time to prove it is the reason for the rejection.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
VERIFY="$ROOT/scripts/verify-evidence-handoff.sh"
MANIFEST_TOOL="$ROOT/scripts/build-evidence-manifest.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$VERIFY" ] || { fail "missing scripts/verify-evidence-handoff.sh"; exit 1; }
[ -f "$MANIFEST_TOOL" ] || { fail "missing scripts/build-evidence-manifest.sh"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

COMMIT=1111111111111111111111111111111111111111
OTHER_COMMIT=2222222222222222222222222222222222222222
NOW="2026-07-26T12:00:00Z"
FRESH="2026-07-26T11:00:00Z"

# mkcase <name> [run-json-overrides] — a complete, VALID handoff, ready to be broken.
mkcase() {
	_d="$WORK/$1"; mkdir -p "$_d/artifact/reports"
	jq --arg c "$COMMIT" '.source.commit = $c | .source.branch = "main" | .source.workflow = "sentinel-shield"' \
		"$ROOT/templates/security-summary.example.json" > "$_d/artifact/reports/security-summary.json"
	sh "$MANIFEST_TOOL" --dir "$_d/artifact" --repository acme/app --run-id 42 \
		--commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
	_extra="${2:-}"; [ -n "$_extra" ] || _extra='{}'
	jq -n --arg c "$COMMIT" --arg t "$FRESH" --argjson extra "$_extra" '
		{ id: 42, name: "sentinel-shield", status: "completed", conclusion: "success",
		  event: "push", head_sha: $c, head_branch: "main", created_at: $t,
		  repository: { full_name: "acme/app" }, head_repository: { full_name: "acme/app" } } * $extra' \
		> "$_d/producer-run.json"
	printf '%s' "$_d"
}

# vrc <dir> [extra-args...] — run the verifier, echo its exit code.
vrc() {
	_d="$1"; shift
	_c=0
	sh "$VERIFY" verify \
		--producer-run "$_d/producer-run.json" \
		--expected-repository acme/app \
		--expected-workflow sentinel-shield \
		--expected-commit "$COMMIT" \
		--expected-ref refs/heads/main \
		--artifact-dir "$_d/artifact" \
		--now "$NOW" "$@" >"$_d/verify.log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
# The first rejection CODE (the token after the REJECT label), not the label itself.
reason() { sed -n 's/^ *REJECT  \([A-Z_][A-Z_]*\).*/\1/p' "$1/verify.log" | head -n1; }

# ---------------------------------------------------------------------------
# 1. The happy path verifies — and is the control for every rejection below.
# ---------------------------------------------------------------------------
D=$(mkcase happy)
check "a fully bound handoff verifies" "$(vrc "$D" --expected-run-id 42)" 0
check "re-running the verification is idempotent" "$(vrc "$D" --expected-run-id 42)" 0
check "the verifier is read-only (artifact unchanged)" \
	"$(cd "$D/artifact" && find . -type f | sort | tr '\n' ' ')" \
	"./reports/security-summary.json ./sentinel-shield-artifact-manifest.json "
check "JSON output reports the verdict" \
	"$(sh "$VERIFY" verify --producer-run "$D/producer-run.json" --expected-repository acme/app \
		--expected-workflow sentinel-shield --expected-commit "$COMMIT" --expected-ref refs/heads/main \
		--artifact-dir "$D/artifact" --now "$NOW" --format json 2>/dev/null | jq -r '.verified')" "true"

# ---------------------------------------------------------------------------
# 2. Producer-identity rejections — one broken dimension each.
# ---------------------------------------------------------------------------
D=$(mkcase wrong-repo '{"repository":{"full_name":"someone-else/app"},"head_repository":{"full_name":"someone-else/app"}}')
check "evidence from the WRONG REPOSITORY is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "WRONG_REPOSITORY"

D=$(mkcase fork '{"head_repository":{"full_name":"attacker/app-fork"}}')
check "evidence from a FORK is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "FORK_EVIDENCE"

D=$(mkcase pr-event '{"event":"pull_request"}')
check "evidence from a pull_request event is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "UNTRUSTED_EVENT"

D=$(mkcase prt-event '{"event":"pull_request_target"}')
check "evidence from pull_request_target is rejected" "$(vrc "$D")" 1

D=$(mkcase wrong-workflow '{"name":"some-other-workflow"}')
check "evidence from a NON-ALLOWLISTED workflow is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "WORKFLOW_NOT_ALLOWLISTED"

D=$(mkcase wrong-branch '{"head_branch":"feature/x"}')
check "evidence from an UNTRUSTED BRANCH is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "UNTRUSTED_REF"

D=$(mkcase wrong-commit "$(jq -nc --arg c "$OTHER_COMMIT" '{head_sha:$c}')")
check "evidence for a DIFFERENT COMMIT is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "WRONG_COMMIT"

D=$(mkcase failed-run '{"conclusion":"failure"}')
check "evidence from a FAILED run is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "RUN_NOT_SUCCESSFUL"

D=$(mkcase cancelled-run '{"conclusion":"cancelled"}')
check "evidence from a CANCELLED run is rejected" "$(vrc "$D")" 1

D=$(mkcase skipped-run '{"conclusion":"skipped"}')
check "evidence from a SKIPPED run is rejected" "$(vrc "$D")" 1

D=$(mkcase inprogress '{"status":"in_progress","conclusion":null}')
check "evidence from an UNFINISHED run is rejected" "$(vrc "$D")" 1

D=$(mkcase wrong-run-id)
check "a run id that differs from the expected one is rejected" "$(vrc "$D" --expected-run-id 99)" 1
check "  reason" "$(reason "$D")" "WRONG_RUN_ID"

D=$(mkcase stale '{"created_at":"2026-07-01T00:00:00Z"}')
check "STALE evidence is rejected" "$(vrc "$D")" 1
check "  reason" "$(reason "$D")" "STALE_EVIDENCE"

D=$(mkcase future '{"created_at":"2027-01-01T00:00:00Z"}')
check "evidence timestamped in the FUTURE is rejected" "$(vrc "$D")" 1

D=$(mkcase badtime '{"created_at":"not-a-timestamp"}')
check "an UNPARSEABLE run timestamp is rejected (freshness unprovable)" "$(vrc "$D")" 1

D=$(mkcase norun)
printf 'not-json{' > "$D/producer-run.json"
check "an unreadable producer run is rejected" "$(vrc "$D")" 1

# Ambiguity: two runs that BOTH satisfy every rule must be rejected, not silently picked.
D=$(mkcase ambiguous)
jq '.id = 43' "$D/producer-run.json" > "$D/producer-run-2.json"
_c=0
sh "$VERIFY" verify --producer-run "$D/producer-run.json" --producer-run "$D/producer-run-2.json" \
	--expected-repository acme/app --expected-workflow sentinel-shield --expected-commit "$COMMIT" \
	--expected-ref refs/heads/main --artifact-dir "$D/artifact" --now "$NOW" >"$D/verify.log" 2>&1 || _c=$?
check "TWO equally valid producer runs are AMBIGUOUS, not 'latest wins'" "$_c" 1
grep -q 'AMBIGUOUS_PRODUCER' "$D/verify.log" && pass "  the ambiguity is named explicitly" || fail "  ambiguity not reported"
# ...and naming the run that actually produced the artifact resolves it.
_c=0
sh "$VERIFY" verify --producer-run "$D/producer-run.json" --producer-run "$D/producer-run-2.json" \
	--expected-repository acme/app --expected-workflow sentinel-shield --expected-commit "$COMMIT" \
	--expected-ref refs/heads/main --artifact-dir "$D/artifact" --now "$NOW" --expected-run-id 42 >/dev/null 2>&1 || _c=$?
check "naming the producing run explicitly resolves the ambiguity" "$_c" 0
# Naming the OTHER run must still fail: the artifact belongs to run 42, so trusting run 43
# would mean accepting an artifact from a different run (the substitution this guards against).
_c=0
sh "$VERIFY" verify --producer-run "$D/producer-run.json" --producer-run "$D/producer-run-2.json" \
	--expected-repository acme/app --expected-workflow sentinel-shield --expected-commit "$COMMIT" \
	--expected-ref refs/heads/main --artifact-dir "$D/artifact" --now "$NOW" --expected-run-id 43 >"$D/verify.log" 2>&1 || _c=$?
check "naming a run that did NOT produce this artifact is rejected" "$_c" 1
grep -q 'MANIFEST_WRONG_RUN' "$D/verify.log" && pass "  the artifact/run cross-binding is named" || fail "  artifact/run mismatch not reported"

# ---------------------------------------------------------------------------
# 3. Artifact-integrity rejections.
# ---------------------------------------------------------------------------
D=$(mkcase no-manifest); rm -f "$D/artifact/sentinel-shield-artifact-manifest.json"
check "an artifact with NO checksum manifest is rejected" "$(vrc "$D")" 1
grep -q 'MANIFEST_MISSING' "$D/verify.log" && pass "  the missing manifest is named" || fail "  missing manifest not reported"
grep -q 'ARTIFACT_IDENTITY_UNPROVEN' "$D/verify.log" && pass "  the artifact identity is also unproven without a manifest" || fail "  artifact identity not reported"

D=$(mkcase substituted)
printf '{"substituted":true}' > "$D/artifact/reports/security-summary.json"
check "SUBSTITUTED artifact content is rejected (digest mismatch)" "$(vrc "$D")" 1
grep -q 'ARTIFACT_DIGEST_MISMATCH' "$D/verify.log" && pass "  the digest mismatch is named" || fail "  digest mismatch not reported"

D=$(mkcase extra-file)
printf 'payload' > "$D/artifact/reports/extra.json"
check "an UNCOVERED extra file in the artifact is rejected" "$(vrc "$D")" 1
grep -q 'ARTIFACT_UNVERIFIED_FILES' "$D/verify.log" && pass "  the unverified file is named" || fail "  unverified file not reported"

D=$(mkcase missing-file); rm -f "$D/artifact/reports/security-summary.json"
check "a manifest-listed file missing from the artifact is rejected" "$(vrc "$D")" 1

D=$(mkcase manifest-other-run)
jq '.run_id = "999"' "$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "a manifest from ANOTHER RUN is rejected (artifact substitution)" "$(vrc "$D" --expected-run-id 42)" 1
grep -q 'MANIFEST_WRONG_RUN' "$D/verify.log" && pass "  the wrong-run manifest is named" || fail "  wrong-run manifest not reported"

D=$(mkcase manifest-other-commit)
jq --arg c "$OTHER_COMMIT" '.commit = $c' "$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "a manifest for another COMMIT is rejected" "$(vrc "$D")" 1

D=$(mkcase manifest-other-repo)
jq '.repository = "someone-else/app"' "$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "a manifest from another REPOSITORY is rejected" "$(vrc "$D")" 1

D=$(mkcase manifest-traversal)
jq '.files += [{"path":"../../etc/passwd","sha256":"'"$(printf 'a%.0s' $(seq 1 64))"'"}]' \
	"$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "a manifest path that escapes the artifact directory is rejected" "$(vrc "$D")" 1
grep -q 'MANIFEST_PATH_UNSAFE' "$D/verify.log" && pass "  path traversal is named" || fail "  path traversal not reported"

D=$(mkcase manifest-empty)
jq '.files = []' "$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "an EMPTY manifest (verifying nothing) is rejected" "$(vrc "$D")" 1

D=$(mkcase wrong-artifact-name)
jq '.artifact = "some-other-artifact"' "$D/artifact/sentinel-shield-artifact-manifest.json" > "$D/m.json" && mv "$D/m.json" "$D/artifact/sentinel-shield-artifact-manifest.json"
check "an artifact whose declared name is not allowlisted is rejected" "$(vrc "$D")" 1

# ---------------------------------------------------------------------------
# 4. The evidence must bind ITSELF to the commit — not just its wrapper.
# ---------------------------------------------------------------------------
D=$(mkcase summary-other-commit)
jq --arg c "$OTHER_COMMIT" '.source.commit = $c' "$D/artifact/reports/security-summary.json" > "$D/s.json" \
	&& mv "$D/s.json" "$D/artifact/reports/security-summary.json"
sh "$MANIFEST_TOOL" --dir "$D/artifact" --repository acme/app --run-id 42 --commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
check "a summary whose OWN commit differs is rejected" "$(vrc "$D")" 1
grep -q 'SUMMARY_WRONG_COMMIT' "$D/verify.log" && pass "  the summary binding failure is named" || fail "  summary binding failure not reported"

D=$(mkcase summary-other-branch)
jq '.source.branch = "feature/x"' "$D/artifact/reports/security-summary.json" > "$D/s.json" \
	&& mv "$D/s.json" "$D/artifact/reports/security-summary.json"
sh "$MANIFEST_TOOL" --dir "$D/artifact" --repository acme/app --run-id 42 --commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
check "a summary from an untrusted branch is rejected" "$(vrc "$D")" 1

D=$(mkcase summary-other-workflow)
jq '.source.workflow = "attacker-workflow"' "$D/artifact/reports/security-summary.json" > "$D/s.json" \
	&& mv "$D/s.json" "$D/artifact/reports/security-summary.json"
sh "$MANIFEST_TOOL" --dir "$D/artifact" --repository acme/app --run-id 42 --commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
check "a summary naming a non-allowlisted producer workflow is rejected" "$(vrc "$D")" 1

D=$(mkcase no-summary); rm -f "$D/artifact/reports/security-summary.json"
sh "$MANIFEST_TOOL" --dir "$D/artifact" --repository acme/app --run-id 42 --commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
check "an artifact with NO summary is rejected" "$(vrc "$D")" 1

# ---------------------------------------------------------------------------
# 5. Invocation contract: trust inputs are mandatory, never defaulted.
# ---------------------------------------------------------------------------
D=$(mkcase args)
novrc() { _c=0; sh "$VERIFY" verify "$@" >/dev/null 2>&1 || _c=$?; printf '%s' "$_c"; }
check "a missing --expected-repository is exit 2" \
	"$(novrc --producer-run "$D/producer-run.json" --expected-workflow x --expected-commit "$COMMIT" --expected-ref refs/heads/main --artifact-dir "$D/artifact")" 2
check "a missing --expected-workflow allowlist is exit 2" \
	"$(novrc --producer-run "$D/producer-run.json" --expected-repository acme/app --expected-commit "$COMMIT" --expected-ref refs/heads/main --artifact-dir "$D/artifact")" 2
check "a missing --expected-ref allowlist is exit 2" \
	"$(novrc --producer-run "$D/producer-run.json" --expected-repository acme/app --expected-workflow x --expected-commit "$COMMIT" --artifact-dir "$D/artifact")" 2
check "a short/invalid --expected-commit is exit 2" \
	"$(novrc --producer-run "$D/producer-run.json" --expected-repository acme/app --expected-workflow x --expected-commit 1111 --expected-ref refs/heads/main --artifact-dir "$D/artifact")" 2
check "an unknown argument is exit 2" "$(novrc --wat)" 2
check "an unknown mode is exit 2" "$(_c=0; sh "$VERIFY" frobnicate >/dev/null 2>&1 || _c=$?; printf '%s' "$_c")" 2
check "explain documents the trust rules" "$(sh "$VERIFY" explain | grep -c '^ *[0-9]')" 14

# ---------------------------------------------------------------------------
# 6. The shipped consumer template is opt-in, least-privilege and safe.
# ---------------------------------------------------------------------------
T="templates/workflows/sentinel-shield-evidence-handoff.yml"
if [ -f "$T" ]; then
	grep -q '# *workflow_run:' "$T" && pass "the handoff template ships DISABLED (workflow_run commented out)" \
		|| fail "the handoff template ships with workflow_run enabled by default"
	# Only an ACTIVE trigger matters; the header explains why pull_request_target is unsafe.
	grep -E '^[[:space:]]*pull_request_target:' "$T" >/dev/null 2>&1 \
		&& fail "the handoff template TRIGGERS on pull_request_target" \
		|| pass "the handoff template never triggers on pull_request_target"
	grep -q 'actions: read' "$T" && pass "the handoff job requests actions: read" || fail "the handoff job does not request actions: read"
	grep -qE '(contents|actions|packages|id-token|security-events): write' "$T" && fail "the handoff template requests a WRITE scope" \
		|| pass "the handoff template requests no write scope"
	grep -q 'verify-evidence-handoff.sh verify' "$T" && pass "the handoff template verifies before enforcing" \
		|| fail "the handoff template does not run the verifier"
	# The verification step must come BEFORE the enforcement step.
	_v=$(grep -n 'verify-evidence-handoff.sh verify' "$T" | head -n1 | cut -d: -f1)
	_e=$(grep -n 'enforce-gates.sh' "$T" | head -n1 | cut -d: -f1)
	if [ -n "$_v" ] && [ -n "$_e" ] && [ "$_v" -lt "$_e" ]; then
		pass "verification runs before enforcement"
	else
		fail "enforcement is not preceded by verification"
	fi
	grep -q 'select-security-summary.sh' "$T" && fail "the handoff template allows the example-summary fallback" \
		|| pass "the handoff template never falls back to the example summary"
	_uses=$(grep -cE '^\s*uses: ' "$T" || true)
	_pinned=$(grep -cE '^\s*uses: [^@]+@[0-9a-f]{40}' "$T" || true)
	check "every action in the handoff template is SHA-pinned" "$_pinned" "$_uses"
else
	fail "missing $T"
fi

# The recommended same-run topology must still be documented as the default.
grep -q 'needs:' templates/workflows/sentinel-shield.yml \
	&& pass "the default managed workflow still uses the same-run needs: topology" \
	|| fail "the default managed workflow no longer uses the same-run topology"

# --- CodeRabbit round 2: a nested decoy manifest, and the flattened layout ----
# `! -name <basename>` excluded EVERY file with the manifest's name at any depth, so a decoy
# at reports/sentinel-shield-artifact-manifest.json — not the real manifest, not listed in
# .files — never reached the unverified-files check.
D=$(mkcase decoy)
printf '{"schema_version":"1","files":[]}\n' > "$D/artifact/reports/sentinel-shield-artifact-manifest.json"
check "a nested decoy manifest is NOT accepted as verified content" "$(vrc "$D" --expected-run-id 42)" 1
check "  and is reported as unverified content" "$(reason "$D")" "ARTIFACT_UNVERIFIED_FILES"

# upload-artifact roots the archive at the least common ancestor of the uploaded paths, so a
# real handoff arrives FLAT (no reports/ prefix). The verifier must accept that layout
# instead of failing every real handoff on a directory level.
D=$(mkcase flat)
mv "$D/artifact/reports/security-summary.json" "$D/artifact/security-summary.json"
rmdir "$D/artifact/reports"
rm -f "$D/artifact/sentinel-shield-artifact-manifest.json"
sh "$MANIFEST_TOOL" --dir "$D/artifact" --repository acme/app --run-id 42 \
	--commit "$COMMIT" --workflow sentinel-shield >/dev/null 2>&1
check "the FLAT artifact layout verifies" "$(vrc "$D" --expected-run-id 42)" 0

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '287-cross-workflow-handoff: ALL CHECKS PASSED\n'
	exit 0
fi
printf '287-cross-workflow-handoff: FAILURES PRESENT\n'
exit 1
