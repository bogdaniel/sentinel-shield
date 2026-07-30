#!/bin/sh
# Sentinel Shield prod test — installer renders a runnable engine source config (issue #90).
#
# `install-baseline.sh --apply` used to install a managed workflow still containing
#   SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield
# so a "successful" install left CI guaranteed to fail on its first run, and the documented
# fix was a hand edit of the YAML — exactly where the repository/ref trust boundary gets
# replaced unsafely.
#
# Repository and ref are CONFIGURATION DATA here: validated against a strict grammar, then
# rendered by an anchored whole-line replacement. This suite proves the validation, the
# rendering, the dry-run contract, the production immutability policy, sync ownership, and
# that a placeholder is rejected before the workflow is committed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
INSTALL="$ROOT/scripts/install-baseline.sh"
SYNC="$ROOT/scripts/sync-baseline.sh"
DOCTOR="$ROOT/scripts/doctor.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

WF=".github/workflows/sentinel-shield.yml"
# val <dir> <KEY> — the value assigned in the installed workflow.
val() {
	sed -nE "s/^[[:space:]]*$2:[[:space:]]*([^[:space:]#]+).*/\1/p" "$1/$WF" 2>/dev/null | head -n1
}
# irc <dir> <args...> — run the installer, echo its exit code.
irc() { _d="$1"; shift; _c=0; sh "$INSTALL" --target "$_d" "$@" >/dev/null 2>&1 || _c=$?; printf '%s' "$_c"; }
newdir() { _n="$WORK/$1"; mkdir -p "$_n"; printf '%s' "$_n"; }

# ---------------------------------------------------------------------------
# 1. The happy path: --apply produces a RUNNABLE workflow with no placeholder.
# ---------------------------------------------------------------------------
D=$(newdir happy)
check "install --apply succeeds" "$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref v9.9.9)" 0
check "repository is rendered" "$(val "$D" SENTINEL_SHIELD_REPOSITORY)" "acme/shield"
check "ref is rendered" "$(val "$D" SENTINEL_SHIELD_REF)" "v9.9.9"
if grep -q 'YOUR_ORG' "$D/$WF"; then fail "the installed workflow still contains the YOUR_ORG placeholder"; else pass "no YOUR_ORG placeholder remains in the installed workflow"; fi
# The rendered file must still be parseable YAML with the same structure.
if command -v yq >/dev/null 2>&1; then
	yq -e '.jobs' "$D/$WF" >/dev/null 2>&1 && pass "the rendered workflow still parses as YAML" \
		|| fail "the rendered workflow no longer parses as YAML"
else
	printf 'SKIP: yq is not installed — the YAML re-parse assertion did not run\n'
fi
check "exactly one repository assignment remains" "$(grep -cE '^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:' "$D/$WF")" 1

# Default derivation: no flags at all must still produce a runnable workflow when this
# checkout has an unambiguous origin remote (that is the one-command adoption goal).
D=$(newdir derived)
check "install --apply with no source flags succeeds" "$(irc "$D" --profile laravel --apply)" 0
_derived=$(val "$D" SENTINEL_SHIELD_REPOSITORY)
if command -v git >/dev/null 2>&1 && git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
	if [ -n "$_derived" ] && [ "$_derived" != "YOUR_ORG/sentinel-shield" ]; then
		pass "repository derived from this checkout's origin remote ($_derived)"
	else
		fail "repository was not derived from the origin remote (got '$_derived')"
	fi
	check "ref defaults to the release-status contract" "$(val "$D" SENTINEL_SHIELD_REF)" \
		"$(jq -r '.consumer_ref.value' "$ROOT/config/release-status.json")"
else
	printf 'SKIP: no origin remote in this checkout — the derivation assertion did not run\n'
fi

# ---------------------------------------------------------------------------
# 2. Dry-run shows the substitutions and writes NOTHING.
# ---------------------------------------------------------------------------
D=$(newdir dryrun)
_out=$(sh "$INSTALL" --target "$D" --profile laravel --source-repository acme/shield --source-ref v9.9.9 2>&1 || true)
printf '%s' "$_out" | grep -q 'would set in .github/workflows/sentinel-shield.yml' \
	&& pass "dry-run reports the exact workflow it would configure" \
	|| fail "dry-run does not report the source-config substitution"
printf '%s' "$_out" | grep -q 'SENTINEL_SHIELD_REPOSITORY=acme/shield' \
	&& printf '%s' "$_out" | grep -q 'SENTINEL_SHIELD_REF=v9.9.9' \
	&& pass "dry-run reports both substituted values" \
	|| fail "dry-run does not report the substituted values"
check "dry-run wrote no files" "$(find "$D" -mindepth 1 | wc -l | tr -d ' ')" 0

