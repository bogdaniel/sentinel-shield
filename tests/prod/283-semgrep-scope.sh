#!/bin/sh
# Sentinel Shield prod test — Semgrep scope excludes the embedded engine checkout (issue #85).
#
# The managed workflows check Sentinel Shield out at SENTINEL_SHIELD_PATH (tools/sentinel-shield)
# and run Semgrep from the CONSUMER ROOT. The Laravel and React profile ignore files excluded
# dependencies and build output but NOT that nested checkout, and the Node/hardened-enterprise
# profiles installed no ignore file at all — so Semgrep analysed the engine's own scripts,
# examples and INTENTIONALLY INSECURE evidence fixtures as if they were application code. A
# required Semgrep gate could then fail on clean consumer source, and a consumer's findings
# depended on which engine version they pinned.
#
# This suite derives the requirement from the RESOLVED PROFILES (not a hand-written list), so a
# future profile cannot reintroduce self-scanning unnoticed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# The path the managed templates configure. Read from the template, never hardcoded here, so
# the two cannot drift apart silently.
SS_PATH=$(grep -hoE '^[[:space:]]*SENTINEL_SHIELD_PATH:[[:space:]]*[^[:space:]#]+' templates/workflows/sentinel-shield.yml |
	sed -E 's/^[[:space:]]*SENTINEL_SHIELD_PATH:[[:space:]]*//; s#/*$##' | head -n1)
if [ -n "$SS_PATH" ]; then pass "managed template configures SENTINEL_SHIELD_PATH=$SS_PATH"
else fail "could not read SENTINEL_SHIELD_PATH from templates/workflows/sentinel-shield.yml"; SS_PATH=tools/sentinel-shield; fi

# ignores <ignore-file> <path> — does this .semgrepignore exclude <path>? Directory rules
# (a trailing '/') are prefix matches; plain paths match exactly. Deliberately small: it models
# only the rule forms Sentinel Shield ships.
ignores() {
	_if="$1"; _path="$2"
	while IFS= read -r _rule; do
		case "$_rule" in ''|'#'*) continue ;; esac
		_rule=$(printf '%s' "$_rule" | sed 's/[[:space:]]*$//')
		[ -n "$_rule" ] || continue
		case "$_rule" in
			*/) case "$_path" in "$_rule"*) return 0 ;; esac ;;
			*)  [ "$_path" = "$_rule" ] && return 0 ;;
		esac
	done < "$_if"
	return 1
}

