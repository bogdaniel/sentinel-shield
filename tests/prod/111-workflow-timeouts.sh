#!/bin/sh
# Sentinel Shield production test — every shipped workflow job must set an
# explicit `timeout-minutes`.
#
# A job without a timeout inherits GitHub's 6-hour default: a hung step (a wedged
# scanner, a network stall, an infinite loop) burns a runner for hours and, for
# scheduled jobs, can pile up. This guard fails CLOSED if any job in
# .github/workflows/ or templates/workflows/ omits timeout-minutes.
#
# EXEMPTIONS: none today. If a legitimately-exempt job appears (e.g. a pure
# reusable-workflow caller that cannot carry timeout-minutes), add "<file>:<job>"
# to EXEMPT below with a comment — silent gaps are not allowed.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# shellcheck source=tests/lib/workflow-invocation.sh
. "$ROOT/tests/lib/workflow-invocation.sh"

# Space-separated "file-basename:job" exemptions (documented, none currently).
EXEMPT=""

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

is_exempt() {
	for _e in $EXEMPT; do [ "$_e" = "$1" ] && return 0; done
	return 1
}

# jobs_missing_timeout <file> — print "<job>" for each job lacking timeout-minutes.
# Pure awk (no yq dependency): after `jobs:`, each 2-space key opens a job block;
# a block is satisfied by a `    timeout-minutes:` line before the next job/EOF.
jobs_missing_timeout() {
	awk '
		/^jobs:[[:space:]]*$/ { injobs=1; next }
		{
			# A job key: 2-space indent, bare `name:` with optional trailing comment.
			if (injobs && $0 ~ /^  [A-Za-z0-9_"'"'"'-]+:[[:space:]]*(#.*)?$/) {
				if (cur != "" && !has) print cur
				line=$0; sub(/^  /,"",line); sub(/:.*/,"",line); cur=line; has=0
			}
			# Job-level timeout-minutes (4-space); tolerate a trailing comment.
			if (injobs && $0 ~ /^    timeout-minutes:[[:space:]]/) has=1
		}
		END { if (cur != "" && !has) print cur }
	' "$1"
}

_seen=0
for _dir in "$ROOT/.github/workflows" "$ROOT/templates/workflows"; do
	for _f in "$_dir"/*.yml "$_dir"/*.yaml; do
		[ -e "$_f" ] || continue
		_seen=1
		_base=${_f##*/}
		_missing=$(jobs_missing_timeout "$_f")
		_bad=0
		for _job in $_missing; do
			is_exempt "$_base:$_job" && continue
			fail "$_base: job '$_job' has no timeout-minutes"
			_bad=1
		done
		[ "$_bad" = 0 ] && pass "$_base: all jobs set timeout-minutes"
	done
done

if [ "$_seen" = 0 ]; then
	fail "no workflow files found under .github/workflows or templates/workflows"
fi

# ---------------------------------------------------------------------------
# The two BLOCKING suites must each own a distinct sweep, with a budget that fits it.
# ---------------------------------------------------------------------------
# ci-production-readiness ran `self-test.sh all` and THEN the production-readiness sweep, so
# it duplicated everything ci-self-test already owns and reliably exceeded its budget on the
# second half. A job killed by `timeout-minutes` is reported by GitHub as CANCELLED, not as a
# failure — which is why this looked for days like concurrency cancellation rather than a job
# that never had long enough, and why no amount of waiting for the stack to settle produced
# exact-head evidence on any branch.
#
# The division WAS: ci-self-test owns the COMPLETE suite (`all`); ci-production-readiness owns
# the focused independent sweep. That fixed the timeout, but left `all` — which INCLUDES the
# production sweep — running in ci-self-test while ci-production-readiness ran the same sweep
# again. Duplicate execution, not independent validation (#284).
#
# The division is now: ci-self-test owns `ci-core` (every registered suite EXCEPT the
# production sweep); ci-production-readiness remains the sole owner of `production-readiness`.
# `all` is unchanged in meaning and remains the exhaustive local umbrella, but no longer runs
# in CI as a single job. This asserts that division, because it is the kind of thing a later
# edit restores by accident.
#
# Set coverage (`ci-core ∪ production-readiness = all`, `∩ = ∅`) is proven separately, against
# scripts/self-test.sh itself, by tests/prod/113-suite-topology.sh.
ST=".github/workflows/ci-self-test.yml"
PR=".github/workflows/ci-production-readiness.yml"
# run_count <repo-relative-file> <arg> — how many lines invoke self-test.sh with exactly <arg>.
# The matcher lives in tests/lib/workflow-invocation.sh so 113 uses the same one; see there for
# why it matches invocations rather than one spelling of them.
run_count() { wf_run_count_int "$ROOT/$1" "$2"; }