# ---------------------------------------------------------------------------
# 3. Input validation — repository. Malformed values are exit 2, never rendered.
# ---------------------------------------------------------------------------
i=0
for bad in \
	'acme' \
	'a/b/c' \
	'../../etc/passwd' \
	'YOUR_ORG/sentinel-shield' \
	'acme/shield; rm -rf /' \
	'acme/shield && curl evil' \
	'${{ secrets.GITHUB_TOKEN }}' \
	'$(id)' \
	'`id`' \
	'acme/shield
SOMETHING_ELSE: injected' \
	'acme/shield #comment' \
	'ftp://host/acme/shield' \
	'http://github.com/acme/shield' \
	'https://ghe.corp.example/acme/shield.git' \
	'ssh://git@ghe.corp.example/acme/shield.git' \
	'git@ghe.corp.example:acme/shield.git'
do
	i=$((i + 1))
	D=$(newdir "badrepo$i")
	check "rejects malformed repository #$i" "$(irc "$D" --profile laravel --apply --source-repository "$bad")" 2
	[ -f "$D/$WF" ] && fail "malformed repository #$i still wrote a workflow"
done

# Accepted URL forms all normalise to owner/name.
i=0
# A NON-github.com host is no longer an accepted form: actions/checkout resolves owner/name
# against the RUNNER's server, so reducing a GHE URL to owner/name silently retargets the
# request to a different repository. Those cases moved to the refusal list below.
for good in 'acme/shield' 'https://github.com/acme/shield' 'https://github.com/acme/shield.git' \
	'git@github.com:acme/shield.git' 'ssh://git@github.com/acme/shield.git'
do
	i=$((i + 1))
	D=$(newdir "goodrepo$i")
	if [ "$(irc "$D" --profile laravel --apply --source-repository "$good" --source-ref v9.9.9)" = 0 ]; then
		check "normalises '$good'" "$(val "$D" SENTINEL_SHIELD_REPOSITORY)" "acme/shield"
	else
		fail "rejected a valid repository form: $good"
	fi
done

# ---------------------------------------------------------------------------
# 4. Input validation — ref, and the production immutability policy.
# ---------------------------------------------------------------------------
i=0
for badref in 'v1.0.0; id' 'refs/heads/../x' '$(id)' 'v1.0.0
INJECT: yes' '-not-a-ref'
do
	i=$((i + 1))
	D=$(newdir "badref$i")
	check "rejects malformed ref #$i" "$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref "$badref")" 2
done

D=$(newdir branchref)
check "a moving branch ref is rejected by default" \
	"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref master)" 2
D=$(newdir branchallowed)
check "a moving branch ref is allowed with --allow-branch-ref" \
	"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref master --allow-branch-ref)" 0
check "the branch ref was rendered" "$(val "$D" SENTINEL_SHIELD_REF)" "master"

APPROVED=$(jq -r '.consumer_ref.value' "$ROOT/config/release-status.json")
for _m in strict regulated; do
	D=$(newdir "prod-branch-$_m")
	check "--mode $_m rejects a branch ref" \
		"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref master --allow-branch-ref --mode "$_m")" 2
	D=$(newdir "prod-tag-$_m")
	check "--mode $_m rejects an unapproved tag" \
		"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref v0.0.1 --mode "$_m")" 2
	D=$(newdir "prod-sha-$_m")
	check "--mode $_m accepts a full commit SHA" \
		"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref 1111111111111111111111111111111111111111 --mode "$_m")" 0
	D=$(newdir "prod-approved-$_m")
	check "--mode $_m accepts the approved release tag" \
		"$(irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref "$APPROVED" --mode "$_m")" 0
done

# ---------------------------------------------------------------------------
# 5. Opt-out, idempotency and rollback.
# ---------------------------------------------------------------------------
D=$(newdir optout)
check "--no-source-render succeeds" "$(irc "$D" --profile laravel --apply --no-source-render)" 0
grep -q 'YOUR_ORG/sentinel-shield' "$D/$WF" && pass "--no-source-render leaves the template exactly as shipped" \
	|| fail "--no-source-render still rewrote the source configuration"

D=$(newdir idem)
irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref v9.9.9 >/dev/null
cp "$D/$WF" "$WORK/first.yml"
irc "$D" --profile laravel --apply --force --source-repository acme/shield --source-ref v9.9.9 >/dev/null
if diff -q "$WORK/first.yml" "$D/$WF" >/dev/null 2>&1; then
	pass "re-running the installer with the same inputs is byte-identical (idempotent)"
else
	fail "a second install with identical inputs produced a different workflow"
fi

# A failed install must not leave a half-configured workflow behind: the transaction rolls
# back and the target is restored.
D=$(newdir rollback)
irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref v9.9.9 >/dev/null
cp "$D/$WF" "$WORK/before-rollback.yml"
SENTINEL_SHIELD_FAULT_AFTER="$WF" sh "$INSTALL" --target "$D" --profile laravel --apply --force \
	--source-repository other/engine --source-ref v8.8.8 >/dev/null 2>&1 || true