# ---------------------------------------------------------------------------
# 1. Every profile that SELECTS Semgrep must install an ignore file that excludes the
#    embedded checkout. Profiles that do not select Semgrep are exempt — and that exemption
#    is derived from the resolver, not asserted by hand.
# ---------------------------------------------------------------------------
PROFILES="laravel symfony php-library node react docker hardened-enterprise node-react laravel-react-docker"
_covered=0
for _p in $PROFILES; do
	# A resolver crash, an unknown profile or a jq schema change used to collapse into
	# `_sem=''`, which the case below treats as "this profile does not select Semgrep" — the
	# profile then passed WITHOUT its ignore file ever being checked. That is fail-open in
	# the one suite whose job is to make self-scanning impossible to reintroduce unnoticed.
	_rc=0
	_eff=$(sh scripts/resolve-effective-profile.sh --profile "$_p" --format json 2>"$WORK/resolve-$_p.err") || _rc=$?
	if [ "$_rc" -ne 0 ] || [ -z "$_eff" ]; then
		fail "resolve-effective-profile failed for '$_p' (exit $_rc) — Semgrep scope UNKNOWN, refusing to treat that as 'not selected': $(tail -1 "$WORK/resolve-$_p.err" 2>/dev/null)"
		continue
	fi
	_sem=$(printf '%s' "$_eff" |
		jq -r '[.tools | to_entries[] | select(.key == "semgrep") | .value.policy] | join("")') || {
		fail "could not read the semgrep policy out of the resolved profile for '$_p' — refusing to treat an unreadable policy as 'not selected'"
		continue
	}
	_t="$WORK/install-$_p"
	mkdir -p "$_t"
	if ! sh scripts/install-baseline.sh --target "$_t" --profile "$_p" --apply >/dev/null 2>&1; then
		fail "install-baseline failed for profile '$_p'"
		continue
	fi
	case "$_sem" in
		''|disabled|external)
			if [ -f "$_t/.semgrepignore" ]; then
				# Not a failure, but it must still be correct if shipped.
				ignores "$_t/.semgrepignore" "$SS_PATH/scripts/x.sh" \
					&& pass "profile '$_p' does not select Semgrep but its ignore file still excludes the checkout" \
					|| fail "profile '$_p' ships a .semgrepignore that does NOT exclude $SS_PATH/"
			else
				pass "profile '$_p' does not select Semgrep (policy='${_sem:-absent}') — no ignore file required"
			fi ;;
		*)
			_covered=$((_covered + 1))
			if [ ! -f "$_t/.semgrepignore" ]; then
				fail "profile '$_p' selects semgrep ($_sem) but installs NO .semgrepignore — Semgrep would scan $SS_PATH/ as application code"
				continue
			fi
			if ignores "$_t/.semgrepignore" "$SS_PATH/scripts/build-security-summary.sh"; then
				pass "profile '$_p' excludes the embedded checkout from Semgrep"
			else
				fail "profile '$_p' installs a .semgrepignore that does NOT exclude $SS_PATH/"
			fi
			# Consumer application source must STILL be scanned — an over-broad exclusion
			# would "fix" this issue by scanning nothing.
			_scanned=1
			for _src in "app/Http/Controllers/UserController.php" "src/index.ts" "resources/js/app.tsx" "lib/service.js"; do
				ignores "$_t/.semgrepignore" "$_src" && { _scanned=0; fail "profile '$_p' excludes consumer application source: $_src"; }
			done
			[ "$_scanned" -eq 1 ] && pass "profile '$_p' keeps consumer application source scanned"
			;;
	esac
done
if [ "$_covered" -ge 7 ]; then
	pass "$_covered Semgrep-selecting profile(s) were exercised"
else
	fail "only $_covered Semgrep-selecting profile(s) were exercised — the matrix is not covering the shipped profiles"
fi

# ---------------------------------------------------------------------------
# 2. A nested engine checkout containing an intentionally detectable finding must be
#    excluded while clean consumer source is not. Structural by default; if a real semgrep
#    binary is available the same fixture is scanned for real.
# ---------------------------------------------------------------------------
FIX="$WORK/consumer"
mkdir -p "$FIX"
sh scripts/install-baseline.sh --target "$FIX" --profile laravel --apply >/dev/null 2>&1 || fail "fixture install failed"
mkdir -p "$FIX/$SS_PATH/tests/examples" "$FIX/app/Http/Controllers"
# An engine test fixture that is insecure ON PURPOSE (this is what leaked into consumer scans).
cat > "$FIX/$SS_PATH/tests/examples/insecure-fixture.php" <<'PHP'
<?php
// Intentionally insecure ENGINE FIXTURE — never consumer code.
$cmd = $_GET['cmd'];
system($cmd);
eval($_POST['payload']);
PHP
cat > "$FIX/app/Http/Controllers/CleanController.php" <<'PHP'
<?php
namespace App\Http\Controllers;

final class CleanController
{
    public function index(): string
    {
        return 'ok';
    }
}
PHP
if ignores "$FIX/.semgrepignore" "$SS_PATH/tests/examples/insecure-fixture.php"; then
	pass "a nested engine test fixture is excluded from the consumer Semgrep scope"
else
	fail "a nested engine test fixture would be scanned as consumer code"
