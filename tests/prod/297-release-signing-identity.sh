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
_lines=$(wc -l < "$WORK/verify.sh" 2>/dev/null || printf '0'); _lines=${_lines##* }
if [ "$_lines" -lt 20 ]; then
	fail "could not extract the verification step from the workflow ($_lines lines) — the suite would silently test nothing"
	exit 1
fi
pass "extracted the verification step from the workflow ($_lines lines)"
sh -n "$WORK/verify.sh" || fail "the extracted step is not valid POSIX sh"

# --- gh stub -----------------------------------------------------------------
# Modes are driven by GH_MODE. Each returns what the real API would for that state.
mkdir -p "$WORK/bin"
# The step retries three times with a backoff. The stub fails instantly, so the sleeps are
# pure dead time: shadow `sleep` on PATH to keep the retry COUNT while dropping the wait.
cat > "$WORK/bin/sleep" <<'SLEEP'
#!/bin/sh
exit 0
SLEEP
chmod +x "$WORK/bin/sleep"
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
		# The step makes three different reads against this path; dispatch on the jq filter.
		case "$3$4" in
			*signature*|*tagger*)
				if [ -n "${GH_TAGGER_FAIL:-}" ]; then exit 1; fi
				printf 'present/Release Bot <bot@example.com>\n'; exit 0 ;;
			*object.type*)
				# Peeling the verified tag object to the commit being published.
				case "${GH_PEEL:-}" in
					fail)      exit 1 ;;
					mismatch)  printf 'commit|9999999999999999999999999999999999999999\n'; exit 0 ;;
					nested)    printf 'tag|%s\n' "$GH_OBJ"; exit 0 ;;
					not-commit) printf 'tree|1234567890123456789012345678901234567890\n'; exit 0 ;;
					*)         printf 'commit|%s\n' "$GH_COMMIT"; exit 0 ;;
				esac ;;
		esac
		case "${GH_MODE:-}" in
			verified)        printf 'true|valid\n' ;;
			unknown-key)     printf 'false|unknown_key\n' ;;
			unknown-sigtype) printf 'false|unknown_signature_type\n' ;;
			not-verified)    printf 'false|bad_signature\n' ;;
			expired)         printf 'false|expired_key\n' ;;
			revoked)         printf 'false|revoked_key\n' ;;
			unsigned)        printf 'false|unsigned\n' ;;
			bad-email) printf 'false|bad_email\n' ;;
			unverified-email) printf 'false|unverified_email\n' ;;
			not-signing-key) printf 'false|not_signing_key\n' ;;
			malformed-sig) printf 'false|malformed_signature\n' ;;
			invalid) printf 'false|invalid\n' ;;
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
		GH_COMMIT="$COMMIT" GH_PEEL="${2:-}" \
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
	'bad-email|the signature email does not match the account' \
	'unverified-email|the signing email is unverified' \
	'not-signing-key|the key is not a signing key' \
	'malformed-sig|the signature is malformed' \
	'invalid|the verification result is the literal invalid state' \
	'missing-fields|the verification result is absent' \
	'malformed|the verification response is malformed' \
	'empty|the verification response is empty' \
	'api-fail|the verification API call fails' \
	'ref-fail|the tag object cannot be resolved' \
	; do
	_mode=${_case%%|*}; _why=${_case#*|}
	check "publication is BLOCKED when $_why ($_mode)" "$(run "$_mode")" 1
	case "$_mode" in
		# Only resolving the tag object fails BEFORE the verification read and has its own
		# diagnostic; every state that reaches the verdict — api-fail included — must carry
		# the documented failure code.
		ref-fail) : ;;
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
contains "the diagnostic names the tagger when GitHub can" "$_log" "Release Bot"
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
env PATH="$WORK/bin:$PATH" GH_MODE=unknown-key GH_TAGGER_FAIL=1 GH_OBJ="$OBJ" GH_TOKEN=x \
	GH_COMMIT="$COMMIT" TAG="$TAG" REPO="acme/shield" COMMIT="$COMMIT" \
	sh "$WORK/verify.sh" >"$WORK/log" 2>&1 || _c=$?
