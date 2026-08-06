#!/bin/sh
# Sentinel Shield production test — self-test suite topology.
#
# WHY THIS EXISTS (#284)
#
# `ci-self-test` ran `self-test.sh all` and `ci-production-readiness` ran the production
# sweep. `all` INCLUDES that sweep, so the ~40-minute suite executed in both workflows. That
# is duplicate execution, not independent validation: both invoke the same implementation and
# compare against the same oracle, so a defect in the sweep is not caught twice — it is missed
# twice, at double the runner cost.
#
# The duplication was, however, doing one useful thing by accident: it GUARANTEED that every
# suite ran somewhere. Remove the overlap and that guarantee disappears with it. So coverage
# has to stop being an emergent property of the overlap and become an asserted one:
#
#     ci-core ∪ production-readiness = all
#     ci-core ∩ production-readiness = ∅
#     every registered suite belongs to exactly one blocking workflow
#
# Without this, a suite dropped from `run_ci_core()` disappears from CI silently: `ci-core`
# still passes, `production-readiness` still passes, and nothing reports that a suite stopped
# running. A missing suite is indistinguishable from a passing one.
#
# The workflow-side matcher is shared with tests/prod/111-workflow-timeouts.sh
# (tests/lib/workflow-invocation.sh) rather than reimplemented here — a second, weaker parser
# for the same contract is how one of them quietly stops matching.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck source=tests/lib/workflow-invocation.sh
. "$ROOT/tests/lib/workflow-invocation.sh"

ST_SH="$ROOT/scripts/self-test.sh"
WF_SELF="$ROOT/.github/workflows/ci-self-test.yml"
WF_PROD="$ROOT/.github/workflows/ci-production-readiness.yml"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

[ -f "$ST_SH" ] || { fail "scripts/self-test.sh is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` inside the trap: an aborted run must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# --- parsers ---------------------------------------------------------------
# All three strip full-line comments first. A commented-out suite is documentation, not a
# registration and not an invocation — counting one would let a suite look covered while it
# never runs.
#
# `registered_suites <file>` — subcommand names from the `case "$SUB" in` dispatch, excluding
# the composite/meta arms (`all`, `ci-core`, help, catch-all).
registered_suites() {
	grep -vE '^[[:space:]]*#' "$1" |
		awk '
			/^[[:space:]]*case[[:space:]]+"\$SUB"[[:space:]]+in/ { inc = 1; next }
			inc && /^esac/ { inc = 0 }
			inc && /^[[:space:]]*[a-z0-9|-]+\)[[:space:]]*run_[a-z0-9_]+[[:space:]]*;;/ {
				line = $0
				sub(/^[[:space:]]*/, "", line)
				sub(/\).*/, "", line)
				if (line != "all" && line != "ci-core") print line
			}
		' | sort -u
}

# `suite_fn <file> <subcommand>` — the run_* function a subcommand dispatches to.
suite_fn() {
	grep -vE '^[[:space:]]*#' "$1" |
		awk -v s="$2" '
			$0 ~ ("^[[:space:]]*" s "\\)[[:space:]]*run_[a-z0-9_]+[[:space:]]*;;") {
				line = $0
				sub(/^[^)]*\)[[:space:]]*/, "", line)
				sub(/[[:space:]]*;;.*/, "", line)
				print line
				exit
			}
		'
}

# `fn_body_calls <file> <function-name>` — run_* calls inside a function definition.
fn_body_calls() {
	grep -vE '^[[:space:]]*#' "$1" |
		awk -v f="$2" '
			$0 ~ ("^" f "\\(\\)[[:space:]]*\\{") { inf = 1; next }
			inf && /^\}/ { inf = 0 }
			inf && /^[[:space:]]*run_[a-z0-9_]+[[:space:]]*$/ {
				line = $0
				gsub(/[[:space:]]/, "", line)
				print line
			}
		' | sort -u
}

# `case_arm_calls <file> <arm>` — run_* calls inside a multi-line `case` arm.
case_arm_calls() {
	grep -vE '^[[:space:]]*#' "$1" |
		awk -v a="$2" '
			$0 ~ ("^[[:space:]]*" a "\\)[[:space:]]*$") { ina = 1; next }
			ina && /^[[:space:]]*;;[[:space:]]*$/ { ina = 0 }
			ina && /^[[:space:]]*run_[a-z0-9_]+[[:space:]]*$/ {
				line = $0
				gsub(/[[:space:]]/, "", line)
				print line
			}
		' | sort -u
}