fi
if ignores "$FIX/.semgrepignore" "app/Http/Controllers/CleanController.php"; then
	fail "consumer application source is excluded from the Semgrep scope"
else
	pass "consumer application source stays in the Semgrep scope"
fi
if command -v semgrep >/dev/null 2>&1; then
	_sgout="$WORK/semgrep.json"
	( cd "$FIX" && semgrep --quiet --json --output "$_sgout" --config "$ROOT/semgrep/app" . >/dev/null 2>&1 ) || true
	if [ -f "$_sgout" ] && jq -e . "$_sgout" >/dev/null 2>&1; then
		_nested=$(jq --arg p "$SS_PATH/" '[.results[]? | select((.path // "") | startswith($p))] | length' "$_sgout")
		check "live semgrep reports no finding inside the embedded checkout" "$_nested" "0"
	else
		printf 'SKIP: semgrep produced no parsable report; the live scan assertion did not run\n'
	fi
else
	printf 'SKIP: semgrep is not installed — the live scan assertion did not run (structural assertions above still applied)\n'
fi

# ---------------------------------------------------------------------------
# 3. sync-baseline must not silently regress the scope, and doctor must flag an existing
#    consumer whose ignore file predates this fix (the file is PROJECT-OWNED, so sync
#    deliberately never rewrites it — doctor is the migration signal).
# ---------------------------------------------------------------------------
sh scripts/sync-baseline.sh --target "$FIX" --profile laravel --apply --force >/dev/null 2>&1 || true
if ignores "$FIX/.semgrepignore" "$SS_PATH/scripts/x.sh"; then
	pass "the exclusion survives sync-baseline --apply --force"
else
	fail "sync-baseline removed the embedded-checkout exclusion"
fi

LEGACY="$WORK/legacy"
mkdir -p "$LEGACY"
sh scripts/install-baseline.sh --target "$LEGACY" --profile laravel --apply >/dev/null 2>&1 || fail "legacy fixture install failed"
# Simulate a consumer that adopted before the fix: their project-owned ignore file has no
# exclusion for the engine checkout.
# Strip the engine-checkout exclusion using the path read from the TEMPLATE (§29), not a
# hardcoded literal: with the literal, changing SENTINEL_SHIELD_PATH in the template turned
# this negative control into a silent no-op — it would strip nothing, the fixture would still
# exclude the checkout, and the "legacy consumer" case would never be exercised.
#
# `grep -v` also exits 1 when it selects NO lines, and under `set -e` the `grep … && mv` list
# would then abort the entire suite instead of failing one check. Guarded so an empty result
# is a reported failure, not a dead run.
if grep -v "^${SS_PATH}/\{0,1\}$" "$LEGACY/.semgrepignore" > "$LEGACY/.semgrepignore.tmp"; then
	mv "$LEGACY/.semgrepignore.tmp" "$LEGACY/.semgrepignore"
else
	rm -f "$LEGACY/.semgrepignore.tmp"
	fail "legacy fixture: stripping '$SS_PATH' left nothing behind — the installed .semgrepignore is not what this control assumes"
fi
if ignores "$LEGACY/.semgrepignore" "$SS_PATH/scripts/x.sh"; then
	fail "the legacy fixture still excludes the checkout — the negative control is not exercising anything"
else
	pass "negative control: the legacy ignore file does NOT exclude the checkout"
fi
# BEFORE the repair, doctor must report the gap — that report is what tells a legacy
# consumer to run the sync in the first place.
_doc=$(sh scripts/doctor.sh --target "$LEGACY" --profile laravel 2>&1 || true)
if printf '%s' "$_doc" | grep -q 'does not exclude the configured Sentinel Shield checkout path'; then
	pass "doctor reports an ignore file that does not exclude the engine checkout"
else
	fail "doctor did NOT report a consumer whose .semgrepignore leaves the engine checkout scanned"