check "an unnameable tagger still blocks" "$_c" 1
contains "  and the diagnostic still carries the reason" "$(cat "$WORK/log")" "unknown_key"

# ---------------------------------------------------------------------------
# 4. There is no way around it.
# ---------------------------------------------------------------------------
_wf=$(cat "$WF")
missing "the workflow has no bootstrap-exception input"   "$_wf" "bootstrap"
# Scoped to a workflow INPUT named bypass. A substring check would now match the
# `bypass_actors` inspection in the tag-protection gate, which is the opposite of a bypass.
if grep -nE '^[[:space:]]+bypass[a-z_]*:' "$WF" | grep -vq 'bypass_actors'; then
	fail "the workflow declares a bypass input"
else
	pass "the workflow has no bypass input"
fi
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

# ---------------------------------------------------------------------------
# 5. A VERIFIED signature on one object proves nothing about another commit.
# ---------------------------------------------------------------------------
# The signature was verified against the tag OBJECT. Publication is of a COMMIT. If the tag ref
# moved between the checkout and the API read, the verified object belongs to a different
# commit, and the old flow only noticed after `gh release create` had already published.
check "a verified tag whose object peels to ANOTHER commit is refused" "$(run verified mismatch)" 1
contains "  named as a target mismatch" "$(cat "$WORK/log")" "TAG_TARGET_COMMIT_MISMATCH"
contains "  reporting the commit actually pointed at" "$(cat "$WORK/log")" "9999999999999999999999999999999999999999"
contains "  and the commit being published" "$(cat "$WORK/log")" "$COMMIT"
contains "  with the tag-immutability remediation" "$(cat "$WORK/log")" "do NOT move or re-push"
check "a tag object that cannot be peeled is refused" "$(run verified fail)" 1
contains "  named as an unresolved target" "$(cat "$WORK/log")" "TAG_TARGET_UNRESOLVED"
check "a tag object that does not peel to a commit is refused" "$(run verified not-commit)" 1
contains "  also named as an unresolved target" "$(cat "$WORK/log")" "TAG_TARGET_UNRESOLVED"
check "a tag pointing at a tag is peeled, not refused outright" "$(run verified nested)" 1

# ---------------------------------------------------------------------------
# 6. The ref must still be the verified object at the moment of publication.
# ---------------------------------------------------------------------------
# Verification happens in an earlier step; `gh release create --verify-tag` acts on the tag as
# it exists NOW. A ref moved in between must stop publication BEFORE the release is created —
# detecting it afterwards means a wrong release already exists.
awk '
	/^      - name: Create GitHub Release/ { instep = 1; next }
	instep && /^[[:space:]]*run: \|/ { inrun = 1; next }
	inrun && /^      - name: / { exit }
	inrun { sub(/^          /, ""); print }
' "$WF" > "$WORK/create.sh"
_clines=$(wc -l < "$WORK/create.sh" 2>/dev/null || printf '0'); _clines=${_clines##* }
if [ "$_clines" -lt 15 ]; then
	fail "could not extract the release-creation step ($_clines lines) — the moved-ref checks would test nothing"
else
	pass "extracted the release-creation step ($_clines lines)"
fi
sh -n "$WORK/create.sh" || fail "the extracted creation step is not valid POSIX sh"

# A `gh` stub that RECORDS whether a release was ever created.
cat > "$WORK/bin/gh" <<'STUB2'
#!/bin/sh
# Records every release call so the test can prove none was made.
case "$1 $2" in
	"release create" | "release view")
		printf '%s %s\n' "$1" "$2" >> "$GH_CALLS"
		[ "$1 $2" = "release view" ] && exit 1
		exit 0 ;;