_n=$(run_count "$ST" ci-core)
[ "$_n" -eq 1 ] && pass "ci-self-test invokes self-test.sh ci-core exactly once" \
	|| fail "ci-self-test invokes self-test.sh ci-core $_n time(s); expected exactly 1"
_n=$(run_count "$ST" all)
[ "$_n" -eq 0 ] && pass "ci-self-test does not invoke self-test.sh all" \
	|| fail "ci-self-test invokes self-test.sh all $_n time(s); \`all\` includes the production sweep that ci-production-readiness already owns, so this restores the duplicate ~40-minute execution #284 removed"
_n=$(run_count "$PR" all)
[ "$_n" -eq 0 ] && pass "ci-production-readiness does not invoke self-test.sh all" \
	|| fail "ci-production-readiness invokes self-test.sh all $_n time(s); the core suite belongs to ci-self-test, and running it twice is what exhausted this job's budget"
_n=$(run_count "$PR" ci-core)
[ "$_n" -eq 0 ] && pass "ci-production-readiness does not invoke self-test.sh ci-core" \
	|| fail "ci-production-readiness invokes self-test.sh ci-core $_n time(s); ci-core belongs to ci-self-test"
_n=$(run_count "$PR" production-readiness)
[ "$_n" -eq 1 ] && pass "ci-production-readiness invokes self-test.sh production-readiness exactly once" \
	|| fail "ci-production-readiness invokes self-test.sh production-readiness $_n time(s); expected exactly 1"
_n=$(run_count "$ST" production-readiness)
[ "$_n" -eq 0 ] && pass "ci-self-test does not invoke self-test.sh production-readiness" \
	|| fail "ci-self-test invokes self-test.sh production-readiness $_n time(s); ci-production-readiness is its sole owner"

# Budgets. A number is asserted, not merely the key's presence: the whole defect was a job
# whose timeout was smaller than the work it was given.
job_timeout() { # job_timeout <file> <job>
	awk -v job="$2" '
		$0 ~ "^  " job ":[[:space:]]*$" { inb = 1; next }
		inb && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
		inb && /^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+/ {
			sub(/^[[:space:]]*timeout-minutes:[[:space:]]*/, ""); print; exit }
	' "$ROOT/$1" 2>/dev/null
}
# These are CURRENT SAFETY FLOORS derived from observed runtime — not targets, not optima, and
# not a claim that the suite should take this long. They exist so a job cannot be given less
# time than the work it is known to need. Raising them later needs no change here; LOWERING
# them does, and should be accompanied by a fresh measurement showing the suite got faster.
#
# The floors come from MEASUREMENT, not from a guess. Timed on the branch tip:
#
#     scripts/self-test.sh all                  3589s = 59.8 min
#     scripts/self-test.sh production-readiness 2672s = 44.5 min
#
# A first attempt at this fix used 35/30, which is below BOTH figures — it would have been
# killed at a higher wall and looked like the remediation failed rather than like the budget
# was still wrong. CI additionally pays for checkout, dependency setup and cleanup, and
# full-self-test runs workflow-sanity and fixtures on top of `all`, so the floors carry real
# headroom for runner variance rather than tracking the measurement exactly.
_t=$(job_timeout "$ST" full-self-test); case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
[ "$_t" -ge 90 ] && pass "ci-self-test/full-self-test budget is $_t min (>= 90)" \
	|| fail "ci-self-test/full-self-test budget is $_t min, below the current safety floor of 90. \`self-test.sh all\` was measured at 59.8 min, before checkout, dependency setup and this job's extra workflow-sanity and fixture steps — at $_t min the job is killed at the budget and GitHub reports it as 'cancelled'. The floor is derived from that observation, not from an ideal runtime; lower it only with a fresh measurement."
# The matcher must see every spelling, or the contract is enforceable only against the one
# form we happen to ship today. The fixtures now live with the matcher in
# tests/lib/workflow-invocation.sh, so both this suite and 113-suite-topology.sh prove the
# same parser rather than each trusting it.
wf_run_count_selfcheck pass fail

_t=$(job_timeout "$PR" self-tests); case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
[ "$_t" -ge 75 ] && pass "ci-production-readiness/self-tests budget is $_t min (>= 75)" \
	|| fail "ci-production-readiness/self-tests budget is $_t min, below the current safety floor of 75. The production sweep was measured at 44.5 min before setup — at $_t min the job is killed at the budget and GitHub reports it as 'cancelled'. The floor is derived from that observation, not from an ideal runtime; lower it only with a fresh measurement."

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d workflow job(s) missing timeout-minutes\n' "$FAILS" >&2
	exit 1
fi
exit 0