fi
# …and the sync REPAIRS it: the required rule is merged back into the project-owned file
# rather than the gap being left open forever.
sh scripts/sync-baseline.sh --target "$LEGACY" --profile laravel --apply >/dev/null 2>&1 || true
if ignores "$LEGACY/.semgrepignore" "$SS_PATH/scripts/x.sh"; then
	pass "sync-baseline merged the required exclusion back into the legacy ignore file"
else
	fail "sync-baseline left a legacy ignore file that does not exclude the engine checkout"
fi
_doc=$(sh scripts/doctor.sh --target "$LEGACY" --profile laravel 2>&1 || true)
if printf '%s' "$_doc" | grep -q 'does not exclude the configured Sentinel Shield checkout path'; then
	fail "doctor still reports the gap after the sync repaired it"
else
	pass "  and doctor no longer reports the gap"
fi

# A NON-DEFAULT SENTINEL_SHIELD_PATH must produce actionable guidance rather than silence.
MOVED="$WORK/moved"
mkdir -p "$MOVED"
sh scripts/install-baseline.sh --target "$MOVED" --profile laravel --apply >/dev/null 2>&1 || fail "moved fixture install failed"
for _wf in "$MOVED"/.github/workflows/*.yml; do
	[ -e "$_wf" ] || continue
	sed 's#SENTINEL_SHIELD_PATH: tools/sentinel-shield#SENTINEL_SHIELD_PATH: vendor/ss-engine#' "$_wf" > "$_wf.tmp" && mv "$_wf.tmp" "$_wf"
done
_doc=$(sh scripts/doctor.sh --target "$MOVED" --profile laravel 2>&1 || true)
if printf '%s' "$_doc" | grep -q "vendor/ss-engine"; then
	pass "doctor detects a non-default SENTINEL_SHIELD_PATH that is not excluded, and names it"
else
	fail "doctor did not flag a non-default SENTINEL_SHIELD_PATH left unexcluded"
fi
if printf '%s' "$_doc" | grep -q "add 'vendor/ss-engine/' to .semgrepignore"; then
	pass "the guidance is actionable (states the exact rule to add)"
else
	fail "the non-default-path warning is not actionable"
fi

# ---------------------------------------------------------------------------
# 4. Source ignore templates must all carry the exclusion (a new profile copying an old
#    template cannot reintroduce the defect).
# ---------------------------------------------------------------------------
_srcs=$(jq -r -s '[.[] | .files[]? | select(.target == ".semgrepignore") | .source] | unique | .[]' \
	profiles/*/profile.manifest.json profiles/combinations/*.manifest.json 2>/dev/null || true)
_n=0
for _s in $_srcs; do
	_n=$((_n + 1))
	if [ ! -f "$_s" ]; then fail "manifest references a missing ignore template: $_s"; continue; fi
	if grep -qE "^${SS_PATH}/?$" "$_s"; then
		pass "ignore template excludes the checkout: $_s"
	else
		fail "ignore template does NOT exclude $SS_PATH/: $_s"
	fi
done
if [ "$_n" -ge 3 ]; then
	pass "$_n distinct ignore template(s) checked"
else
	fail "only $_n ignore template(s) found — the manifest sweep is not covering the profiles"
fi

# Every spelling Semgrep honours for excluding a directory must satisfy doctor. Matching
# only `path` and `path/` produced a false WARN on correctly configured projects, which
# teaches adopters to ignore the check.
SPELL="$WORK/spell"
for _form in '.sentinel-shield' '.sentinel-shield/' '/.sentinel-shield' '/.sentinel-shield/' '.sentinel-shield/**' '/.sentinel-shield/**'; do
	rm -rf "$SPELL"; mkdir -p "$SPELL"
	sh scripts/install-baseline.sh --target "$SPELL" --profile laravel --apply >/dev/null 2>&1 \
		|| { fail "spelling fixture install failed"; break; }
	for _wf in "$SPELL"/.github/workflows/*.yml; do
		[ -e "$_wf" ] || continue
		sed 's#SENTINEL_SHIELD_PATH: [^[:space:]]*#SENTINEL_SHIELD_PATH: .sentinel-shield#' "$_wf" > "$_wf.tmp" && mv "$_wf.tmp" "$_wf"
	done
	printf '%s\n' "$_form" > "$SPELL/.semgrepignore"
	_doc=$(sh scripts/doctor.sh --target "$SPELL" --profile laravel 2>&1 || true)
	if printf '%s' "$_doc" | grep -q 'does not exclude the configured Sentinel Shield checkout'; then
		fail "doctor false-WARNs on the valid .semgrepignore spelling '$_form'"
	else
		pass "doctor accepts the .semgrepignore spelling '$_form'"
	fi
done
# …and a genuinely unrelated exclusion still fails closed.
printf '%s\n' 'src/generated' > "$SPELL/.semgrepignore"
_doc=$(sh scripts/doctor.sh --target "$SPELL" --profile laravel 2>&1 || true)
if printf '%s' "$_doc" | grep -q 'does not exclude the configured Sentinel Shield checkout'; then
	pass "doctor still reports an ignore file that excludes something else entirely"
else
	fail "doctor accepted an ignore file that does not exclude the engine checkout"
fi

# Multiple unexcluded paths must produce one suggestion PER path, not a joined nonsense
# token like 'a b/'.
MULTI="$WORK/multi"
rm -rf "$MULTI"; mkdir -p "$MULTI/.github/workflows"
printf 'name: a\nenv:\n  SENTINEL_SHIELD_PATH: vendor/engine-a\n' > "$MULTI/.github/workflows/a.yml"
printf 'name: b\nenv:\n  SENTINEL_SHIELD_PATH: vendor/engine-b\n' > "$MULTI/.github/workflows/b.yml"
printf 'src/generated\n' > "$MULTI/.semgrepignore"
_doc=$(sh scripts/doctor.sh --target "$MULTI" --profile laravel 2>&1 || true)
if printf '%s' "$_doc" | grep -q "add 'vendor/engine-a/' 'vendor/engine-b/' to .semgrepignore"; then
	pass "doctor suggests one exclusion per unexcluded path"
else
	fail "doctor's multi-path remediation hint is not per-path: $(printf '%s' "$_doc" | grep 'does not exclude' || true)"
fi

# An EXISTING project .semgrepignore used to be left untouched, so a project that adopted
# before the exclusion existed never received it and Semgrep kept scanning the engine
# checkout. The file is still project-owned; the required rules are merged into it.
MERGE="$WORK/merge"
rm -rf "$MERGE"; mkdir -p "$MERGE/.sentinel-shield"
printf '# project rules\nnode_modules/\n' > "$MERGE/.semgrepignore"
sh scripts/sync-baseline.sh --target "$MERGE" --profile laravel --apply >/dev/null 2>&1 || true
if grep -qxF 'tools/sentinel-shield/' "$MERGE/.semgrepignore"; then
	pass "sync merges the engine-checkout exclusion into an existing .semgrepignore"
else
	fail "an existing .semgrepignore never received the engine-checkout exclusion"
fi
if grep -qxF 'node_modules/' "$MERGE/.semgrepignore"; then
	pass "  and keeps the project's own entries"
else
	fail "  but destroyed the project's own entries"
fi
_before=$(cat "$MERGE/.semgrepignore")
sh scripts/sync-baseline.sh --target "$MERGE" --profile laravel --apply >/dev/null 2>&1 || true
if [ "$_before" = "$(cat "$MERGE/.semgrepignore")" ]; then
	pass "  and the merge is idempotent"
else
	fail "  but re-running the merge changed the file again"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '283-semgrep-scope: ALL CHECKS PASSED\n'
	exit 0
fi
printf '283-semgrep-scope: FAILURES PRESENT\n'
exit 1