esac
case "$2" in
	*/git/ref/tags/*)
		# `none` = the ref could not be read at all, which is not the same as reading a
		# ref that now points somewhere else.
		[ "${GH_NOW:-}" = none ] && exit 1
		printf '%s\n' "${GH_NOW:-$GH_OBJ}"; exit 0 ;;
	*/git/tags/*)
		# The publish-time re-read of the verification verdict.
		[ "${GH_VNOW:-}" = none ] && exit 1
		printf '%s\n' "${GH_VNOW:-true}"; exit 0 ;;
esac
exit 1
STUB2
chmod +x "$WORK/bin/gh"

runcreate() { # runcreate <ref-now> -> exit code; calls recorded in $WORK/calls
	: > "$WORK/calls"
	_c=0
	env PATH="$WORK/bin:$PATH" GH_TOKEN=x GH_OBJ="$OBJ" GH_NOW="$1" GH_CALLS="$WORK/calls" \
		TAG="$TAG" REPO="acme/shield" NOTES="/dev/null" KIND="" VERIFIED_OBJ="$OBJ" \
		sh "$WORK/create.sh" >"$WORK/clog" 2>&1 || _c=$?
	printf '%s' "$_c"
}

check "publication proceeds while the ref still holds the verified object" "$(runcreate "$OBJ")" 0
_moved=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
check "a ref MOVED after verification refuses to publish" "$(runcreate "$_moved")" 1
contains "  named as a moved ref" "$(cat "$WORK/clog")" "TAG_REF_MOVED"
contains "  reporting both objects" "$(cat "$WORK/clog")" "$_moved"
if grep -q 'release create' "$WORK/calls" 2>/dev/null; then
	fail "a release was CREATED for a tag whose ref had moved — the check ran too late"
else
	pass "  and NO release-creation call was made"
fi
# The verification STATE can change between the check and the write — a key revoked or
# removed in between. The publisher re-reads the verdict for the same object.
runcreate2() { # runcreate2 <verified-now> -> exit code
	: > "$WORK/calls"
	_c=0
	env PATH="$WORK/bin:$PATH" GH_TOKEN=x GH_OBJ="$OBJ" GH_NOW="$OBJ" GH_VNOW="$1" \
		GH_CALLS="$WORK/calls" TAG="$TAG" REPO="acme/shield" NOTES="/dev/null" KIND="" \
		VERIFIED_OBJ="$OBJ" sh "$WORK/create.sh" >"$WORK/clog" 2>&1 || _c=$?
	printf '%s' "$_c"
}
check "a signing identity that stops verifying before the write refuses to publish" "$(runcreate2 false)" 1
contains "  named as an unverified identity" "$(cat "$WORK/clog")" "TAG_SIGNING_IDENTITY_UNVERIFIED"
if grep -q 'release create' "$WORK/calls" 2>/dev/null; then
	fail "a release was created after the signing identity stopped verifying"
else
	pass "  and NO release-creation call was made"
fi
check "an unreadable verification state refuses to publish" "$(runcreate2 none)" 1

check "an unreadable ref refuses to publish" "$(runcreate none)" 1
contains "  named as an unresolved ref" "$(cat "$WORK/clog")" "TAG_REF_UNRESOLVED"
if grep -q 'release create' "$WORK/calls" 2>/dev/null; then
	fail "a release was created despite an unreadable tag ref"
else
	pass "  and NO release-creation call was made"
fi

# ---------------------------------------------------------------------------
# 7. The tag must be UNMOVABLE, not merely re-checked.
# ---------------------------------------------------------------------------
# The final ref check and `gh release create --verify-tag` are separate API operations, so a
# writer able to move the ref in between could still have a release published for an unverified
# target. Narrowing that interval does not close it; an ACTIVE, non-bypassable tag ruleset does.
# Everything below fails closed: what cannot be inspected is never assumed benign.
awk '
	/^      - name: Require an enforced, non-bypassable tag ruleset/ { instep = 1; next }
	instep && /^[[:space:]]*run: \|/ { inrun = 1; next }
	inrun && /^      - name: / { exit }
	inrun { sub(/^          /, ""); print }
' "$WF" > "$WORK/ruleset.sh"
_rlines=$(wc -l < "$WORK/ruleset.sh" 2>/dev/null); _rlines=${_rlines##* }
if [ "${_rlines:-0}" -lt 20 ]; then
	fail "could not extract the tag-ruleset step ($_rlines lines) — these checks would test nothing"
else
	pass "extracted the tag-ruleset step ($_rlines lines)"
fi
sh -n "$WORK/ruleset.sh" || fail "the extracted tag-ruleset step is not valid POSIX sh"

# A `gh` stub whose ruleset answers are driven by two files.
cat > "$WORK/bin/gh" <<'RSTUB'
#!/bin/sh
case "$2" in
	*/rulesets\?includes_parents=true) [ -f "$GH_RS_LIST" ] || exit 1; cat "$GH_RS_LIST"; exit 0 ;;
	*/rulesets/*) [ -f "$GH_RS_DETAIL" ] || exit 1; cat "$GH_RS_DETAIL"; exit 0 ;;
esac
exit 1
RSTUB
chmod +x "$WORK/bin/gh"

rs() { # rs <list-json> <detail-json> -> exit code; log in $WORK/rslog
	printf '%s' "$1" > "$WORK/rs-list.json"
	printf '%s' "$2" > "$WORK/rs-detail.json"
	_c=0
	env PATH="$WORK/bin:$PATH" GH_TOKEN=x TAG="$TAG" REPO="acme/shield" \
		GH_RS_LIST="$WORK/rs-list.json" GH_RS_DETAIL="$WORK/rs-detail.json" \
		sh "$WORK/ruleset.sh" >"$WORK/rslog" 2>&1 || _c=$?
	printf '%s' "$_c"
}
_LIST='[{"id":1,"target":"tag"}]'
_ok='{"id":1,"target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"update"},{"type":"deletion"}],"bypass_actors":[]}'

check "an active ruleset restricting update+deletion permits publication" "$(rs "$_LIST" "$_ok")" 0
contains "  and says protection was proven" "$(cat "$WORK/rslog")" "tag protection proven"

# enforcement must be ACTIVE: evaluate/disabled report violations, they do not prevent them.
for _mode in evaluate disabled; do
	_d=$(printf '%s' "$_ok" | sed "s/\"enforcement\":\"active\"/\"enforcement\":\"$_mode\"/")
	check "enforcement '$_mode' is refused" "$(rs "$_LIST" "$_d")" 1
	contains "  named as unproven protection ($_mode)" "$(cat "$WORK/rslog")" "TAG_PROTECTION_UNPROVEN"
done

# BOTH restrictions are required.
_d=$(printf '%s' "$_ok" | sed 's/{"type":"deletion"}//; s/,]/]/')
check "a ruleset without a deletion restriction is refused" "$(rs "$_LIST" "$_d")" 1
_d=$(printf '%s' "$_ok" | sed 's/{"type":"update"},//')
check "a ruleset without an update restriction is refused" "$(rs "$_LIST" "$_d")" 1

# THE OMISSION TRAP: GitHub omits bypass_actors unless the caller can read the ruleset. Absent
# must mean "could not be proven", never "there are no bypasses".
_d=$(printf '%s' "$_ok" | sed 's/,"bypass_actors":\[\]//')
check "an ABSENT bypass_actors field is refused, not read as empty" "$(rs "$_LIST" "$_d")" 1
contains "  explaining that the bypasses could not be inspected" "$(cat "$WORK/rslog")" "CANNOT be inspected"

# An always-bypass defeats the protection during the publication interval.
for _actor in '{"actor_type":"OrganizationAdmin","actor_id":1,"bypass_mode":"always"}' \
	'{"actor_type":"RepositoryRole","actor_id":5,"bypass_mode":"always"}' \
	'{"actor_type":"Integration","actor_id":99,"bypass_mode":"always"}' \
	'{"actor_type":"Team","actor_id":7,"bypass_mode":"always"}'; do
	_d=$(printf '%s' "$_ok" | sed "s/\"bypass_actors\":\[\]/\"bypass_actors\":[$_actor]/")
	check "an ALWAYS bypass is refused ($(printf '%s' "$_actor" | sed 's/.*actor_type":"\([A-Za-z]*\)".*/\1/'))" "$(rs "$_LIST" "$_d")" 1
	contains "  naming the bypass" "$(cat "$WORK/rslog")" "ALWAYS bypass"