# --- the three sets --------------------------------------------------------
fn_body_calls "$ST_SH" run_ci_core > "$TMP/core"
suite_fn "$ST_SH" production-readiness > "$TMP/prod"
case_arm_calls "$ST_SH" all > "$TMP/all_arm"

CORE_N=$(wc -l < "$TMP/core" | tr -d ' ')
[ "$CORE_N" -gt 0 ] && pass "run_ci_core() registers $CORE_N suite(s)" \
	|| { fail "run_ci_core() could not be parsed or is empty — every assertion below would be vacuous"; exit 1; }
[ -s "$TMP/prod" ] && pass "production-readiness dispatches to $(cat "$TMP/prod")" \
	|| { fail "the production-readiness case arm could not be parsed"; exit 1; }

# `all` must be exactly run_ci_core + the production sweep. Composition, not a second
# hand-maintained list of 48 calls: two lists drift the first time somebody adds a suite to
# one of them.
{ echo run_ci_core; cat "$TMP/prod"; } | sort -u > "$TMP/all_expected"
if cmp -s "$TMP/all_arm" "$TMP/all_expected"; then
	pass "the 'all' arm is exactly run_ci_core + $(cat "$TMP/prod")"
else
	fail "the 'all' arm is [$(tr '\n' ' ' < "$TMP/all_arm")], expected [$(tr '\n' ' ' < "$TMP/all_expected")] — 'all' must be COMPOSED from ci-core and the production sweep, never re-list the suites"
fi

# ci-core ∪ production-readiness = all  (expanded to the real suite set)
sort -u "$TMP/core" "$TMP/prod" > "$TMP/union"
registered_suites "$ST_SH" > "$TMP/registered"
REG_N=$(wc -l < "$TMP/registered" | tr -d ' ')
: > "$TMP/registered_fns"
while read -r _s; do
	_f=$(suite_fn "$ST_SH" "$_s")
	if [ -z "$_f" ]; then
		fail "registered suite '$_s' does not dispatch to a run_* function"
	else
		echo "$_f" >> "$TMP/registered_fns"
	fi
done < "$TMP/registered"
sort -u "$TMP/registered_fns" -o "$TMP/registered_fns"

_uncovered=$(comm -23 "$TMP/registered_fns" "$TMP/union" | tr '\n' ' ')
if [ -z "$_uncovered" ]; then
	pass "ci-core ∪ production-readiness covers all $REG_N registered suite(s)"
else
	fail "registered suite(s) run by NEITHER ci-core nor production-readiness: $_uncovered — these no longer execute in CI at all, and a missing suite is indistinguishable from a passing one"
fi

_phantom=$(comm -13 "$TMP/registered_fns" "$TMP/union" | tr '\n' ' ')
if [ -z "$_phantom" ]; then
	pass "ci-core ∪ production-readiness contains no unregistered function"
else
	fail "ci-core/production-readiness invoke function(s) with no registered subcommand: $_phantom"
fi

# ci-core ∩ production-readiness = ∅
_overlap=$(comm -12 "$TMP/core" "$TMP/prod" | tr '\n' ' ')
if [ -z "$_overlap" ]; then
	pass "ci-core ∩ production-readiness = ∅"
else
	fail "suite(s) in BOTH ci-core and production-readiness: $_overlap — that is the duplicate execution #284 removed"
fi

# --- every registered suite belongs to exactly one blocking workflow -------
# ci-self-test owns whatever ci-core runs; ci-production-readiness owns the sweep. A suite
# invoked directly by a workflow that does not own it would be a second owner.
_st_core=$(wf_run_count_int "$WF_SELF" ci-core)
_pr_prod=$(wf_run_count_int "$WF_PROD" production-readiness)
[ "$_st_core" -eq 1 ] && pass "ci-self-test invokes ci-core exactly once" \
	|| fail "ci-self-test invokes ci-core $_st_core time(s); expected exactly 1"
[ "$_pr_prod" -eq 1 ] && pass "ci-production-readiness invokes production-readiness exactly once" \
	|| fail "ci-production-readiness invokes production-readiness $_pr_prod time(s); expected exactly 1"