if diff -q "$WORK/before-rollback.yml" "$D/$WF" >/dev/null 2>&1; then
	pass "an interrupted install rolls the workflow back to its previous configuration"
else
	fail "an interrupted install left a changed workflow: $(val "$D" SENTINEL_SHIELD_REPOSITORY) / $(val "$D" SENTINEL_SHIELD_REF)"
fi

# ---------------------------------------------------------------------------
# 6. Sync ownership: the consumer's configuration survives a managed update.
# ---------------------------------------------------------------------------
D=$(newdir sync)
irc "$D" --profile laravel --apply --source-repository private/fork --source-ref 2222222222222222222222222222222222222222 >/dev/null
sh "$SYNC" --target "$D" --profile laravel --apply --force >/dev/null 2>&1 || fail "sync --apply --force failed"
check "sync preserves the consumer repository" "$(val "$D" SENTINEL_SHIELD_REPOSITORY)" "private/fork"
check "sync preserves the consumer ref" "$(val "$D" SENTINEL_SHIELD_REF)" "2222222222222222222222222222222222222222"
_syncout=$(sh "$SYNC" --target "$D" --profile laravel --apply --force 2>&1 || true)
printf '%s' "$_syncout" | grep -q 'up-to-date: .github/workflows/sentinel-shield.yml' \
	&& pass "a preserved workflow reports up-to-date instead of permanent drift" \
	|| fail "sync reports the workflow as drifting even though only consumer-owned values differ"

_upd=$(sh "$SYNC" --target "$D" --profile laravel --apply --force --update-source-config --source-ref v9.9.9 2>&1 || true)
check "--update-source-config applies the new ref" "$(val "$D" SENTINEL_SHIELD_REF)" "v9.9.9"
check "--update-source-config preserves the repository when not given one" "$(val "$D" SENTINEL_SHIELD_REPOSITORY)" "private/fork"
printf '%s' "$_upd" | grep -q 'source-config CHANGED' \
	&& pass "the source-config change is announced (audited)" \
	|| fail "the source-config change was silent"

# ---------------------------------------------------------------------------
# 7. Preflight rejects a placeholder before CI is committed.
# ---------------------------------------------------------------------------
D=$(newdir placeholder)
irc "$D" --profile laravel --apply --no-source-render >/dev/null
_doc=$(sh "$DOCTOR" --target "$D" --profile laravel 2>&1 || true)
printf '%s' "$_doc" | grep -q 'still carry the SENTINEL_SHIELD_REPOSITORY placeholder' \
	&& pass "doctor rejects a workflow that still carries the placeholder" \
	|| fail "doctor did not reject the placeholder"
printf '%s' "$_doc" | grep -q 'do not hand-edit the YAML' \
	&& pass "doctor points at the validated CLI path rather than a manual edit" \
	|| fail "doctor's placeholder guidance is not actionable"

D=$(newdir mutable)
irc "$D" --profile laravel --apply --source-repository acme/shield --source-ref feature-branch --allow-branch-ref >/dev/null
_doc=$(sh "$DOCTOR" --target "$D" --profile laravel 2>&1 || true)
printf '%s' "$_doc" | grep -q 'not provably immutable' \
	&& pass "doctor flags a non-immutable SENTINEL_SHIELD_REF" \
	|| fail "doctor did not flag a moving SENTINEL_SHIELD_REF"

# ---------------------------------------------------------------------------
# 8. The AI-assisted install path uses the same validated CLI.
# ---------------------------------------------------------------------------
_prompt=$(sh "$ROOT/scripts/print-ai-install-prompt.sh" 2>/dev/null || true)
printf '%s' "$_prompt" | grep -q -- '--source-repository' \
	&& pass "the AI install prompt uses --source-repository" \
	|| fail "the AI install prompt does not use the validated --source-repository path"
printf '%s' "$_prompt" | grep -qi 'do not hand-edit' \
	&& pass "the AI install prompt forbids hand-editing the workflow YAML" \
	|| fail "the AI install prompt does not forbid hand-editing the workflow YAML"

# ---------------------------------------------------------------------------
# CodeRabbit review follow-ups: unvalidated sync input, a late unresolvable ref,
# and a quoted placeholder passing the fail-closed preflight.
# ---------------------------------------------------------------------------
# sync must reject a malformed CLI source value INSTEAD of silently falling back to the
# shipped placeholder — that fallback reverted a configured consumer under --apply --force.
SC="$WORK/sync-consumer"; mkdir -p "$SC"
sh "$INSTALL" --target "$SC" --profile laravel --apply --source-repository acme/shield \
	--source-ref v2.2.0 >/dev/null 2>&1 || fail "sync fixture install failed"
