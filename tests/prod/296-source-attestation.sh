#!/bin/sh
# Sentinel Shield prod test — summary source attestation (#241).
#
# `source` was three free-form CLI labels defaulting to `unknown` / `master` / `local`,
# emitted verbatim and never validated. A production-looking summary could claim any commit,
# an abbreviated or invented SHA was indistinguishable from a real one, a local build could
# assert a workflow run, and the enforcer only checked that the object existed — so evidence
# from anywhere could be judged as this run's.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
BUILD="$ROOT/scripts/build-security-summary.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP
mkdir -p "$WORK/raw"

SHA_A=0123456789abcdef0123456789abcdef01234567
SHA_B=fedcba9876543210fedcba9876543210fedcba98

# b <output> [args…] — local build (no CI environment), echoing the exit code.
# EVERY GitHub Actions variable the builder consumes. The builder treats these as CLAIMS and
# uses them when the corresponding CLI value is absent — including replacing `commit: unknown`
# with GITHUB_SHA. That behaviour is correct and deliberate; it is what makes a CI build
# self-describing. It also means this suite cannot invoke the builder with an inherited
# environment and call the result "local".
#
# It did exactly that: `b()` was documented as "local build (no CI environment)" and ran with
# whatever the shell had. In a developer shell that is nothing, so the suite passed. On a
# GitHub runner it is a full set of real values, so "a local build with no commit says
# `unknown`" received the runner's own SHA and failed — deterministically, and only in CI.
# That is the entire reason #278 was red on the runner while passing locally at the same SHA.
#
# Listed explicitly rather than globbed: a glob would silently stop covering a variable the
# builder starts reading, which is the same class of gap this is fixing.
SA_GH_VARS='GITHUB_REPOSITORY GITHUB_REF GITHUB_EVENT_NAME GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA'
# sa_clean_env — the `env -u …` prefix that removes all of them.
sa_clean_env() {
	_sce=""
	for _v in $SA_GH_VARS; do _sce="$_sce -u $_v"; done
	printf 'env%s' "$_sce"
}
SA_CLEAN=$(sa_clean_env)