_two_owners=""
while read -r _s; do
	_f=$(suite_fn "$ST_SH" "$_s")
	# Which set does the suite live in?
	if grep -qx "$_f" "$TMP/core" 2>/dev/null; then _owner=ci-self-test
	elif grep -qx "$_f" "$TMP/prod" 2>/dev/null; then _owner=ci-production-readiness
	else continue; fi
	# A direct invocation from the OTHER blocking workflow is a second owner. A direct
	# invocation from the owning workflow is fast-feedback duplication inside one workflow,
	# which is a cost question, not a coverage-ownership violation.
	if [ "$_owner" = ci-self-test ]; then
		[ "$(wf_run_count_int "$WF_PROD" "$_s")" -eq 0 ] || _two_owners="$_two_owners $_s"
	else
		[ "$(wf_run_count_int "$WF_SELF" "$_s")" -eq 0 ] || _two_owners="$_two_owners $_s"
	fi
done < "$TMP/registered"
if [ -z "$_two_owners" ]; then
	pass "every registered suite belongs to exactly one blocking workflow"
else
	fail "suite(s) invoked by a second blocking workflow:$_two_owners"
fi

# --- the parsers must be provably not-fooled ------------------------------
# A parser that silently stopped matching would report an empty set, and every assertion
# above would pass vacuously. Each fixture is a way the real file could drift.
cat > "$TMP/fixture.sh" <<'FIXTURE'
#!/bin/sh
run_ci_core() {
	run_alpha
	run_beta
#	run_ghost_commented
}
case "$SUB" in
	alpha) run_alpha ;;
	beta) run_beta ;;
#	ghost) run_ghost_commented ;;
	production-readiness) run_production_readiness ;;
	ci-core) run_ci_core ;;
	all)
		run_ci_core
		run_production_readiness
		;;
esac
FIXTURE

_fx_core=$(fn_body_calls "$TMP/fixture.sh" run_ci_core | tr '\n' ' ')
[ "$_fx_core" = "run_alpha run_beta " ] \
	&& pass "fn_body_calls ignores a commented-out suite call (self-check)" \
	|| fail "fn_body_calls returned [$_fx_core] on the fixture; expected [run_alpha run_beta ] — a commented-out call must not count as coverage"

_fx_reg=$(registered_suites "$TMP/fixture.sh" | tr '\n' ' ')
[ "$_fx_reg" = "alpha beta production-readiness " ] \
	&& pass "registered_suites ignores a commented-out case arm and excludes all/ci-core (self-check)" \
	|| fail "registered_suites returned [$_fx_reg] on the fixture; expected [alpha beta production-readiness ]"

_fx_all=$(case_arm_calls "$TMP/fixture.sh" all | tr '\n' ' ')
[ "$_fx_all" = "run_ci_core run_production_readiness " ] \
	&& pass "case_arm_calls reads the composed 'all' arm (self-check)" \
	|| fail "case_arm_calls returned [$_fx_all] on the fixture; expected [run_ci_core run_production_readiness ]"

# A fixture where a suite was dropped from ci-core must be REJECTED — proof the coverage
# check can actually fail, not just pass.
sed '/run_beta$/d' "$TMP/fixture.sh" > "$TMP/dropped.sh"
_dropped_core=$(fn_body_calls "$TMP/dropped.sh" run_ci_core | tr '\n' ' ')
_dropped_reg=$(registered_suites "$TMP/dropped.sh" | tr '\n' ' ')
case "$_dropped_core$_dropped_reg" in
*run_beta*) fail "the dropped-suite fixture still reports run_beta as covered — the coverage check cannot detect a dropped suite" ;;
*) case "$_dropped_reg" in
	*beta*) pass "a suite dropped from run_ci_core is still registered and therefore reported uncovered (self-check)" ;;
	*) fail "the dropped-suite fixture lost the 'beta' registration too, so the check would not notice" ;;
	esac ;;
esac

# The shared workflow matcher proves itself (every invocation spelling, comments, and that
# `ci-core` is never read as `all`).
wf_run_count_selfcheck pass fail

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d suite-topology check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nsuite-topology: OK (ci-core=%s, production-readiness=1, registered=%s)\n' "$CORE_N" "$REG_N"
exit 0
