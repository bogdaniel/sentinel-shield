#!/bin/sh
# Sentinel Shield — render the authoritative backlog report from
# config/remediation-plan.json.
#
# The plan file is the source of truth; this only renders it. If you want a
# different answer, change the plan and let tests/prod/112-remediation-plan.sh
# re-validate it — do not special-case anything here.
#
# Usage:
#   scripts/backlog-report.sh            # human-readable rollup
#   scripts/backlog-report.sh ready      # issues unblocked and actionable now
#   scripts/backlog-report.sh json       # the raw plan, for other tooling
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLAN="$ROOT/config/remediation-plan.json"
MODE=${1:-summary}

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
[ -f "$PLAN" ] || { echo "missing $PLAN" >&2; exit 1; }

case "$MODE" in
json)
	cat "$PLAN"
	;;
ready)
	# Actionable now: nothing blocking it, and not already finished/parked.
	jq -r '
		.issues
		| map(select((.blocked_by | length) == 0 and .type != "epic"
		             and (.status == "ready" or .status == "in-progress")))
		| sort_by(.priority, .milestone, .issue)
		| .[]
		| "\(.priority)\t\(.milestone)\t#\(.issue)\t\(.implementation_group)"
	' "$PLAN"
	;;
summary)
	printf 'Sentinel Shield — remediation backlog\n'
	printf 'plan generated for master %s\n\n' "$(jq -r '.generated_for_master' "$PLAN")"

	printf 'BY MILESTONE\n'
	jq -r '
		.milestones[] as $m
		| ([.issues[] | select(.milestone == $m.key)]) as $rows
		| "  \($m.key)  epic #\($m.epic)  total=\($rows | length)"
		  + "  p0=\([$rows[] | select(.priority == "p0")] | length)"
		  + "  ready=\([$rows[] | select(.status == "ready" and .type != "epic")] | length)"
		  + "  blocked=\([$rows[] | select(.status == "blocked")] | length)"
		  + "   \($m.title)"
	' "$PLAN"

	printf '\nBY PRIORITY\n'
	jq -r '
		[.issues[] | select(.type != "epic") | .priority]
		| group_by(.) | sort_by(-length)[]
		| "  \(.[0])\t\(length)"
	' "$PLAN"

	printf '\nBY STATUS\n'
	jq -r '
		[.issues[] | .status] | group_by(.) | sort_by(-length)[]
		| "  \(.[0])\t\(length)"
	' "$PLAN"

	printf '\nBY DOMAIN\n'
	jq -r '
		[.issues[] | select(.type != "epic") | .primary_domain]
		| group_by(.) | sort_by(-length)[]
		| "  \(.[0])\t\(length)"
	' "$PLAN"

	printf '\nHIGHEST-FANOUT BLOCKERS (unblock these first)\n'
	jq -r '
		[.issues[] | select((.blocks | length) > 0)]
		| sort_by(-(.blocks | length))
		| .[0:8][]
		| "  #\(.issue)\tblocks \(.blocks | length)\t\(.milestone)\t\(.implementation_group)"
	' "$PLAN"

	printf '\nACTIONABLE NOW: %s issue(s) — see `scripts/backlog-report.sh ready`\n' \
		"$(jq '[.issues[] | select((.blocked_by | length) == 0 and .type != "epic" and .status == "ready")] | length' "$PLAN")"
	;;
*)
	echo "usage: backlog-report.sh [summary|ready|json]" >&2
	exit 2
	;;
esac
