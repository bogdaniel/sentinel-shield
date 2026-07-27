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
b() { _o="$1"; shift; _c=0; sh "$BUILD" --raw-dir "$WORK/raw" --output "$_o" "$@" >"$WORK/log" 2>&1 || _c=$?; printf '%s' "$_c"; }
# ci <output> [args…] — build with a GitHub Actions environment.
ci() {
	_o="$1"; shift; _c=0
	env GITHUB_ACTIONS=true GITHUB_RUN_ID=1234 GITHUB_RUN_ATTEMPT=2 \
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
check "  the trust level is local" "$(src "$WORK/local.json" trust)" "local"
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
check "  and the trust level is the platform" "$(src "$WORK/ci.json" trust)" "github-actions"

check "a CLI commit contradicting the platform is refused" "$(ci "$WORK/x.json" --commit "$SHA_B")" 2
contains "  and says the summary may not be relabelled" "$(cat "$WORK/log")" "may not be relabelled onto another commit"
check "a CLI repository contradicting the platform is refused" "$(ci "$WORK/x.json" --repository other/repo)" 2
check "a CLI run-id contradicting the platform is refused" "$(ci "$WORK/x.json" --run-id 9999)" 2
check "a matching CLI value is accepted (agreement is not a conflict)" "$(ci "$WORK/agree.json" --commit "$SHA_A" --repository acme/shield)" 0

# A local build may not impersonate a run.
check "a local build claiming a run id is refused" "$(b "$WORK/x.json" --run-id 5)" 2
contains "  and says it is attestation-limited" "$(cat "$WORK/log")" "attestation-limited"
check "a local build claiming a run attempt is refused" "$(b "$WORK/x.json" --run-attempt 2)" 2

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
# gate <summary> <mode> — echo the enforcer's exit code.
gate() {
	sh "$RESOLVE" --mode "$2" --output-dir "$G" --format env >/dev/null 2>&1
	_c=0
	sh "$ENFORCE" --gates-env "$G/sentinel-shield-gates.env" --summary "$1" \
		--output-dir "$G" --format json >"$G/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
jq '.tools = {"tests":{"status":"pass"}}' "$EXAMPLE" > "$WORK/attested.json"
check "a fully attested summary passes regulated" "$(gate "$WORK/attested.json" regulated)" 0
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

jq '.source.trust = "local"' "$WORK/attested.json" > "$WORK/localtrust.json"
check "regulated refuses a LOCAL build as production evidence" "$(gate "$WORK/localtrust.json" regulated)" 2
contains "  and points at strict for a local assurance run" "$(cat "$G/log")" "use 'strict' for a local assurance run"
check "strict still accepts a local build" "$(gate "$WORK/localtrust.json" strict)" 0

jq 'del(.source.trust)' "$WORK/attested.json" > "$WORK/notrust.json"
check "regulated refuses a summary with no attestation at all" "$(gate "$WORK/notrust.json" regulated)" 2
jq '.source.trust = "self-declared"' "$WORK/attested.json" > "$WORK/badtrust.json"
check "regulated refuses an unknown trust level" "$(gate "$WORK/badtrust.json" regulated)" 2

# End to end: a real CI build satisfies regulated without any hand-editing.
CID="$WORK/cirun"; mkdir -p "$CID"
ci "$CID/s.json" >/dev/null
jq '.tools = {"tests":{"status":"pass"}}' "$CID/s.json" > "$CID/s2.json"
check "a summary built in CI is bound to its run without hand-editing" "$(src "$CID/s2.json" trust)" "github-actions"
check "  with the platform commit" "$(src "$CID/s2.json" commit)" "$SHA_A"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '296-source-attestation: ALL CHECKS PASSED\n'
	exit 0
fi
printf '296-source-attestation: FAILURES PRESENT\n'
exit 1