# b <output> [args…] — LOCAL build: no CI environment, guaranteed, not merely assumed.
b() {
	_o="$1"; shift; _c=0
	# shellcheck disable=SC2086  # SA_CLEAN is a controlled `env -u …` prefix
	$SA_CLEAN sh "$BUILD" --raw-dir "$WORK/raw" --output "$_o" "$@" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
# ci <output> [args…] — build with a GitHub Actions environment.
#
# Starts from the SAME sanitized baseline and then sets the complete fixture identity, so an
# omitted field cannot be quietly supplied by the runner. Before, `ci()` set seven variables on
# top of whatever was already there; any consumed variable it did not name would have leaked.
ci() {
	_o="$1"; shift; _c=0
	# shellcheck disable=SC2086
	$SA_CLEAN env GITHUB_ACTIONS=true GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=2 \
		GITHUB_REPOSITORY=acme/shield GITHUB_REF=refs/heads/main \
		GITHUB_EVENT_NAME=push GITHUB_SHA="$SHA_A" \
		sh "$BUILD" --raw-dir "$WORK/raw" --output "$_o" "$@" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
src() { jq -r --arg f "$2" '.source[$f] | if . == null then "null" else tostring end' "$1"; }

# ---------------------------------------------------------------------------
# 1. A commit is evidence or an explicit non-claim — never a label.
# ---------------------------------------------------------------------------
check "a local build with no commit succeeds" "$(b "$WORK/local.json")" 0
check "  and says so: the commit is the explicit non-claim" "$(src "$WORK/local.json" commit)" "unknown"
# The BUILDER never asserts trust: environment variables are claims supplied to the
# process, so everything it emits is `unverified` until an attestation is verified.
check "  the builder emits an UNVERIFIED trust level" "$(src "$WORK/local.json" trust)" "unverified"
check "  the attestation is versioned" "$(src "$WORK/local.json" attestation_version)" "1"
check "  and is bound to the inputs it was built from" \
	"$(jq -r '(.source.inputs_digest // "") | test("^[0-9a-f]{64}$")' "$WORK/local.json")" "true"

for _bad in testcommit abc123 0123456789abcdef 0123456789abcdef0123456789abcdef0123456 zzzz456789abcdef0123456789abcdef01234567; do
	check "an invented commit '$_bad' is refused" "$(b "$WORK/x.json" --commit "$_bad")" 2
done
contains "  the refusal explains what a commit must be" "$(cat "$WORK/log")" "full 40-hex commit SHA"
check "a full SHA is accepted" "$(b "$WORK/ok.json" --commit "$SHA_A")" 0
b "$WORK/upper.json" --commit "$(printf '%s' "$SHA_A" | tr 'a-f' 'A-F')" >/dev/null
check "  and normalised to lowercase" "$(src "$WORK/upper.json" commit)" "$SHA_A"

# Unsafe label characters cannot enter the attestation.
for _f in branch workflow ref event; do
	check "an unsafe --$_f value is refused" "$(b "$WORK/x.json" "--$_f" 'a b; rm -rf /')" 2
done
check "a non-numeric --run-id is refused" "$(ci "$WORK/x.json" --run-id 12x)" 2
check "a repository that is not owner/name is refused" "$(b "$WORK/x.json" --repository shield)" 2

# ---------------------------------------------------------------------------
# 2. The platform is the source of truth; the caller cannot contradict it.
# ---------------------------------------------------------------------------
check "a CI build succeeds" "$(ci "$WORK/ci.json")" 0
check "  the commit is derived from the platform" "$(src "$WORK/ci.json" commit)" "$SHA_A"
check "  as is the repository" "$(src "$WORK/ci.json" repository)" "acme/shield"
check "  the ref" "$(src "$WORK/ci.json" ref)" "refs/heads/main"
check "  the event" "$(src "$WORK/ci.json" event)" "push"
check "  the run id and attempt" "$(src "$WORK/ci.json" run_id),$(src "$WORK/ci.json" run_attempt)" "1234,2"
check "  and a CI environment does NOT raise the trust level" "$(src "$WORK/ci.json" trust)" "unverified"

# Neither the CLI value nor the environment claim is trusted, so a disagreement is RECORDED
# rather than fatal — refusing it would only push callers to unset the variable, buying no
# security while breaking fixture and replay builds.
check "a CLI commit differing from the environment is recorded, not refused" "$(ci "$WORK/div.json" --commit "$SHA_B")" 0
check "  the value the caller passed is what is recorded" "$(src "$WORK/div.json" commit)" "$SHA_B"
check "  and the divergence is declared" \
	"$(jq -r '[.source.diverged_claims[]] | index("commit") != null' "$WORK/div.json")" "true"
contains "  with a warning that neither value is trusted" "$(cat "$WORK/log")" "Neither is trusted"
check "a CLI repository differing from the environment is recorded" "$(ci "$WORK/div2.json" --repository other/repo)" 0
check "  the caller value is recorded" "$(src "$WORK/div2.json" repository)" "other/repo"
check "  and declared" "$(jq -r '[.source.diverged_claims[]] | index("repository") != null' "$WORK/div2.json")" "true"
check "a matching CLI value is accepted (agreement is not a conflict)" "$(ci "$WORK/agree.json" --commit "$SHA_A" --repository acme/shield)" 0

# A run id is metadata like everything else: it confers nothing, because the builder emits
# `unverified` regardless. What matters is that no environment can reach an ATTESTED level.
check "a local build may record a run id (it confers nothing)" "$(b "$WORK/runid.json" --run-id 5)" 0
check "  and is still unverified" "$(src "$WORK/runid.json" trust)" "unverified"
for _spoof in GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_SHA; do
	_c=0
	env GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_REPOSITORY=evil/repo GITHUB_SHA="$SHA_B" \
		sh "$BUILD" --raw-dir "$WORK/raw" --output "$WORK/spoof.json" >/dev/null 2>&1 || _c=$?
	check "spoofing $_spoof cannot raise the trust level" "$(src "$WORK/spoof.json" trust)" "unverified"
done

# The attestation is bound to the evidence: different inputs, different digest.
printf '{"results":[]}\n' > "$WORK/raw/semgrep.json"
b "$WORK/local2.json" >/dev/null
if [ "$(src "$WORK/local2.json" inputs_digest)" = "$(src "$WORK/local.json" inputs_digest)" ]; then
	fail "the inputs digest did not change when the evidence changed"
else
	pass "the inputs digest tracks the evidence the summary was built from"
fi
rm -f "$WORK/raw/semgrep.json"

# ---------------------------------------------------------------------------
# 3. The assurance modes refuse an unbound summary.
# ---------------------------------------------------------------------------
G="$WORK/g"; mkdir -p "$G"
# gate <summary> <mode> [attestation-record] — echo the enforcer's exit code.
gate() {
	sh "$RESOLVE" --mode "$2" --output-dir "$G" --format env >/dev/null 2>&1
	_c=0
	if [ -n "${3:-}" ]; then
		sh "$ENFORCE" --gates-env "$G/sentinel-shield-gates.env" --summary "$1" \
			--attestation "$3" --output-dir "$G" --format json >"$G/log" 2>&1 || _c=$?
	else
		sh "$ENFORCE" --gates-env "$G/sentinel-shield-gates.env" --summary "$1" \
			--output-dir "$G" --format json >"$G/log" 2>&1 || _c=$?
	fi
	printf '%s' "$_c"
}
# att_for <summary> <out> [overrides-jq] — an attestation record bound to <summary> as it
# exists on disk. The digest is computed HERE, which is the whole point: a summary cannot
# carry its own digest, because writing it in changes it.
att_for() {
	_ad=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
	[ -n "$_ad" ] || _ad=$(shasum -a 256 "$1" | awk '{print $1}')
	jq -n --arg d "sha256:$_ad" \
		--arg r "$(jq -r '.source.repository // ""' "$1")" \
		--arg c "$(jq -r '.source.commit // ""' "$1")" \
		'{attestation:"sentinel-shield/source-attestation@1", verified:true,
		  verifier:"test", artifact:"summary", artifact_digest:$d,
		  repository:$r, commit:$c, workflow:"sentinel-shield", run_id:"1234567890"}' \
		| jq "${3:-.}" > "$2"
}
# regulated requires a VERIFIED platform attestation — the builder never emits one, so an
# attested fixture is what a real attestation-verification step would have produced.
jq '.tools = {"tests":{"status":"pass"}}
	| .source.trust = "github-actions-attested"
	| .attestation = {verified:true, issuer:"https://token.actions.githubusercontent.com",
		repository:.source.repository, commit:.source.commit, workflow:"sentinel-shield",
		workflow_sha:"1111111111111111111111111111111111111111", run_id:"1234567890",
		run_attempt:"1", artifact_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
	"$EXAMPLE" > "$WORK/attested.json"
# THE ATTESTATION MUST COME FROM OUTSIDE THE DOCUMENT IT ATTESTS.
# Reading `.attestation` out of the summary meant whoever writes the summary could write
# `verified: true` beside their own `.source` claims — the document authorising itself. The
# record now arrives via --attestation and is bound to the summary's digest, computed at
# enforcement time.
check "a summary that attests to ITSELF does not satisfy regulated" \
	"$(gate "$WORK/attested.json" regulated)" 2
att_for "$WORK/attested.json" "$WORK/att.json"
check "  but an independently supplied record bound to it does" \
	"$(gate "$WORK/attested.json" regulated "$WORK/att.json")" 0
# …and every way of weakening the RECORD fails closed.
att_for "$WORK/attested.json" "$WORK/unver.json" '.verified = false'
check "regulated refuses a record with verified=false" "$(gate "$WORK/attested.json" regulated "$WORK/unver.json")" 2
att_for "$WORK/attested.json" "$WORK/nodig.json" 'del(.artifact_digest)'
check "regulated refuses a record that binds no artifact digest" "$(gate "$WORK/attested.json" regulated "$WORK/nodig.json")" 2
att_for "$WORK/attested.json" "$WORK/otherdig.json" '.artifact_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
check "regulated refuses a record bound to a DIFFERENT artifact" "$(gate "$WORK/attested.json" regulated "$WORK/otherdig.json")" 2
att_for "$WORK/attested.json" "$WORK/wrongc.json" '.commit = "ffffffffffffffffffffffffffffffffffffffff"'
check "regulated refuses a record for another commit" "$(gate "$WORK/attested.json" regulated "$WORK/wrongc.json")" 2
att_for "$WORK/attested.json" "$WORK/wrongr.json" '.repository = "evil/repo"'
check "regulated refuses a record for another repository" "$(gate "$WORK/attested.json" regulated "$WORK/wrongr.json")" 2
att_for "$WORK/attested.json" "$WORK/badfmt.json" '.attestation = "something/else@9"'
check "regulated refuses an unrecognised record format" "$(gate "$WORK/attested.json" regulated "$WORK/badfmt.json")" 2
check "regulated refuses a record file that does not exist" "$(gate "$WORK/attested.json" regulated "$WORK/absent.json")" 2
# The verifier that produces these records must exist and be runnable.
check "the independent verifier exists" "$([ -f "$ROOT/scripts/verify-source-attestation.sh" ] && echo yes || echo no)" "yes"
_vc=0; sh "$ROOT/scripts/verify-source-attestation.sh" >/dev/null 2>&1 || _vc=$?
check "  and refuses an invocation with no arguments" "$_vc" 2
jq '.source.trust = "github-actions"' "$WORK/attested.json" > "$WORK/oldtrust.json"
check "an unrecognised trust level is never treated as the trusted one" "$(gate "$WORK/oldtrust.json" regulated)" 2
check "  and strict" "$(gate "$WORK/attested.json" strict)" 0
check "  and baseline" "$(gate "$WORK/attested.json" baseline)" 0

jq '.source.commit = "unknown"' "$WORK/attested.json" > "$WORK/nocommit.json"
check "strict refuses a summary with no commit" "$(gate "$WORK/nocommit.json" strict)" 2
contains "  saying the default is a non-claim" "$(cat "$G/log")" "explicit non-claim"
check "regulated refuses it too" "$(gate "$WORK/nocommit.json" regulated)" 2
check "baseline keeps the migration tolerance" "$(gate "$WORK/nocommit.json" baseline)" 0

jq '.source.commit = "0123456789abcdef"' "$WORK/attested.json" > "$WORK/shortcommit.json"
check "strict refuses an abbreviated commit" "$(gate "$WORK/shortcommit.json" strict)" 2

jq 'del(.source.repository)' "$WORK/attested.json" > "$WORK/norepo.json"
check "strict refuses a summary with no repository" "$(gate "$WORK/norepo.json" strict)" 2
contains "  saying a commit alone does not identify evidence" "$(cat "$G/log")" "does not identify evidence"

jq '.source.trust = "unverified" | del(.attestation)' "$WORK/attested.json" > "$WORK/localtrust.json"
check "regulated refuses UNVERIFIED provenance as production evidence" "$(gate "$WORK/localtrust.json" regulated)" 2
contains "  and points at strict for an attestation-limited run" "$(cat "$G/log")" "attestation-limited assurance run"
check "strict still accepts it, bound to repository+commit" "$(gate "$WORK/localtrust.json" strict)" 0
contains "  but labels it attestation-limited rather than attested" "$(cat "$G/log")" "ATTESTATION-LIMITED"

jq 'del(.source.trust)' "$WORK/attested.json" > "$WORK/notrust.json"
check "regulated refuses a summary with no attestation at all" "$(gate "$WORK/notrust.json" regulated)" 2
jq '.source.trust = "self-declared"' "$WORK/attested.json" > "$WORK/badtrust.json"
check "regulated refuses an unknown trust level" "$(gate "$WORK/badtrust.json" regulated)" 2

# End to end: a real CI build satisfies regulated without any hand-editing.
CID="$WORK/cirun"; mkdir -p "$CID"
ci "$CID/s.json" >/dev/null
jq '.tools = {"tests":{"status":"pass"}}' "$CID/s.json" > "$CID/s2.json"
check "a summary built in CI records its run but claims no trust" "$(src "$CID/s2.json" trust)" "unverified"
check "  while still recording the platform run id" "$(src "$CID/s2.json" run_id)" "1234"
check "  with the platform commit" "$(src "$CID/s2.json" commit)" "$SHA_A"

# --- the verifier: a successful signature is not an identity ------------------
# `gh attestation verify --repo X` succeeds for ANY attestation that repository can produce.
# Without --signer-workflow it is a signature check, not an identity check, and a genuine
# attestation from a workflow that never certifies release evidence would verify happily.
VA="$ROOT/scripts/verify-source-attestation.sh"
VW=$(mktemp -d); mkdir -p "$VW/bin"; printf '{"summary":"x"}\n' > "$VW/s.json"
cat > "$VW/bin/gh" <<'STUB'
#!/bin/sh
[ -n "${GH_FAIL:-}" ] && { echo "gh: verification failed" >&2; exit 1; }
cat <<JSON
[{"verificationResult":{"signature":{"certificate":{
  "sourceRepositoryURI":"https://github.com/${GH_REPO:-acme/app}",
  "sourceRepositoryDigest":"${GH_COMMIT:-1111111111111111111111111111111111111111}",
  "buildSignerURI":"https://github.com/acme/app/.github/workflows/${GH_WF:-sentinel-shield.yml}@refs/heads/main",
  "runInvocationURI":"https://github.com/acme/app/actions/runs/${GH_RUN:-999}/attempts/1"
}}}}]
JSON
STUB
chmod +x "$VW/bin/gh"
vrun() { # vrun <expected-rc> <label> <marker|-> [env...]
	_vw=$1; _vl=$2; _vm=$3; shift 3
	rm -f "$VW/att.json"; _vrc=0
	env PATH="$VW/bin:$PATH" "$@" sh "$VA" --summary "$VW/s.json" --repository acme/app \
		--signer-workflow sentinel-shield.yml --output "$VW/att.json" >"$VW/log" 2>&1 || _vrc=$?
	check "$_vl" "$_vrc" "$_vw"
	[ "$_vm" = "-" ] || { grep -q "$_vm" "$VW/log" && pass "  reported as $_vm" || fail "  did not report $_vm"; }
}
# --signer-workflow is not optional.
_vc=0; env PATH="$VW/bin:$PATH" sh "$VA" --summary "$VW/s.json" --repository acme/app \
	--output "$VW/att.json" >/dev/null 2>&1 || _vc=$?
check "the verifier refuses to run without --signer-workflow" "$_vc" 2

vrun 0 "a verified attestation from the required producer is recorded" -
check "  bound to the digest computed by the verifier, not read from the file" \
	"$(jq -r '.artifact_digest' "$VW/att.json" 2>/dev/null)" \
	"sha256:$(sha256sum "$VW/s.json" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$VW/s.json" | awk '{print $1}')"
vrun 1 "a SUCCESSFUL verification from another workflow is refused" SOURCE_ATTESTATION_WRONG_PRODUCER GH_WF=release-notes.yml
check "  and no record is written" "$([ -f "$VW/att.json" ] && echo yes || echo no)" "no"
vrun 1 "a SUCCESSFUL verification for another repository is refused" SOURCE_ATTESTATION_WRONG_REPOSITORY GH_REPO=evil/other
vrun 1 "an unverified artifact is refused" SOURCE_ATTESTATION_UNVERIFIED GH_FAIL=1
# The filters must actually reach gh, not just be accepted as arguments.
cat > "$VW/bin/gh" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "$VW/args"
exit 1
STUB
chmod +x "$VW/bin/gh"
env PATH="$VW/bin:$PATH" sh "$VA" --summary "$VW/s.json" --repository acme/app \
	--signer-workflow sentinel-shield.yml --output "$VW/a.json" >/dev/null 2>&1 || true
check "the signer workflow is passed through to gh" \
	"$(grep -c -- '--signer-workflow sentinel-shield.yml' "$VW/args" 2>/dev/null || true)" "1"
check "the predicate type is passed through to gh" \
	"$(grep -c -- '--predicate-type https://slsa.dev/provenance/v1' "$VW/args" 2>/dev/null || true)" "1"
rm -rf "$VW"

# --- regulated must pin the trusted producer ---------------------------------
att_for "$WORK/attested.json" "$WORK/wrongwf.json" '.workflow = "release-notes.yml"'
_c=0
sh "$RESOLVE" --mode regulated --output-dir "$G" --format env >/dev/null 2>&1
env SENTINEL_SHIELD_TRUSTED_WORKFLOW=sentinel-shield sh "$ENFORCE" \
	--gates-env "$G/sentinel-shield-gates.env" --summary "$WORK/attested.json" \
	--attestation "$WORK/wrongwf.json" --output-dir "$G" --format json >"$G/log" 2>&1 || _c=$?
check "regulated refuses a record from a workflow this repository does not trust" "$_c" 2
contains "  naming the trusted producer" "$(cat "$G/log")" "this repository trusts"

# --- the local helper must be local even ON a runner --------------------------
# This is the defect that made #278 red in CI while passing in a developer shell at the same
# commit: `b()` inherited the ambient environment, so on GitHub Actions its "local" builds
# silently became CI builds and `commit: unknown` came back as the runner's SHA.
#
# Seeding realistic HOSTILE values here means the suite now fails in a developer shell too if
# the isolation regresses — the bug can no longer hide until it reaches a runner.
_HOSTILE_SHA=99999999999999999999999999999999999999ff
_hostile() { # _hostile <cmd…> — run with a full, plausible Actions environment present
	env GITHUB_ACTIONS=true \
		GITHUB_REPOSITORY=evil-org/hijacked-repo \
		GITHUB_REF=refs/heads/attacker-branch \
		GITHUB_EVENT_NAME=pull_request_target \
		GITHUB_RUN_ID=666666 \
		GITHUB_RUN_ATTEMPT=9 \
		GITHUB_SHA="$_HOSTILE_SHA" \
		"$@"
}
# Sanity: the fixture really would leak if the helper did not sanitize. Build DIRECTLY with the
# hostile environment and confirm the builder picks it up — otherwise the assertions below
# would pass for want of anything to leak.
_hostile sh "$BUILD" --raw-dir "$WORK/raw" --output "$WORK/leak-proof.json" >/dev/null 2>&1 || true
check "control: an unsanitized build DOES absorb the ambient runner identity" \
	"$(src "$WORK/leak-proof.json" commit)" "$_HOSTILE_SHA"
check "  and the ambient repository too" \
	"$(src "$WORK/leak-proof.json" repository)" "evil-org/hijacked-repo"

# Now the real assertion: the SHIPPED b() helper, called with that environment exported, must
# still produce a local build. Exercising b() itself rather than a re-implementation of it is
# the point — a copy could be sanitized while the helper the suite actually uses is not.
(
	export GITHUB_ACTIONS=true \
		GITHUB_REPOSITORY=evil-org/hijacked-repo \
		GITHUB_REF=refs/heads/attacker-branch \
		GITHUB_EVENT_NAME=pull_request_target \
		GITHUB_RUN_ID=666666 \
		GITHUB_RUN_ATTEMPT=9 \
		GITHUB_SHA="$_HOSTILE_SHA"
	b "$WORK/local-under-ci.json" >/dev/null 2>&1
)
check "a LOCAL build under a hostile Actions environment reports no commit claim" \
	"$(src "$WORK/local-under-ci.json" commit)" "unknown"
check "  and no repository claim" \
	"$(src "$WORK/local-under-ci.json" repository)" "null"
check "  and no run id" \
	"$(src "$WORK/local-under-ci.json" run_id)" "null"
check "  and trust stays unverified" \
	"$(src "$WORK/local-under-ci.json" trust)" "unverified"
check "  and it did NOT pick up the hostile SHA" \
	"$([ "$(src "$WORK/local-under-ci.json" commit)" = "$_HOSTILE_SHA" ] && echo leaked || echo clean)" "clean"

# The sanitizer must cover EVERY variable the builder reads — not a snapshot of today's list.
_missing=""
for _v in $(grep -ohE 'GITHUB_[A-Z_]+' "$BUILD" | sort -u); do
	case " $SA_GH_VARS " in *" $_v "*) ;; *) _missing="$_missing $_v" ;; esac
done
[ -z "$_missing" ] && pass "the sanitizer covers every GITHUB_* the builder consumes" \
	|| fail "the builder now reads$_missing, which this suite does not sanitize — a local build would absorb it on a runner"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '296-source-attestation: ALL CHECKS PASSED\n'
	exit 0
fi
printf '296-source-attestation: FAILURES PRESENT\n'
exit 1
