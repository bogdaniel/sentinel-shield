#!/bin/sh
# Sentinel Shield prod test — release publication requires a VERIFIED tag signing identity.
#
# Publication used to continue when GitHub reported `verified=false` with reason
# `unknown_key` / `unknown_signature_type`: the workflow warned and moved on. In that state
# the workflow has proved only that the tag carries signature BYTES — it has NOT authenticated
# the signer or established that the signer may publish releases. Signature material is not
# release authorization, so repository/tag write access was effectively enough to publish an
# unattributed tag.
#
# The policy is now absolute: `verification.verified == true` or no release. There is NO
# bootstrap exception, owner-approved bypass, expiring waiver, or warning-only path.
#
# The workflow step is YAML, so this suite EXTRACTS its shell body and runs it against a
# stubbed `gh`. That exercises the real published script, not a copy of it.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
WF="$ROOT/.github/workflows/release-publish.yml"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
missing() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }

[ -f "$WF" ] || { fail "missing .github/workflows/release-publish.yml"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

TAG=v9.9.9
OBJ=abcabcabcabcabcabcabcabcabcabcabcabcabca
COMMIT=1111111111111111111111111111111111111111

# --- extract the verification step's shell body ------------------------------
# The body is the `run: |` block of the step, dedented by its 10-space indent.
awk '
	/^      - name: Require a GitHub-verified tag signing identity/ { instep = 1; next }
	instep && /^[[:space:]]*run: \|/ { inrun = 1; next }
	inrun && /^      - name: / { exit }
	inrun { sub(/^          /, ""); print }
' "$WF" > "$WORK/verify.sh"
_lines=$(grep -c '' "$WORK/verify.sh" 2>/dev/null || printf '0')
if [ "$_lines" -lt 20 ]; then
	fail "could not extract the verification step from the workflow ($_lines lines) — the suite would silently test nothing"
	exit 1
fi
pass "extracted the verification step from the workflow ($_lines lines)"
sh -n "$WORK/verify.sh" || fail "the extracted step is not valid POSIX sh"

# --- gh stub -----------------------------------------------------------------
# Modes are driven by GH_MODE. Each returns what the real API would for that state.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/bin/sh
# $1=api  $2=<path>  [--jq <filter>]
_path="$2"
case "$_path" in
	*/git/ref/tags/*)
		case "${GH_MODE:-}" in
			ref-fail) exit 1 ;;
			*) printf '%s\n' "$GH_OBJ"; exit 0 ;;
		esac ;;
	*/git/tags/*)
		# The second call in the step asks for verified|reason; the third asks for signer.
		case "$3$4" in
			*signature*|*tagger*)
				if [ -n "${GH_SIGNER_FAIL:-}" ]; then exit 1; fi
				printf 'present/Release Bot <bot@example.com>\n'; exit 0 ;;
		esac
		case "${GH_MODE:-}" in
			verified)        printf 'true|valid\n' ;;
			unknown-key)     printf 'false|unknown_key\n' ;;
			unknown-sigtype) printf 'false|unknown_signature_type\n' ;;
			not-verified)    printf 'false|bad_signature\n' ;;
			expired)         printf 'false|expired_key\n' ;;
			revoked)         printf 'false|revoked_key\n' ;;
			unsigned)        printf 'false|unsigned\n' ;;
			missing-fields)  printf 'null|null\n' ;;
			malformed)       printf 'not-json-at-all\n' ;;
			empty)           printf '\n' ;;
			api-fail)        exit 1 ;;
			*)               printf 'true|valid\n' ;;
		esac
		exit 0 ;;
esac
exit 1
STUB
chmod +x "$WORK/bin/gh"

# run <mode> — run the extracted step with the stub; echo the exit code (log in $WORK/log).
run() {
	_c=0
	env PATH="$WORK/bin:$PATH" GH_MODE="$1" GH_OBJ="$OBJ" GH_TOKEN=x \
		TAG="$TAG" REPO="acme/shield" COMMIT="$COMMIT" \
		sh "$WORK/verify.sh" >"$WORK/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# 1. The ONLY publishing state.
# ---------------------------------------------------------------------------
check "verified=true with an attributable signer publishes" "$(run verified)" 0
contains "  and reports the verified identity" "$(cat "$WORK/log")" "signing identity GitHub-verified"
missing "  without emitting the failure code" "$(cat "$WORK/log")" "TAG_SIGNING_IDENTITY_UNVERIFIED"

# ---------------------------------------------------------------------------
# 2. Every unverified state blocks — including the two that used to warn.
# ---------------------------------------------------------------------------
for _case in \
	'unknown-key|the signing key is not registered on the account' \
	'unknown-sigtype|the signature type is not one GitHub can attribute' \
	'not-verified|the signature itself does not verify' \
	'expired|the signing key has expired' \
	'revoked|the signing key was revoked' \
	'unsigned|the tag carries no signature' \
	'missing-fields|the verification result is absent' \
	'malformed|the verification response is malformed' \
	'empty|the verification response is empty' \
	'api-fail|the verification API call fails' \
	'ref-fail|the tag object cannot be resolved' \
	; do
	_mode=${_case%%|*}; _why=${_case#*|}
	check "publication is BLOCKED when $_why ($_mode)" "$(run "$_mode")" 1
	case "$_mode" in
		# The two failures before the verification read have their own diagnostics; every
		# state that reaches the verdict must carry the documented failure code.
		ref-fail | api-fail) : ;;
		*) contains "  emitting TAG_SIGNING_IDENTITY_UNVERIFIED ($_mode)" "$(cat "$WORK/log")" "TAG_SIGNING_IDENTITY_UNVERIFIED" ;;
	esac
done

# ---------------------------------------------------------------------------
# 3. The diagnostic has to be actionable.
# ---------------------------------------------------------------------------
run unknown-key >/dev/null
_log=$(cat "$WORK/log")
contains "the diagnostic names the tag"            "$_log" "$TAG"
contains "the diagnostic names the tag target"     "$_log" "$OBJ"
contains "the diagnostic names the published commit" "$_log" "$COMMIT"
contains "the diagnostic names the verification reason" "$_log" "unknown_key"
contains "the diagnostic names the signer when GitHub can" "$_log" "Release Bot"
contains "the diagnostic states the remediation"   "$_log" "Register the signing key"
contains "  including where to register it"        "$_log" "SSH and GPG keys"
contains "  and that an existing tag is never rewritten" "$_log" "do NOT move, re-sign or replace"
contains "  with a runbook reference"              "$_log" "production-release-runbook.md"
# The referenced runbook section must actually exist.
if grep -q '^## `TAG_SIGNING_IDENTITY_UNVERIFIED`' "$ROOT/docs/production-release-runbook.md"; then
	pass "  and that runbook section exists"
else
	fail "  but the runbook has no TAG_SIGNING_IDENTITY_UNVERIFIED section"
fi
for _must in 'no** bootstrap exception' 'do **not** force-update' 'Register the public signing key' 'tagged but unpublished'; do
	if grep -qF "$_must" "$ROOT/docs/production-release-runbook.md"; then
		pass "  runbook states: $_must"
	else
		fail "  runbook does not state: $_must"
	fi
done

# A signer the API cannot name must not stop the failure being reported.
_c=0
env PATH="$WORK/bin:$PATH" GH_MODE=unknown-key GH_SIGNER_FAIL=1 GH_OBJ="$OBJ" GH_TOKEN=x \
	TAG="$TAG" REPO="acme/shield" COMMIT="$COMMIT" sh "$WORK/verify.sh" >"$WORK/log" 2>&1 || _c=$?
check "an unnameable signer still blocks" "$_c" 1
contains "  and the diagnostic still carries the reason" "$(cat "$WORK/log")" "unknown_key"

# ---------------------------------------------------------------------------
# 4. There is no way around it.
# ---------------------------------------------------------------------------
_wf=$(cat "$WF")
missing "the workflow has no bootstrap-exception input"   "$_wf" "bootstrap"
missing "the workflow has no bypass input"                "$_wf" "bypass"
missing "the workflow has no allow-unverified switch"     "$_wf" "allow_unverified"
missing "the workflow has no allow-unsigned switch"       "$_wf" "allow-unsigned"
missing "the workflow does not accept an exception file"  "$_wf" "exception"
# Only EXECUTABLE lines matter: the policy comment names the reasons deliberately.
if grep -vE '^[[:space:]]*#' "$WF" | grep -qE 'unknown_key|unknown_signature_type'; then
	fail "the workflow still branches on unknown_key/unknown_signature_type — those must not be special-cased at all"
else
	pass "unknown_key and unknown_signature_type are not special-cased in any executable line"
fi
# The step must be able to fail the job: no continue-on-error, no `|| true` on the verdict.
_step=$(awk '/^      - name: Require a GitHub-verified tag signing identity/{f=1} f&&/^      - name: Create GitHub Release/{exit} f' "$WF")
missing "the verification step has no continue-on-error" "$_step" "continue-on-error"
missing "the verification verdict is not swallowed by || true" "$_step" "|| true"
contains "the extracted step sets -eu" "$_step" "set -eu"

# The publish step must come AFTER the verification step, so a failure prevents it.
_vline=$(grep -n 'Require a GitHub-verified tag signing identity' "$WF" | cut -d: -f1)
_cline=$(grep -n 'Create GitHub Release' "$WF" | head -1 | cut -d: -f1)
if [ -n "$_vline" ] && [ -n "$_cline" ] && [ "$_vline" -lt "$_cline" ]; then
	pass "verification runs BEFORE the release is created"
else
	fail "the release-creation step does not follow the verification step"
fi

# The manual backfill path is the same job, so it obeys the same contract.
if grep -q 'workflow_dispatch' "$WF"; then
	_jobs=$(awk '/^jobs:/{j=1;next} j&&/^[a-z]/{exit} j&&/^  [a-z0-9_-]+:[[:space:]]*$/{n++} END{print n+0}' "$WF")
	check "manual backfill shares the single publishing job (no second, laxer path)" "$_jobs" 1
else
	fail "the workflow declares no workflow_dispatch backfill path"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '297-release-signing-identity: ALL CHECKS PASSED\n'
	exit 0
fi
printf '297-release-signing-identity: FAILURES PRESENT\n'
exit 1
