#!/bin/sh
# Sentinel Shield prod test — installed-product compatibility matrix (issues #84, #87).
#
# Workflow-template validation used to be STATIC: YAML parsing, permissions, trigger safety,
# pin checks and selected textual invariants. Every one of those passed while the assembled
# product was inconsistent — a profile required `reports/raw/syft.json` that no workflow step
# produced, the workflow wrote `reports/sbom.spdx.json` instead, and the split and combined
# templates produced different evidence for the same policy. "Workflow validation passed"
# could therefore coexist with a broken first consumer run (run-tool-plan exit 3).
#
# This suite exercises the ASSEMBLED product for every supported profile: the real installer,
# the real resolver, the real manifests, the real report paths and the real workflow files —
# never a duplicated model of them. It runs offline and deterministically: no live scanner is
# required, and no assertion is satisfied by a skip.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
COVERAGE="$ROOT/scripts/verify-producer-coverage.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$COVERAGE" ] || { fail "missing scripts/verify-producer-coverage.sh"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

PROFILES="laravel symfony php-library node react docker node-react laravel-react-docker hardened-enterprise"

# ---------------------------------------------------------------------------
# 1. Producer coverage over the whole matrix (the #84 contract).
# ---------------------------------------------------------------------------
_c=0; sh "$COVERAGE" >/dev/null 2>&1 || _c=$?
check "every required tool in every profile/stage/variant has exactly one producer" "$_c" 0

# The matrix must actually cover the shipped profiles — a silently empty run would "pass".
_covered=$(sh "$COVERAGE" 2>/dev/null | grep -c '^== profile=' || true)
case "$_covered" in '' | *[!0-9]*) _covered=0 ;; esac
if [ "$_covered" -ge 40 ]; then
	pass "coverage matrix evaluated $_covered profile/stage/variant combinations"
else
	fail "coverage matrix only evaluated $_covered combinations — it is not covering the shipped profiles"
fi
for _p in $PROFILES; do
	sh "$COVERAGE" --profile "$_p" >/dev/null 2>&1 \
		&& pass "profile '$_p' is fully covered" \
		|| fail "profile '$_p' has an uncovered required tool"
done

# NEGATIVE CONTROL: a workflow that produces nothing must FAIL the coverage check, otherwise
# every result above could be vacuous.
printf 'name: empty\non:\n  push:\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' > "$WORK/empty-workflow.yml"
_c=0; sh "$COVERAGE" --profile laravel --stage main --workflow "$WORK/empty-workflow.yml" >/dev/null 2>&1 || _c=$?
check "negative control: a workflow with no producers fails coverage" "$_c" 1

# NEGATIVE CONTROL: a runner declared but absent from disk must fail.
_c=0; sh "$COVERAGE" --profile does-not-exist-profile >/dev/null 2>&1 || _c=$?
check "an unresolvable profile fails closed" "$_c" 1

# ---------------------------------------------------------------------------
# 2. Report paths agree across profile, collector and summary builder.
# ---------------------------------------------------------------------------
_mismatch=0
_checked=0
for _p in $PROFILES; do
	_eff=$(sh scripts/resolve-effective-profile.sh --profile "$_p" --format json 2>/dev/null) || continue
	for _pair in $(printf '%s' "$_eff" | jq -r '.tools | to_entries[] | select(.value.report != null) | "\(.key)=\(.value.report)"'); do
		_k="${_pair%%=*}"; _r="${_pair#*=}"
		_col="scripts/collectors/$_k.sh"
		[ -f "$_col" ] || continue
		_checked=$((_checked + 1))
		# The collector's default INPUT must be the very path the profile promises.
		_in=$(grep -E '^INPUT="' "$_col" | head -n1 | sed -E 's/^INPUT="([^"]*)".*/\1/')
		[ -n "$_in" ] || continue
		if [ "$_in" != "$_r" ]; then
			fail "report-path mismatch for '$_k' in profile '$_p': profile says '$_r', collector reads '$_in'"
			_mismatch=1
		fi
	done
