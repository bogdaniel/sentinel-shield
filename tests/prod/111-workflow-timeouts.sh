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
# The division is now: ci-self-test owns the COMPLETE suite; ci-production-readiness owns the
# focused independent sweep. This asserts that division, because it is the kind of thing a
# later edit restores by accident.
ST=".github/workflows/ci-self-test.yml"
PR=".github/workflows/ci-production-readiness.yml"
# run_count <file> <arg> — how many `run:` lines invoke self-test.sh with exactly <arg>.
run_count() {
	# Match the INVOCATION, not one spelling of it. The first version required
	# `run: sh scripts/self-test.sh <arg>` on a single line, so `./scripts/self-test.sh all`,
	# `bash scripts/self-test.sh all`, or the same command inside a multiline `run: |` block all
	# counted as zero — and ci-production-readiness could restore the complete suite, and its
	# timeout risk, while still passing this check. A contract enforced against one spelling is
	# not enforced.
	#
	# So: any line that invokes the script with that argument, however it is spelled, and
	# whether or not `run:` is on the same line. Comments are excluded so prose mentioning a
	# command is not counted as running it.
	grep -vE '^[[:space:]]*#' "$ROOT/$1" 2>/dev/null \
		| grep -cE "(^|[[:space:]]|/)(sh|bash|dash)?[[:space:]]*\.?/?scripts/self-test\.sh[[:space:]]+$2([[:space:]]|\$)" \
		|| true
}
_n=$(run_count "$ST" all); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
[ "$_n" -eq 1 ] && pass "ci-self-test invokes self-test.sh all exactly once" \
	|| fail "ci-self-test invokes self-test.sh all $_n time(s); expected exactly 1"
_n=$(run_count "$PR" all); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
[ "$_n" -eq 0 ] && pass "ci-production-readiness does not invoke self-test.sh all" \
	|| fail "ci-production-readiness invokes self-test.sh all $_n time(s); the complete suite belongs to ci-self-test, and running it twice is what exhausted this job's budget"
_n=$(run_count "$PR" production-readiness); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
[ "$_n" -eq 1 ] && pass "ci-production-readiness invokes self-test.sh production-readiness exactly once" \
	|| fail "ci-production-readiness invokes self-test.sh production-readiness $_n time(s); expected exactly 1"

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
# form we happen to ship today. Fixtures for each: direct `./scripts/...`, `bash scripts/...`,
# and the command inside a multiline `run: |` block — the three ways ci-production-readiness
# could quietly regain the complete suite while this check still reported zero.
_rcf=$(mktemp -d)
printf 'jobs:\n  a:\n    steps:\n      - run: ./scripts/self-test.sh all\n' > "$_rcf/direct.yml"
printf 'jobs:\n  a:\n    steps:\n      - run: bash scripts/self-test.sh all\n' > "$_rcf/bash.yml"
printf 'jobs:\n  a:\n    steps:\n      - run: |\n          set -eu\n          sh scripts/self-test.sh all\n' > "$_rcf/multiline.yml"
printf 'jobs:\n  a:\n    steps:\n      # sh scripts/self-test.sh all  (documentation, not an invocation)\n      - run: echo hi\n' > "$_rcf/comment.yml"
_saved_root="$ROOT"; ROOT="$_rcf"
for _form in direct bash multiline; do
	_n=$(run_count "$_form.yml" all); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
	[ "$_n" -eq 1 ] && pass "run_count detects the $_form invocation form" \
		|| fail "run_count missed the $_form invocation form ($_n) — the suite could be restored without this check noticing"
done
_n=$(run_count "comment.yml" all); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
[ "$_n" -eq 0 ] && pass "run_count does not count a commented-out invocation" \
	|| fail "run_count counted a comment as an invocation ($_n)"
ROOT="$_saved_root"
rm -rf "$_rcf"

_t=$(job_timeout "$PR" self-tests); case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
[ "$_t" -ge 75 ] && pass "ci-production-readiness/self-tests budget is $_t min (>= 75)" \
	|| fail "ci-production-readiness/self-tests budget is $_t min, below the current safety floor of 75. The production sweep was measured at 44.5 min before setup — at $_t min the job is killed at the budget and GitHub reports it as 'cancelled'. The floor is derived from that observation, not from an ideal runtime; lower it only with a fresh measurement."

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d workflow job(s) missing timeout-minutes\n' "$FAILS" >&2
	exit 1
fi
exit 0
