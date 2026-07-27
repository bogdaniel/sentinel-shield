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
	'ftp://host/acme/shield'
do
	i=$((i + 1))
	D=$(newdir "badrepo$i")
	check "rejects malformed repository #$i" "$(irc "$D" --profile laravel --apply --source-repository "$bad")" 2
	[ -f "$D/$WF" ] && fail "malformed repository #$i still wrote a workflow"
done

# Accepted URL forms all normalise to owner/name.
i=0
for good in 'acme/shield' 'https://github.com/acme/shield' 'https://github.com/acme/shield.git' \
	'git@github.com:acme/shield.git' 'ssh://git@ghe.corp.example/acme/shield.git' \
	'https://ghe.corp.example/acme/shield.git'
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

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '284-installer-source-config: ALL CHECKS PASSED\n'
	exit 0
fi
printf '284-installer-source-config: FAILURES PRESENT\n'
exit 1