done
[ "$_checked" -gt 0 ] || fail "no profile/collector report paths were compared"
[ "$_mismatch" -eq 0 ] && pass "profile report paths match their collectors ($_checked comparisons)"

# The Syft path regression specifically: the profile contract, the collector and BOTH shipped
# main-gate variants must all name reports/raw/syft.json.
_syft=$(jq -r '.tools.syft.report' profiles/laravel/profile.manifest.json)
check "the laravel profile's syft report path" "$_syft" "reports/raw/syft.json"
for _wf in templates/workflows/sentinel-shield.yml templates/workflows/sentinel-shield-main.yml; do
	grep -Fq "$_syft" "$_wf" && pass "$(basename "$_wf") produces $_syft" || fail "$(basename "$_wf") does not produce $_syft"
done

# ---------------------------------------------------------------------------
# 3. Install -> dry-run -> apply -> sync -> drift-repair for every profile.
# ---------------------------------------------------------------------------
for _p in $PROFILES; do
	_t="$WORK/inst-$_p"; mkdir -p "$_t"
	if ! sh scripts/install-baseline.sh --target "$_t" --profile "$_p" >/dev/null 2>&1; then
		fail "$_p: dry-run install failed"; continue
	fi
	[ "$(find "$_t" -mindepth 1 | wc -l | tr -d ' ')" = "0" ] || fail "$_p: dry-run wrote files"
	if ! sh scripts/install-baseline.sh --target "$_t" --profile "$_p" --apply >/dev/null 2>&1; then
		fail "$_p: apply install failed"; continue
	fi
	_wf="$_t/.github/workflows/sentinel-shield.yml"
	if [ ! -f "$_wf" ]; then fail "$_p: no managed workflow installed"; continue; fi
	# The installed workflow must reference a real, non-placeholder engine source.
	if grep -qE '^[[:space:]]*SENTINEL_SHIELD_REPOSITORY:[[:space:]]*(YOUR_ORG/|<)' "$_wf"; then
		fail "$_p: the installed workflow still carries the engine-source placeholder"
	fi
	# It must parse and still declare the source-checkout steps.
	grep -q 'run-tool-plan.sh' "$_wf" || fail "$_p: the installed workflow does not run the tool plan"
	# Sync must be a no-op immediately after install, and must repair a deliberate drift.
	sh scripts/sync-baseline.sh --target "$_t" --profile "$_p" --apply --force >/dev/null 2>&1 || fail "$_p: sync failed"
	printf '# drifted\n' >> "$_wf"
	_out=$(sh scripts/sync-baseline.sh --target "$_t" --profile "$_p" 2>&1 || true)
	printf '%s' "$_out" | grep -q 'manual-review-needed (managed drift' \
		|| fail "$_p: sync did not detect managed drift in the workflow"
	sh scripts/sync-baseline.sh --target "$_t" --profile "$_p" --apply --force >/dev/null 2>&1 || fail "$_p: drift repair failed"
	grep -q '^# drifted$' "$_wf" && fail "$_p: drift repair did not restore the managed workflow"
	pass "$_p: install (dry-run + apply), sync and drift repair behave"
done

# ---------------------------------------------------------------------------
# 4. Deterministic structural run over the REAL fixture evidence sets. No live scanner is
#    involved: the e2e fixtures are recorded scanner output, so this exercises the actual
#    collectors, the summary builder and the enforcer against the profile contract.
# ---------------------------------------------------------------------------
# profile:fixture-directory
FIXTURE_MAP="laravel:tests/e2e/laravel
symfony:tests/e2e/symfony
laravel-react-docker:tests/e2e/laravel-react-docker
node:tests/e2e/js-only
react:tests/e2e/typescript"