done

# The ruleset must cover THIS tag.
_d=$(printf '%s' "$_ok" | sed 's#refs/tags/v\*#refs/tags/release-*#')
check "a ruleset whose pattern does not cover the tag is refused" "$(rs "$_LIST" "$_d")" 1
_d=$(printf '%s' "$_ok" | sed 's#"include":\["refs/tags/v\*"\]#"include":["~ALL"]#')
check "a ~ALL ruleset covers the tag" "$(rs "$_LIST" "$_d")" 0
_d=$(printf '%s' "$_ok" | sed 's#"exclude":\[\]#"exclude":["refs/tags/v*"]#')
check "an EXCLUDED tag is not covered" "$(rs "$_LIST" "$_d")" 1

# A branch ruleset is not tag protection.
check "a ruleset targeting branches does not protect the tag" "$(rs '[{"id":1,"target":"branch"}]' "$_ok")" 1
check "no rulesets at all is refused" "$(rs '[]' "$_ok")" 1

# Unreadable API state fails closed.
_c=0
env PATH="$WORK/bin:$PATH" GH_TOKEN=x TAG="$TAG" REPO="acme/shield" \
	GH_RS_LIST="$WORK/does-not-exist" GH_RS_DETAIL="$WORK/rs-detail.json" \
	sh "$WORK/ruleset.sh" >"$WORK/rslog" 2>&1 || _c=$?