_wf=$(ls "$SC"/.github/workflows/*.yml 2>/dev/null | head -1)
_before=$(cat "$_wf" 2>/dev/null || true)
for _bad in 'not a repo' 'https://example.com' '../../etc'; do
	_c=0
	sh "$SYNC" --target "$SC" --profile laravel --apply --force --update-source-config \
		--source-repository "$_bad" >/dev/null 2>&1 || _c=$?
	check "sync refuses the malformed --source-repository '$_bad'" "$_c" 2
done
_c=0
sh "$SYNC" --target "$SC" --profile laravel --apply --force --update-source-config \
	--source-ref main >/dev/null 2>&1 || _c=$?
check "sync refuses a moving branch ref without --allow-branch-ref" "$_c" 2
check "  the configured workflow was not reverted to the placeholder" \
	"$(cat "$_wf" 2>/dev/null)" "$_before"
if grep -qE '^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:[[:space:]]*.?YOUR_ORG/' "$_wf" 2>/dev/null; then
	fail "  a refused sync reverted the workflow to the shipped placeholder"
else
	pass "  the workflow still carries its configured repository"
fi
_c=0
sh "$SYNC" --target "$SC" --profile laravel --dry-run --update-source-config >/dev/null 2>&1 || _c=$?
check "sync refuses --update-source-config with nothing to update" "$_c" 2

# A QUOTED placeholder is the same unrunnable placeholder.
QP="$WORK/quoted"; mkdir -p "$QP/.github/workflows"
for _q in '"YOUR_ORG/sentinel-shield"' "'YOUR_ORG/sentinel-shield'" 'YOUR_ORG/sentinel-shield'; do
	printf 'name: x\nenv:\n  SENTINEL_SHIELD_REPOSITORY: %s\n' "$_q" > "$QP/.github/workflows/w.yml"
	if ( . "$ROOT/scripts/lib/source-config.sh"; sc_has_placeholder "$QP/.github/workflows/w.yml" ); then
		pass "the placeholder preflight detects the form $_q"
	else
		fail "the placeholder preflight MISSED the form $_q"
	fi
done
printf 'name: x\nenv:\n  SENTINEL_SHIELD_REPOSITORY: "acme/shield"\n' > "$QP/.github/workflows/w.yml"
if ( . "$ROOT/scripts/lib/source-config.sh"; sc_has_placeholder "$QP/.github/workflows/w.yml" ); then
	fail "the placeholder preflight false-positives on a real quoted repository"
else
	pass "a real quoted repository is not a placeholder"
fi

# The preflight's question is "can this workflow check the engine out", not "is this one of
# the two placeholder spellings we happen to ship". It used to be the latter, so every other
# unusable value passed it.
for _bad in 'TODO' 'changeme' 'acme shield/x' 'https://ghe.example.com/acme/engine' 'http://github.com/acme/engine'; do
	printf 'name: x\nenv:\n  SENTINEL_SHIELD_REPOSITORY: %s\n' "$_bad" > "$QP/.github/workflows/w.yml"
	if ( . "$ROOT/scripts/lib/source-config.sh"; sc_has_placeholder "$QP/.github/workflows/w.yml" ); then
		pass "the preflight rejects the unusable engine source '$_bad'"
	else
		fail "the preflight ACCEPTED '$_bad', which sc_normalize_repository refuses — the workflow cannot check the engine out"
	fi
done
# An empty assignment is unusable for the same reason.
printf 'name: x\nenv:\n  SENTINEL_SHIELD_REPOSITORY:\n' > "$QP/.github/workflows/w.yml"
if ( . "$ROOT/scripts/lib/source-config.sh"; sc_has_placeholder "$QP/.github/workflows/w.yml" ); then
	pass "the preflight rejects an EMPTY engine source"
else
	fail "the preflight accepted an empty SENTINEL_SHIELD_REPOSITORY"
fi
# A file that does not declare the key is a different contract; answering "placeholder" here
# would misreport it.
printf 'name: x\nenv:\n  SOMETHING_ELSE: value\n' > "$QP/.github/workflows/w.yml"
if ( . "$ROOT/scripts/lib/source-config.sh"; sc_has_placeholder "$QP/.github/workflows/w.yml" ); then
	fail "a workflow with no SENTINEL_SHIELD_REPOSITORY key is reported as carrying a placeholder"
else
	pass "a workflow that does not declare the key is not a placeholder finding"
fi

# ---------------------------------------------------------------------------
# An ENFORCING mode must refuse to install a gate that cannot run.
# ---------------------------------------------------------------------------
# strict/regulated install a blocking gate. A managed workflow left with the engine-source
# placeholder cannot check the engine out, so the gate never runs — and a gate that never runs
# blocks nothing while every dashboard shows it installed. Both routes to that state used to
# be a printed WARNING that the install carried on past.
for _m in strict regulated; do
	_nr="$WORK/norender-$_m"; mkdir -p "$_nr"
	_c=0
	sh "$INSTALL" --target "$_nr" --profile laravel --mode "$_m" --no-source-render --apply >/dev/null 2>&1 || _c=$?
	if [ "$_c" -eq 0 ]; then
		fail "--mode $_m with --no-source-render installed an enforcing gate that cannot run"
	else
		pass "--mode $_m refuses --no-source-render (the gate would never run)"
	fi
	check "  and no managed workflow survives the refusal" \
		"$(find "$_nr" -path '*workflows*' -name '*.yml' 2>/dev/null | grep -c . || true)" "0"
done
# The advisory modes are unaffected: leaving the source unset is a documented choice there.
_ro="$WORK/norender-report-only"; mkdir -p "$_ro"
_c=0
sh "$INSTALL" --target "$_ro" --profile laravel --mode report-only --no-source-render --apply >/dev/null 2>&1 || _c=$?
check "--mode report-only still permits --no-source-render" "$_c" 0

# A full commit SHA is immutable on its own: strict/regulated must accept it even when the
# release contract is unreadable, instead of telling a user who passed a 40-hex SHA to pass
# a 40-hex SHA.
SHAOK="$WORK/sha-no-contract"; mkdir -p "$SHAOK"
FR2="$WORK/fakeroot2"; rm -rf "$FR2"; mkdir -p "$FR2"
cp -R "$ROOT/scripts" "$ROOT/profiles" "$ROOT/templates" "$FR2/" 2>/dev/null || true
_c=0
sh "$FR2/scripts/install-baseline.sh" --target "$SHAOK" --profile laravel --apply --mode strict \
	--source-repository acme/shield --source-ref 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1 || _c=$?
check "strict accepts a commit SHA with no readable release contract" "$_c" 0
SHABAD="$WORK/tag-no-contract"; mkdir -p "$SHABAD"
_out=$(sh "$FR2/scripts/install-baseline.sh" --target "$SHABAD" --profile laravel --apply --mode strict \
	--source-repository acme/shield --source-ref v2.2.0 2>&1) && _c=0 || _c=$?
check "strict still refuses a TAG with no readable release contract" "$_c" 2
case "$_out" in
	*"is not a commit SHA"*) pass "  and the message says why the tag specifically is refused" ;;
	*) fail "  with a message that does not distinguish tag from commit: $_out" ;;
esac

# An unresolvable ref must fail EARLY and say why, not die inside the renderer and roll back.
NOREF="$WORK/noref"; mkdir -p "$NOREF"
FAKEROOT="$WORK/fakeroot"; rm -rf "$FAKEROOT"; mkdir -p "$FAKEROOT"
cp -R "$ROOT/scripts" "$ROOT/profiles" "$ROOT/templates" "$FAKEROOT/" 2>/dev/null || true
# no config/release-status.json in the fake root => no approved ref is readable
_out=$(sh "$FAKEROOT/scripts/install-baseline.sh" --target "$NOREF" --profile laravel --apply 2>&1) && _c=0 || _c=$?
check "an unresolvable engine ref fails closed" "$_c" 2
case "$_out" in
	*"no engine ref to pin"*) pass "  and says exactly what is missing and how to fix it" ;;
	*) fail "  with a misleading late error instead: $_out" ;;
esac
check "  nothing was installed into the consumer" \
	"$([ -e "$NOREF/.github/workflows" ] && echo installed || echo clean)" "clean"

# --- CodeRabbit round 2: YAML injection via an embedded newline ---------------
# `grep -Eq '^…$'` is line-oriented, so a two-line value passed the grammar check on its FIRST
# line while the validator returned the WHOLE string — which sc_render_workflow substituted
# verbatim, adding a new key to the installed workflow. Reachable straight from the CLI.
NL=$(printf 'acme/shield\nSENTINEL_SHIELD_EVIL: pwned')
NLREF=$(printf 'v2.2.0\nSENTINEL_SHIELD_EVIL: pwned')
if ( . "$ROOT/scripts/lib/source-config.sh"; sc_normalize_repository "$NL" >/dev/null 2>&1 ); then
	fail "sc_normalize_repository ACCEPTS an embedded-newline repository (YAML injection)"
else
	pass "an embedded-newline repository is refused"
fi
if ( . "$ROOT/scripts/lib/source-config.sh"; sc_ref_kind "$NLREF" >/dev/null 2>&1 ); then
	fail "sc_ref_kind ACCEPTS an embedded-newline ref (YAML injection)"
else
	pass "an embedded-newline ref is refused"
fi
# …and it cannot reach the installed workflow through either entry point.
INJ="$WORK/inject"; mkdir -p "$INJ"
_c=0; sh "$INSTALL" --target "$INJ" --profile laravel --apply --source-repository "$NL" >/dev/null 2>&1 || _c=$?
check "install-baseline refuses an embedded-newline --source-repository" "$_c" 2
_c=0; sh "$INSTALL" --target "$INJ" --profile laravel --apply --source-ref "$NLREF" >/dev/null 2>&1 || _c=$?
check "install-baseline refuses an embedded-newline --source-ref" "$_c" 2
INJ2="$WORK/inject2"; mkdir -p "$INJ2"
sh "$INSTALL" --target "$INJ2" --profile laravel --apply --source-repository acme/shield --source-ref v2.2.0 >/dev/null 2>&1 \
	|| fail "injection fixture install failed"
_c=0; sh "$SYNC" --target "$INJ2" --profile laravel --apply --force --update-source-config \
	--source-repository "$NL" >/dev/null 2>&1 || _c=$?
check "sync-baseline refuses an embedded-newline --source-repository" "$_c" 2
_evil=$(grep -rc 'SENTINEL_SHIELD_EVIL' "$INJ2"/.github/workflows/ 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
check "  no injected key reached any installed workflow" "$_evil" 0

# The renderer substitutes the CANONICAL value, so a URL never reaches the workflow verbatim.
URLD="$WORK/urlrepo"; mkdir -p "$URLD"
sh "$INSTALL" --target "$URLD" --profile laravel --apply --source-repository acme/shield --source-ref v2.2.0 >/dev/null 2>&1 \
	|| fail "url fixture install failed"
_c=0
sh "$SYNC" --target "$URLD" --profile laravel --apply --force --update-source-config \
	--source-repository https://github.com/acme/other.git >/dev/null 2>&1 || _c=$?
check "sync accepts a URL form" "$_c" 0
_wf=$(ls "$URLD"/.github/workflows/*.yml 2>/dev/null | head -1)
check "  and writes the CANONICAL owner/name, not the URL" \
	"$(sh -c '. "'"$ROOT"'/scripts/lib/source-config.sh"; sc_workflow_value "'"$_wf"'" SENTINEL_SHIELD_REPOSITORY')" "acme/other"

# --- second-reviewer round: predictable temp file, cross-host retarget ---------
# `$workflow.sc.tmp.$$` was predictable, so anyone able to write in the directory could
# pre-create it as a SYMLINK and the render would be written THROUGH the link before the
# final mv — defeating the atomic-render guarantee.
SY="$WORK/tmpsym"; mkdir -p "$SY"
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield\n  SENTINEL_SHIELD_REF: v0.0.0\n' > "$SY/w.yml"
# every plausible pid-suffixed name an attacker could pre-create
for _pid in $$ $(($$ + 1)) $(($$ + 2)) 1234; do
	ln -s "$SY/victim" "$SY/w.yml.sc.tmp.$_pid" 2>/dev/null || true
done
( . "$ROOT/scripts/lib/source-config.sh"; sc_render_workflow "$SY/w.yml" acme/shield v2.2.0 ) >/dev/null 2>&1 \
	&& pass "the renderer still works with hostile temp paths pre-created" \
	|| fail "the renderer failed outright with hostile temp paths pre-created"
check "  nothing was written through the pre-created symlink" \
	"$([ -e "$SY/victim" ] && echo written || echo clean)" "clean"
check "  and the workflow itself was rendered" \
	"$(sh -c '. "'"$ROOT"'/scripts/lib/source-config.sh"; sc_workflow_value "'"$SY"'/w.yml" SENTINEL_SHIELD_REPOSITORY')" "acme/shield"
check "  the rendered workflow is readable (mode preserved, not the private staging mode)" \
	"$([ -r "$SY/w.yml" ] && echo yes || echo no)" "yes"

# A non-github.com host must be REFUSED, not silently reduced to owner/name: actions/checkout
# resolves owner/name against the RUNNER's server, so dropping the host retargets the request.
for _u in 'https://ghe.corp.example/acme/shield.git' 'ssh://git@ghe.corp.example/acme/shield.git' 'git@ghe.corp.example:acme/shield.git' 'http://github.com/acme/shield'; do
	if ( . "$ROOT/scripts/lib/source-config.sh"; sc_normalize_repository "$_u" >/dev/null 2>&1 ); then
		fail "a non-github.com/insecure URL was accepted and silently retargeted: $_u"
	else
		pass "refused (never retargeted): $_u"
	fi
done
for _u in 'acme/shield' 'https://github.com/acme/shield.git' 'git@github.com:acme/shield.git'; do
	check "github.com form normalises: $_u" \
		"$( . "$ROOT/scripts/lib/source-config.sh"; sc_normalize_repository "$_u" )" "acme/shield"
done

# ---------------------------------------------------------------------------
# The render must not destroy the caller signal handlers.
# ---------------------------------------------------------------------------
# install-baseline.sh arms a transaction rollback on INT/TERM. sc_render_workflow used to
# install its own INT/TERM/HUP trap and then clear it with `trap -`, so every mutation AFTER
# the first rendered workflow ran with no rollback on interrupt.
TW="$WORK/traps"; mkdir -p "$TW"
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/repo\n  SENTINEL_SHIELD_REF: v1.0.0\n' > "$TW/w.yml"
_traps=$(sh -c '
	. "'"$ROOT"'/scripts/lib/source-config.sh"
	trap "echo CALLER_INT" INT
	trap "echo CALLER_TERM" TERM
	_before=$(trap)
	sc_render_workflow "'"$TW"'/w.yml" acme/shield v2.2.0 >/dev/null 2>&1 || exit 9
	[ "$_before" = "$(trap)" ] && echo same || echo lost
')
check "the render leaves the caller INT/TERM handlers exactly as they were" "$_traps" "same"

# ---------------------------------------------------------------------------
# A workflow the installer SKIPPED must not be rendered anyway.
# ---------------------------------------------------------------------------
SK="$WORK/skipped"; mkdir -p "$SK"
sh "$ROOT/scripts/install-baseline.sh" --target "$SK" --profile laravel --apply \
	--source-repository acme/shield >/dev/null 2>&1
printf 'name: MINE\non: push\nenv:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/keep-me\n' \
	> "$SK/.github/workflows/sentinel-shield.yml"
sh "$ROOT/scripts/install-baseline.sh" --target "$SK" --profile laravel --apply \
	--source-repository acme/shield >/dev/null 2>&1
check "a managed workflow skipped for want of --force is left byte-for-byte" \
	"$(sh -c '. "'"$ROOT"'/scripts/lib/source-config.sh"; sc_workflow_value "'"$SK"'/.github/workflows/sentinel-shield.yml" SENTINEL_SHIELD_REPOSITORY')" \
	"YOUR_ORG/keep-me"

# ---------------------------------------------------------------------------
# doctor must catch a QUOTED placeholder.
# ---------------------------------------------------------------------------
# The preflight kept its own copy of the placeholder regex, and that copy did not allow for a
# quoted value — so `SENTINEL_SHIELD_REPOSITORY: "YOUR_ORG/repo"` reported the source
# configuration as SET, which is a guaranteed first-run CI failure passing its own preflight.
DQ="$WORK/doctor-quoted"; mkdir -p "$DQ"   # NOT $WORK/quoted: that tree already holds a
                                          # hand-written w.yml from the sc_has_placeholder
                                          # block above, which would be installed over and
                                          # then swept up by the loop below.
sh "$ROOT/scripts/install-baseline.sh" --target "$DQ" --profile laravel --apply \
	--no-source-render >/dev/null 2>&1
for _w in "$DQ"/.github/workflows/*.y*ml; do
	[ -e "$_w" ] || continue
	sed -e 's#SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield#SENTINEL_SHIELD_REPOSITORY: "YOUR_ORG/sentinel-shield"#' \
		"$_w" > "$_w.q" && mv "$_w.q" "$_w"
done
if sh "$ROOT/scripts/doctor.sh" --target "$DQ" --profile laravel 2>&1 | grep -q 'still carry the SENTINEL_SHIELD_REPOSITORY placeholder'; then
	pass "doctor catches a QUOTED placeholder"
else
	fail "a quoted placeholder passed the doctor preflight — the workflow cannot check the engine out"
fi

# ---------------------------------------------------------------------------
# A render must PROVE it wrote the complete source contract.
# ---------------------------------------------------------------------------
# A template missing a key was copied, stayed non-empty and returned SUCCESS while the
# installed workflow could not check the engine out. Duplicates were all rewritten, leaving a
# duplicate YAML mapping whose value depends on the parser.
RC="$WORK/render-contract"; mkdir -p "$RC"
_render() { # _render <file> -> exit code
	sh -c '. "$0" 2>/dev/null; . "$1"; sc_render_workflow "$2" acme/shield v2.2.0 >/dev/null 2>&1; printf "%s" "$?"' \
		"$ROOT/scripts/lib/sentinel-shield-common.sh" "$ROOT/scripts/lib/source-config.sh" "$1"
}
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n  SENTINEL_SHIELD_REF: v1.0.0\n' > "$RC/ok.yml"
check "a complete template renders" "$(_render "$RC/ok.yml")" 0
check "  the repository is the canonical value" \
	"$(sh -c '. "$0" 2>/dev/null; . "$1"; sc_workflow_value "$2" SENTINEL_SHIELD_REPOSITORY' \
		"$ROOT/scripts/lib/sentinel-shield-common.sh" "$ROOT/scripts/lib/source-config.sh" "$RC/ok.yml")" "acme/shield"
check "  the ref is the canonical value" \
	"$(sh -c '. "$0" 2>/dev/null; . "$1"; sc_workflow_value "$2" SENTINEL_SHIELD_REF' \
		"$ROOT/scripts/lib/sentinel-shield-common.sh" "$ROOT/scripts/lib/source-config.sh" "$RC/ok.yml")" "v2.2.0"

printf 'env:\n  SENTINEL_SHIELD_REF: v1.0.0\n' > "$RC/no-repo.yml"
check "a template with NO repository key is refused" "$(_render "$RC/no-repo.yml")" 1
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n' > "$RC/no-ref.yml"
check "a template with NO ref key is refused" "$(_render "$RC/no-ref.yml")" 1
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: a/b\n  SENTINEL_SHIELD_REPOSITORY: c/d\n  SENTINEL_SHIELD_REF: v1.0.0\n' > "$RC/dup-repo.yml"
check "a DUPLICATE repository key is refused, not rewritten twice" "$(_render "$RC/dup-repo.yml")" 1
printf 'env:\n  SENTINEL_SHIELD_REPOSITORY: a/b\n  SENTINEL_SHIELD_REF: v1\n  SENTINEL_SHIELD_REF: v2\n' > "$RC/dup-ref.yml"
check "a DUPLICATE ref key is refused" "$(_render "$RC/dup-ref.yml")" 1
# A refused render must leave the file exactly as it was.
cp "$RC/dup-repo.yml" "$RC/dup-repo.before"
_render "$RC/dup-repo.yml" >/dev/null
if cmp -s "$RC/dup-repo.before" "$RC/dup-repo.yml"; then
	pass "a refused render leaves the template byte-for-byte unchanged"
else
	fail "a refused render modified the template"
fi
if ls "$RC"/*.sc.tmp.* >/dev/null 2>&1; then
	fail "a refused render left a staging file behind"
else
	pass "  and leaves no staging file behind"
fi


# ---------------------------------------------------------------------------
# Cardinality is SEMANTIC, not textual: only the workflow-level env: mapping counts.
# ---------------------------------------------------------------------------
# Counting every indentation meant a key nested under a job/step env: satisfied the
# "exactly one" precondition while the top-level configuration was absent, an unrelated
# nested key could be rewritten as though it were the canonical setting, and one canonical
# key plus one nested key was rejected as a duplicate.
SC="$WORK/scope"; mkdir -p "$SC"
_val_at() { sh -c '. "$0" 2>/dev/null; . "$1"; sc_workflow_value "$2" "$3"' \
	"$ROOT/scripts/lib/sentinel-shield-common.sh" "$ROOT/scripts/lib/source-config.sh" "$2" "$3"; }

# 1. canonical top-level keys only -> success
printf 'name: w\nenv:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n  SENTINEL_SHIELD_REF: v1.0.0\njobs:\n  b:\n    runs-on: ubuntu-latest\n' > "$SC/canonical.yml"
check "canonical top-level keys render" "$(_render "$SC/canonical.yml")" 0

# 2. keys ONLY inside a job/step env -> fail (the top-level configuration is absent)
printf 'name: w\njobs:\n  b:\n    env:\n      SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n      SENTINEL_SHIELD_REF: v1.0.0\n' > "$SC/nested-only.yml"
check "keys only inside a job env: are NOT the source configuration" "$(_render "$SC/nested-only.yml")" 1

# 3. canonical key plus a same-named nested key -> canonical updated, nested untouched
printf 'name: w\nenv:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n  SENTINEL_SHIELD_REF: v1.0.0\njobs:\n  b:\n    env:\n      SENTINEL_SHIELD_REPOSITORY: do/not-touch\n' > "$SC/both.yml"
check "a canonical key alongside a nested one still renders" "$(_render "$SC/both.yml")" 0
check "  the canonical value is updated" \
	"$(grep -cE '^  SENTINEL_SHIELD_REPOSITORY: acme/shield$' "$SC/both.yml")" "1"
check "  and the nested value is left exactly as it was" \
	"$(grep -cE '^      SENTINEL_SHIELD_REPOSITORY: do/not-touch$' "$SC/both.yml")" "1"

# 4. a same-named key under an unrelated mapping, and inside a comment, is ignored
printf 'name: w\nenv:\n  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/r\n  SENTINEL_SHIELD_REF: v1.0.0\n# SENTINEL_SHIELD_REPOSITORY: commented/out\nother:\n  SENTINEL_SHIELD_REPOSITORY: unrelated/mapping\n' > "$SC/unrelated.yml"
check "an unrelated mapping and a comment do not affect cardinality" "$(_render "$SC/unrelated.yml")" 0
check "  the unrelated mapping is untouched" \
	"$(grep -cE '^  SENTINEL_SHIELD_REPOSITORY: unrelated/mapping$' "$SC/unrelated.yml")" "1"

# 5. duplicate DIRECT children of the canonical mapping -> fail
printf 'name: w\nenv:\n  SENTINEL_SHIELD_REPOSITORY: a/b\n  SENTINEL_SHIELD_REPOSITORY: c/d\n  SENTINEL_SHIELD_REF: v1.0.0\n' > "$SC/dup-direct.yml"
check "duplicate direct children of the canonical mapping are refused" "$(_render "$SC/dup-direct.yml")" 1


printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '284-installer-source-config: ALL CHECKS PASSED\n'
	exit 0
fi
printf '284-installer-source-config: FAILURES PRESENT\n'
exit 1