# stage_run <profile> <fixture-dir> <stage> <work-suffix> — build the summary from the fixture
# evidence and echo the resulting required_tool_failures ("x" when the build failed).
stage_run() {
	_sp="$1"; _sf="$2"; _ss="$3"; _sw="$WORK/run-$1-$3-$4"
	mkdir -p "$_sw/reports"
	cp -R "$ROOT/$_sf/reports/raw" "$_sw/reports/raw" 2>/dev/null || return 1
	printf '{"SPDXID":"SPDXRef-DOCUMENT"}' > "$_sw/reports/sbom.spdx.json"
	# Complete the evidence set IN THE COPY (never in the repo fixture, which the e2e harness
	# owns and whose runner-owned reports it deliberately does not seed). A report is filled
	# from the shipped example shape, or from the fixture's own canonical tests report for a
	# one-of test group. Anything still missing is left missing — the assertion then fails
	# loudly instead of being quietly satisfied.
	for _need in $(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_sp" --format json 2>/dev/null |
		jq -r --arg s "$_ss" '[
			(.tools | to_entries[] | select((.value.policy // "") == "required" and .value.execution[$s] == true) | .value.report // empty),
			(.one_of_groups // {} | to_entries[] | .key) as $g | empty
		] | .[]'); do
		[ -f "$_sw/$_need" ] && continue
		_base=$(basename "$_need" .json)
		if [ -f "$ROOT/templates/raw/$_base.example.json" ]; then
			cp "$ROOT/templates/raw/$_base.example.json" "$_sw/$_need"
		fi
	done
	# One-of group reports (js-tests/php-tests) are runner-owned; the summary builder only
	# READS them, so standing in the fixture's canonical tests report is legitimate here.
	for _g in $(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_sp" --format json 2>/dev/null |
		jq -r '(.one_of_groups // {}) | to_entries[] | select((.value.policy // "") == "required") | .key'); do
		_gr=$(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_sp" --format json 2>/dev/null |
			jq -r --arg g "$_g" '(.tools[$g].report // ((.one_of_groups[$g].alternatives[]? ) as $m | .tools[$m].report) // "")' | head -n1)
		[ -n "$_gr" ] || continue
		[ -f "$_sw/$_gr" ] && continue
		[ -f "$_sw/reports/raw/tests.json" ] && cp "$_sw/reports/raw/tests.json" "$_sw/$_gr"
	done
	[ "$4" = "corrupt" ] && printf 'not-json{' > "$_sw/reports/raw/semgrep.json"
	[ "$4" = "missing" ] && rm -f "$_sw/reports/raw/semgrep.json"
	( cd "$_sw" && sh "$ROOT/scripts/build-security-summary.sh" --profile "$_sp" --stage "$_ss" \
		--target . --raw-dir reports/raw --output reports/security-summary.json >/dev/null 2>&1 ) || { printf 'x'; return 0; }
	jq -r '.summary.required_tool_failures // "x"' "$_sw/reports/security-summary.json"
}

for _entry in $FIXTURE_MAP; do
	_p="${_entry%%:*}"; _f="${_entry#*:}"
	if [ ! -d "$ROOT/$_f/reports/raw" ]; then
		printf 'SKIP: no fixture evidence at %s — the mock run for %s did not execute\n' "$_f" "$_p"
		continue
	fi
	check "$_p: the fixture evidence satisfies every REQUIRED main-stage tool" "$(stage_run "$_p" "$_f" main clean)" 0
	# The #84 regression, asserted directly: a tool the profile requires only at `scheduled`
	# must NOT be gate-enforced in a MAIN summary (that is what made a main gate unpassable).
	_sum="$WORK/run-$_p-main-clean/reports/security-summary.json"
	if [ -f "$_sum" ]; then
		_sched=$(sh scripts/resolve-effective-profile.sh --profile "$_p" --format json 2>/dev/null |
			jq -r '[.tools | to_entries[] | select((.value.policy // "") == "required" and .value.execution.main != true and .value.execution.scheduled == true) | .key] | join(" ")')
		for _k in $_sched; do
			_emit=$(printf '%s' "$_k" | tr '-' '_')
			_ge=$(jq -r --arg e "$_emit" '.tools[$e].gate_enforced // "absent"' "$_sum")
			case "$_ge" in
				false | absent) pass "$_p: scheduled-only tool '$_k' is not gate-enforced in the main summary" ;;
				*) fail "$_p: scheduled-only tool '$_k' is gate-enforced at main (gate_enforced=$_ge) — the main gate cannot pass" ;;
			esac
		done
	fi
	# NEGATIVE CONTROLS on the same evidence set.
	_corrupt=$(stage_run "$_p" "$_f" main corrupt)
	if [ "$_corrupt" = "x" ] || [ "$_corrupt" -gt 0 ] 2>/dev/null; then
		pass "$_p: invalid JSON in a required report never yields a clean result ($_corrupt)"
	else
		fail "$_p: invalid JSON in a required report still produced required_tool_failures=0"
	fi
	_missing=$(stage_run "$_p" "$_f" main missing)
	if [ "$_missing" = "x" ] || [ "$_missing" -gt 0 ] 2>/dev/null; then
		pass "$_p: a missing required report never yields a clean result ($_missing)"
	else
		fail "$_p: a missing required report still produced required_tool_failures=0"
	fi
done

# An unknown --stage must be rejected rather than silently disabling stage scoping.
_c=0; sh scripts/build-security-summary.sh --stage nonsense --raw-dir "$WORK" --output "$WORK/x.json" >/dev/null 2>&1 || _c=$?
check "an unknown --stage is rejected" "$_c" 2

# ---------------------------------------------------------------------------
# 5. Cross-file regressions this matrix exists to catch.
# ---------------------------------------------------------------------------
# (a) stale engine ref in an active template
_ref=$(jq -r '.consumer_ref.value' config/release-status.json 2>/dev/null || printf '')
if [ -n "$_ref" ]; then
	# (No `grep -E "(?!…)"` here. A negative lookahead is PCRE, not POSIX ERE: grep rejects
	# the pattern, exits 2, the redirected stderr hides it and the count is always 0. The loop
	# below is the check that actually reads each template and compares the pinned ref.)
	_bad=0
	for _wf in templates/workflows/*.yml; do
		_v=$(sed -nE 's/^[[:space:]]*SENTINEL_SHIELD_REF:[[:space:]]*([^[:space:]#]+).*/\1/p' "$_wf" | head -n1)
		[ -n "$_v" ] && [ "$_v" != "$_ref" ] && { fail "template $(basename "$_wf") pins a stale engine ref '$_v' (contract: $_ref)"; _bad=1; }
	done
	[ "$_bad" -eq 0 ] && pass "no active template pins a stale engine ref"
fi
# (b) Semgrep self-scan regression, on the installed product
_t="$WORK/inst-laravel"
if [ -f "$_t/.semgrepignore" ]; then
	grep -qE '^tools/sentinel-shield/?$' "$_t/.semgrepignore" \
		&& pass "the installed product excludes the embedded engine checkout from Semgrep" \
		|| fail "the installed product would scan the embedded engine checkout with Semgrep"
fi
# (c) split vs combined equivalence for the same policy: both must produce every main report.
_diff=0
for _p in $PROFILES; do
	_eff=$(sh scripts/resolve-effective-profile.sh --profile "$_p" --format json 2>/dev/null) || continue
	for _r in $(printf '%s' "$_eff" | jq -r '.tools | to_entries[] | select((.value.policy // "") == "required" and .value.execution.main == true and (.value.runner // "") == "") | .value.report // empty'); do
		_inc=0; _ins=0
		grep -Fq "$_r" templates/workflows/sentinel-shield.yml && _inc=1
		grep -Fq "$_r" templates/workflows/sentinel-shield-main.yml && _ins=1
		if [ "$_inc" != "$_ins" ]; then
			fail "split/combined divergence for $_p: $_r produced by combined=$_inc split=$_ins"
			_diff=1
		fi
	done
done
[ "$_diff" -eq 0 ] && pass "the split and combined main gates produce the same required reports"

# --- CodeRabbit round 2: a --workflow path the tool never read ----------------
# workflow_section resolved "$REPO_ROOT/$1" unconditionally, so an ABSOLUTE path became
# "$REPO_ROOT//tmp/…", `[ -f ]` failed and the function returned nothing — the tool then
# reported "no producer" for a file it never opened, and the control asserting that passed
# for the wrong reason. A typo must never be able to masquerade as "no producers".
_c=0; sh "$ROOT/scripts/verify-producer-coverage.sh" --workflow "/nonexistent/definitely-not-here.yml" >/dev/null 2>&1 || _c=$?
check "a nonexistent --workflow path exits 2, not 'no producer'" "$_c" 2
_tmpwf=$(mktemp -d)/wf.yml; mkdir -p "$(dirname "$_tmpwf")"
printf 'name: probe\njobs:\n  probe:\n    steps:\n      - run: echo reports/raw/gitleaks.json\n' > "$_tmpwf"
_c=0; sh "$ROOT/scripts/verify-producer-coverage.sh" --workflow "$_tmpwf" >/dev/null 2>&1 || _c=$?
if [ "$_c" -eq 2 ]; then
	fail "an ABSOLUTE --workflow path that EXISTS is still treated as unreadable"
else
	pass "an absolute --workflow path is read from where it actually is"
fi
rm -rf "$(dirname "$_tmpwf")"

# The same guarantee for the BUILT-IN workflow map, which had no such check. Only the
# user-supplied --workflow paths were validated up front; the guard covering the built-in
# entries lived inside workflow_section(), which is called as
#
#   if workflow_section "$f" "$job" | grep -Fq "$path"; then
#
# — left of a pipe, inside an `if`, inside a `while` fed by a pipe. Its `exit 2` unwound only
# the innermost subshell; grep then read empty input and returned 1. Deleting one mapped
# template made the tool emit 62 "NO PRODUCER" findings for a file it never opened and exit 1
# (findings) instead of 2 (unreadable input) — an unreadable input turned into a result.
_probe="$WORK/coverage-tree"
rm -rf "$_probe"; mkdir -p "$_probe"
# A tree the script can run from: it resolves REPO_ROOT from its own location.
(cd "$ROOT" && tar cf - scripts config profiles templates schemas 2>/dev/null) | (cd "$_probe" && tar xf -)
_missing="$_probe/templates/workflows/sentinel-shield-main.yml"
if [ -f "$_missing" ]; then
	rm -f "$_missing"
	_c=0; _out=$(sh "$_probe/scripts/verify-producer-coverage.sh" --stage main 2>&1) || _c=$?
	check "a MISSING built-in mapped workflow exits 2, not a report of findings" "$_c" 2
	check "  and no 'NO PRODUCER' finding is emitted for the file that was never read" \
		"$(printf '%s' "$_out" | grep -c 'NO PRODUCER' || true)" "0"
else
	fail "fixture setup: sentinel-shield-main.yml was not copied into the probe tree"
fi
rm -rf "$_probe"

# ---------------------------------------------------------------------------
# An unresolved profile is a configuration failure, never a guessed default.
# ---------------------------------------------------------------------------
# Silently running `laravel-react-docker` meant the producer-coverage checker could prove every
# required producer for the intended profile while the installed workflow enforced a different
# stack, because its policy artifact was missing or ambiguous.
for _wf in "$ROOT"/templates/workflows/sentinel-shield.yml \
	"$ROOT"/templates/workflows/sentinel-shield-main.yml \
	"$ROOT"/templates/workflows/sentinel-shield-pr-fast.yml; do
	_b=$(basename "$_wf")
	if grep -vE '^[[:space:]]*#' "$_wf" | grep -q 'PROFILE=laravel-react-docker\|PROFILE="laravel-react-docker"'; then
		fail "$_b still falls back to a hardcoded profile when resolution yields nothing"
	else
		pass "$_b has no hardcoded profile fallback"
	fi
	# The previous pattern was "SENTINEL_SHIELD_PROJECT_TYPE=' .*head -n1" — a stray quote and
	# a space that no workflow line can contain, so the `else` branch always ran and this
	# passed vacuously, in a suite whose header promises "no assertion is satisfied by a skip".
	#
	# What actually constitutes first-wins is piping a grep for the key into `head -n1` (or
	# `sed -n 1p`, or `awk NR==1`) and using that as the value. Match the SHAPE of that, and
	# exempt the counting line, which legitimately reads the key to reject a duplicate.
	if grep -vE '^[[:space:]]*#' "$_wf" \
		| grep -E 'SENTINEL_SHIELD_PROJECT_TYPE=' \
		| grep -vE 'grep -cE|_pt_n' \
		| grep -qE '\|[[:space:]]*(head -n ?1|sed -n .?1p|awk .?NR ?== ?1)'; then
		fail "$_b still takes the FIRST value of a possibly duplicated policy key"
	else
		pass "  and does not first-wins a duplicated policy key"
	fi
	if grep -q 'declares SENTINEL_SHIELD_PROJECT_TYPE' "$_wf" || grep -q 'declares $1' "$_wf"; then
		pass "  rejecting an ambiguous count explicitly"
	else
		fail "$_b does not reject a duplicated SENTINEL_SHIELD_PROJECT_TYPE"
	fi
done


# --- a REQUIRED tool with nothing behind it must not be certified ------------
# The no-report/no-runner branch is only reached for a tool the profile marks REQUIRED and
# SELECTS at this stage, and it used to `pass` with "nothing to enforce" — certifying a
# required control that nothing can produce, run or verify. A declaration with no
# implementation reported as satisfied is the failure this engine exists to refuse. The
# legitimate shape (a `category: setup` precondition with an `executable` contract) is now
# named explicitly instead of being covered by that same silence.
_gp="$WORK/ghost-probe"
rm -rf "$_gp"; mkdir -p "$_gp"
(cd "$ROOT" && tar cf - scripts config profiles templates schemas 2>/dev/null) | (cd "$_gp" && tar xf -)
if [ -f "$_gp/profiles/node/profile.manifest.json" ]; then
	jq '.tools["ghost-control"] = {policy:"required", category:"sast",
		execution:{pr:true, main:true, scheduled:false}}' \
		"$_gp/profiles/node/profile.manifest.json" > "$_gp/n.json" \
		&& mv "$_gp/n.json" "$_gp/profiles/node/profile.manifest.json"
	_c=0; _out=$(sh "$_gp/scripts/verify-producer-coverage.sh" --profile node --stage pr 2>&1) || _c=$?
	check "a REQUIRED tool with no report, runner, executable or alternatives fails coverage" "$_c" "1"
	check "  and is named as unenforceable rather than passed over" \
		"$(printf '%s' "$_out" | grep -c 'ghost-control: REQUIRED and selected' || true)" "2"
	check "  while 'nothing to enforce' is no longer reported for anything" \
		"$(printf '%s' "$_out" | grep -c 'nothing to enforce' || true)" "0"
else
	fail "ghost probe: the node profile manifest was not copied"
fi
rm -rf "$_gp"
# The precondition tool that legitimately has neither report nor runner is still passed, and
# passed BY NAME, so the reader can see which contract is actually being enforced for it.
_c=0; _out=$(sh "$COVERAGE" --profile node --stage pr 2>&1) || _c=$?
check "the real node profile still passes" "$_c" "0"
check "  and deps-install is passed as an executable contract, not as 'nothing'" \
	"$(printf '%s' "$_out" | grep -c 'deps-install: precondition tool' || true)" "2"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '285-installed-product-compatibility: ALL CHECKS PASSED\n'
	exit 0
fi
printf '285-installed-product-compatibility: FAILURES PRESENT\n'
exit 1