check "an unreadable rulesets list fails closed" "$_c" 1
contains "  saying protection could not be inspected" "$(cat "$WORK/rslog")" "not protection that exists"
_c=0
env PATH="$WORK/bin:$PATH" GH_TOKEN=x TAG="$TAG" REPO="acme/shield" \
	GH_RS_LIST="$WORK/rs-list.json" GH_RS_DETAIL="$WORK/does-not-exist" \
	sh "$WORK/ruleset.sh" >"$WORK/rslog" 2>&1 || _c=$?
check "an unreadable ruleset detail fails closed" "$_c" 1

# The gate must run BEFORE the release is created.
_rline=$(grep -n 'Require an enforced, non-bypassable tag ruleset' "$WF" | cut -d: -f1)
_cline2=$(grep -n 'Create GitHub Release' "$WF" | head -1 | cut -d: -f1)
if [ -n "$_rline" ] && [ -n "$_cline2" ] && [ "$_rline" -lt "$_cline2" ]; then
	pass "tag protection is proven BEFORE the release is created"
else
	fail "the tag-protection gate does not precede release creation"
fi
missing "the ruleset gate has no bypass input" "$(cat "$WF")" "allow_unprotected"


printf '\n'
# --- the ref matcher must translate fnmatch, not paste a pattern into a regex ----
# GitHub ref-name conditions are fnmatch: `*` does not cross `/`, `**` does, `?` is exactly
# one character, and every regex metacharacter is a LITERAL. The first version escaped only
# `.`, leaving `+ ? ( ) [ ] ^ $ | { }` live — so a ruleset could appear to cover a tag it does
# not (a false positive is the dangerous direction: it reports protection that is not there).
_FN=$(sed -n '/def fn:/,/\[\^\/\]");/p' "$WORK/ruleset.sh" | sed '1s/^[[:space:]]*|[[:space:]]*//')
if [ -z "$_FN" ]; then
	fail "could not extract the ref-pattern translation — these checks would test nothing"
