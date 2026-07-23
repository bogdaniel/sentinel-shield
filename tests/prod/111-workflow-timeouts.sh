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

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d workflow job(s) missing timeout-minutes\n' "$FAILS" >&2
	exit 1
fi
exit 0