else
	pass "extracted the ref-pattern translation"
	# fnm <pattern> <ref> — "true"/"false" from the SHIPPED translation.
	fnm() {
		printf '%s' "$2" | jq -R --arg p "$1" "$_FN"' . as $ref | ($p | fn) as $re | ($ref | test("^" + $re + "$"))' 2>/dev/null || printf 'error'
	}
	while IFS='~' read -r _p _r _want _why; do
		[ -n "$_p" ] || continue
		check "ref match: $_why" "$(fnm "$_p" "$_r")" "$_want"
	done <<'EOF'
refs/tags/v*~refs/tags/v2.2.0~true~* matches within a segment
refs/tags/v*~refs/tags/v2/2/0~false~* does not cross /
refs/tags/**~refs/tags/a/b/c~true~** crosses /
refs/tags/v2.2.0~refs/tags/v2.2.0~true~an exact pattern matches
refs/tags/v2.2.0~refs/tags/v2X2.0~false~. is a literal dot, not a wildcard
refs/tags/v?.0~refs/tags/v2.0~true~? is one character
refs/tags/v?.0~refs/tags/v22.0~false~? is exactly one character
refs/tags/rel+x~refs/tags/rel+x~true~+ is a literal plus
refs/tags/rel+x~refs/tags/relx~false~+ is not one-or-more
refs/tags/a|b~refs/tags/a|b~true~a pipe is a literal pipe
refs/tags/a|b~refs/tags/a~false~a pipe is not alternation
refs/tags/x[0]~refs/tags/x[0]~true~[] are literal
refs/tags/x[0]~refs/tags/x0~false~[] is not a character class
refs/tags/a{2}~refs/tags/a{2}~true~{} are literal
refs/tags/a{2}~refs/tags/aa~false~{} is not a repeat count
refs/tags/rel(1)~refs/tags/rel(1)~true~() are literal
refs/tags/^v~refs/tags/^v~true~^ is literal
EOF
fi

# --- the inspection token must be one that CAN see bypass actors -----------------
# GitHub omits `bypass_actors` unless the caller has ruleset write access, which GITHUB_TOKEN
# cannot hold. Inspecting with ${{ github.token }} therefore made this step impossible to
# satisfy no matter how the repository was configured — not fail-closed, just broken, and the
# only pressure such a check creates is to delete it.
_rsenv=$(awk '/^      - name: Require an enforced, non-bypassable tag ruleset/ { inb = 1 }
	inb && /GH_TOKEN:/ { print; exit }' "$WF")
check "the ruleset step does not inspect with the default GITHUB_TOKEN" \
	"$(printf '%s' "$_rsenv" | grep -c 'github.token' || true)" "0"
check "  and uses a dedicated ruleset-inspection secret instead" \
	"$(printf '%s' "$_rsenv" | grep -c 'SENTINEL_SHIELD_RULESET_TOKEN' || true)" "1"
check "  and refuses up front when that secret is absent" \
	"$(grep -c 'no SENTINEL_SHIELD_RULESET_TOKEN secret is configured' "$WORK/ruleset.sh" || true)" "1"
# Publication itself must still use the workflow token, not the elevated one.
check "  while publication still uses the workflow token" \
	"$(grep -c 'GH_TOKEN: ${{ github.token }}' "$WF" || true)" "3"

if [ "$FAILED" -eq 0 ]; then
	printf '297-release-signing-identity: ALL CHECKS PASSED\n'
	exit 0
fi
printf '297-release-signing-identity: FAILURES PRESENT\n'
exit 1
