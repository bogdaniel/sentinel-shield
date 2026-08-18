#!/bin/sh
# Sentinel Shield — semantic reconciliation between the live GitHub backlog and
# config/remediation-plan.json (#345 continuation).
#
# WHY THIS EXISTS
#
# `ci-backlog-reconciliation` ran green while the plan and the backlog disagreed, because the
# live half of tests/prod/112 compared MEMBERSHIP only: every open issue appears in the plan,
# and no closed issue is listed as active work. Both held. Neither says anything about whether
# an issue's status, priority, type, domain or milestone still matches the plan — so #345 sat
# at status:partial live and `ready` in the plan with nothing able to notice.
#
# Membership agreement is not semantic agreement. This script is the difference.
#
# ONE IMPLEMENTATION, ONE TRUST BOUNDARY
#
# The comparison lives here rather than inside the test, so the suite, the governance workflow
# and any future report all read the same rules. The rules themselves live in
# config/backlog-semantics.json — not in shell conditionals — because a label-to-plan
# translation scattered across `case` arms is how the taxonomy and the plan drift apart in the
# first place.
#
# The live snapshot is passed in as a file in exactly the shape
# `gh issue list --json number,state,labels,milestone` returns. That is what makes every rule
# below provable offline against a fixture, including the defect this replaces.
#
# Usage:
#   reconcile-backlog.sh --plan <file> --live <file> --semantics <file> [--json]
#
# Exit 0 when the backlog and the plan agree semantically, 1 when they do not, 2 on a usage or
# input error. Never 0 on an unreadable input: a reconciliation that cannot read its inputs has
# not reconciled anything.
set -eu

rb_die() { printf 'reconcile-backlog: %s\n' "$*" >&2; exit 2; }

PLAN=""; LIVE=""; SEMANTICS=""; AS_JSON=0; AS_OF=""
while [ $# -gt 0 ]; do
	case $1 in
	--plan) PLAN=${2:-}; shift 2 ;;
	--live) LIVE=${2:-}; shift 2 ;;
	--semantics) SEMANTICS=${2:-}; shift 2 ;;
	--json) AS_JSON=1; shift ;;
	--as-of) AS_OF=${2:-}; shift 2 ;;
	-h | --help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) rb_die "unknown argument: $1" ;;
	esac
done
[ -n "$PLAN" ] && [ -n "$LIVE" ] && [ -n "$SEMANTICS" ] || rb_die "usage: reconcile-backlog.sh --plan <file> --live <file> --semantics <file> [--json]"
for _f in "$PLAN" "$LIVE" "$SEMANTICS"; do
	[ -f "$_f" ] || rb_die "not a file: $_f"
done
command -v jq >/dev/null 2>&1 || rb_die "jq is required"
# The review boundary is compared against a DATE, so the date is an input. Production takes today;
# a fixture pins one, because an expiry test that changes verdict with the calendar is not a test.
[ -n "$AS_OF" ] || AS_OF=$(date -u +%Y-%m-%d)
case $AS_OF in
[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
*) rb_die "--as-of expects YYYY-MM-DD, got: $AS_OF" ;;
esac

# THE DECLARED MAPPING IS FIXED, AND SAYING SO IS THE POINT.
#
# The jq below hard-codes each label prefix and plan key. field_mapping supplies the FIELD NAMES
# and which of them are normative; it does not drive extraction. That is a deliberate bound --
# deriving extraction from configuration would mean building a general accessor -- but a config
# surface that looks editable and is silently ignored is worse than one that refuses.
#
# So the supported mapping is pinned here. Change label_prefix or plan_key in the semantics file
# and this refuses to run rather than comparing the wrong thing.
# `normative` IS PART OF THE PIN. It was omitted, and that reopened the hole the pin exists to
# close: $NORM is built from `normative == true`, and the priority, type, primary_domain and
# milestone comparisons are all gated on membership. Flipping one flag to false passed this
# guard and made the reconciler report agreement over a real drift. (status is not gated, so it
# stayed enforced -- which is exactly why the gap was invisible.)
_supported='status|status:|status|true
priority|priority:|priority|true
type|type:|type|true
primary_domain|area:|primary_domain|true
milestone||milestone_title|true'
_declared=$(jq -r '.field_mapping[]? | [.field, (.label_prefix // ""), (.plan_key // ""), ((.normative // false) | tostring)] | join("|")' "$SEMANTICS" | sort)
_pinned=$(printf '%s\n' "$_supported" | sort)
if [ "$_declared" != "$_pinned" ]; then
	printf 'reconcile-backlog: the declared field mapping is not the one this implementation supports.\n' >&2
	printf 'declared:\n%s\nsupported:\n%s\n' "$_declared" "$_pinned" >&2
	rb_die "refusing to compare against a mapping that would be ignored"
fi

# EVERY review_by MUST BE A REAL DATE, validated here rather than only in the suite.
#
# The expiry test is a lexical string comparison, which is correct for YYYY-MM-DD and meaningless
# for anything else: "30/09/2026" < "2026-08-18" is false, so such an entry never expires at any
# --as-of. That is the unbounded exception config/backlog-semantics.json forbids.
#
# The grammar is exact and fully checked: four-digit year, month 01-12, day within that month's
# real length, leap years by the 4/100/400 rule. Plain integer arithmetic, so it is portable --
# no strptime, whose behaviour varies by platform.
_bad_dates=$(jq -r '
	def is_leap($y): ($y % 4 == 0) and (($y % 100 != 0) or ($y % 400 == 0));
	def dim($y; $m): [31, (if is_leap($y) then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][$m - 1];
	def valid($d):
		($d | type == "string")
		and ($d | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
		and (($d[0:4] | tonumber) as $y | ($d[5:7] | tonumber) as $m | ($d[8:10] | tonumber) as $day
		     | ($m >= 1 and $m <= 12) and ($day >= 1 and $day <= dim($y; $m)));
	[ .reconciliation_debt.entries[]?
	  | select((.review_by | valid(.)) | not)
	  | "#\(.issue)/\(.field // "?")=\(.review_by // "absent")" ] | join(" ")
	' "$SEMANTICS" 2>/dev/null) || rb_die "could not read review_by values from $SEMANTICS"
if [ -n "$_bad_dates" ]; then
	printf 'reconcile-backlog: debt entry(ies) whose review_by is not a real YYYY-MM-DD date: %s\n' "$_bad_dates" >&2
	rb_die "a debt entry whose review boundary cannot be compared would never expire"
fi

# The whole comparison is ONE jq program taking three documents. Written as a single filter on
# purpose: a per-issue shell loop invoking jq is where the "translate the label here, and
# slightly differently over there" family of defects comes from.
_out=$(jq -n \
	--slurpfile plan "$PLAN" \
	--slurpfile live "$LIVE" \
	--slurpfile sem "$SEMANTICS" \
	--arg asof "$AS_OF" '
	($plan[0].issues // []) as $P
	| ($live[0] // []) as $L
	| $sem[0] as $S
	| ($S.status_labels // {}) as $SL
	| ([$S.field_mapping[]? | select(.normative == true) | .field]) as $NORM
	| ($S.reconciliation_debt.entries // []) as $DEBT
	# Index the live snapshot by issue number. A duplicate number in the snapshot is itself a
	# finding: it makes every lookup below order-dependent.
	| ([$L[] | .number] | group_by(.) | map(select(length > 1) | .[0])) as $dupnums
	| (reduce $L[] as $i ({}; .[$i.number | tostring] = $i)) as $LI
	| (def labels($i; $pfx): [$i.labels[]?.name | select(startswith($pfx)) | ltrimstr($pfx)];
	   def one($a): if ($a | length) == 1 then $a[0] else null end;
	   # ---- per-issue semantic comparison -------------------------------------------------
	   [ $P[] as $r
	     | ($r.issue | tostring) as $k
	     | ($LI[$k]) as $i
	     | if $i == null then
	         { issue: $r.issue, rule: "membership", detail: "planned issue is not in the live open snapshot" }
	       else
	         (labels($i; "status:")) as $st
	         | (one(labels($i; "priority:"))) as $pri
	         | (one(labels($i; "type:"))) as $ty
	         | (one(labels($i; "area:"))) as $ar
	         | ($i.milestone.title // null) as $ms
	         | (if ($st | length) == 0 then
	              { issue: $r.issue, rule: "status-label-missing", detail: "no status:* label; the plan expects \($r.status)" }
	            elif ($st | length) > 1 then
	              { issue: $r.issue, rule: "status-label-duplicate", detail: "\($st | length) status labels: \($st | join(", "))" }
	            elif ($SL["status:" + $st[0]] == null) then
	              { issue: $r.issue, rule: "status-label-unknown", detail: "status:\($st[0]) is not declared in backlog-semantics" }
	            elif ($SL["status:" + $st[0]].valid_for_open_planned_work != true) then
	              { issue: $r.issue, rule: "status-label-not-valid-open", detail: "status:\($st[0]) is declared invalid for open planned work: \($SL["status:" + $st[0]].reason // "no reason recorded")" }
	            elif ($SL["status:" + $st[0]].plan_status != $r.status) then
	              # A named debt entry permits exactly this pair for exactly this issue.
	              (if ([$DEBT[] | select(.issue == $r.issue and .field == "status" and .plan_value == $r.status and .live_value == $st[0])] | length) > 0
	               then empty
	               else { issue: $r.issue, rule: "status-drift", detail: "plan says \($r.status), live says \($st[0])" }
	               end)
	            else empty end),
	           (if ($NORM | index("priority")) and $pri != null and $pri != $r.priority then
	              { issue: $r.issue, rule: "priority-drift", detail: "plan says \($r.priority), live says \($pri)" } else empty end),
	           (if ($NORM | index("priority")) and $pri == null then
	              { issue: $r.issue, rule: "priority-label-missing", detail: "no single priority:* label" } else empty end),
	           (if ($NORM | index("type")) and $ty != null and $ty != $r.type then
	              { issue: $r.issue, rule: "type-drift", detail: "plan says \($r.type), live says \($ty)" } else empty end),
	           (if ($NORM | index("type")) and $ty == null then
	              { issue: $r.issue, rule: "type-label-missing", detail: "no single type:* label" } else empty end),
	           (if ($NORM | index("primary_domain")) and $ar != null and $ar != $r.primary_domain then
	              { issue: $r.issue, rule: "domain-drift", detail: "plan says \($r.primary_domain), live says \($ar)" } else empty end),
	           # `one()` yields null for BOTH zero and several area labels, so the drift test above
	           # cannot see either. An unresolvable normative field is reported, not skipped.
	           (if ($NORM | index("primary_domain")) and $ar == null then
	              { issue: $r.issue, rule: "domain-label-unresolvable", detail: "\(labels($i; "area:") | length) area:* label(s); exactly one is required to compare against primary_domain \($r.primary_domain)" } else empty end),
	           (if ($NORM | index("milestone")) and $ms != $r.milestone_title then
	              (if ([$DEBT[] | select(.issue == $r.issue and .field == "milestone" and .plan_value == $r.milestone_title and .live_value == $ms)] | length) > 0
	               then empty
	               else { issue: $r.issue, rule: "milestone-drift", detail: "plan says \($r.milestone_title // "none"), live says \($ms // "none")" }
	               end) else empty end)
	       end ]) as $issue_v
	| (# ---- debt hygiene: the list may only shrink ---------------------------------------
	   # Each entry is judged on the value of ITS OWN field. An entry that no longer disagrees
	   # is stale and must be removed; an entry whose pair changed is not silently absorbed.
	   [ $DEBT[] as $d
	     | ($d.issue | tostring) as $k
	     | ($LI[$k]) as $i
	     | ([$P[] | select(.issue == $d.issue)] | first) as $r
     # PRESENCE, not truthiness. `plan_value` and `live_value` may legitimately be null -- an
	     # unassigned milestone is recorded as null -- so they are checked with has(). The
	     # remaining fields must additionally be non-empty: an owner of "" excuses nothing.
	     | (([ "issue", "field", "plan_value", "live_value", "reason", "owner", "remediation", "created", "review_by", "source" ]
	         | map(. as $f | select(($d | has($f)) | not)))
	        + ([ "issue", "field", "reason", "owner", "remediation", "created", "review_by", "source" ]
	         | map(. as $f | select(($d | has($f)) and (($d[$f]) == null or ($d[$f]) == ""))))
	        | unique) as $absent
	     | if ($absent | length) > 0 then
	         { issue: $d.issue, rule: "debt-incomplete", detail: "\($d.field // "?"): missing required field(s): \($absent | join(", "))" }
	       elif (($S.field_mapping // []) | map(select(.normative == true) | .field) | index($d.field)) == null then
	         { issue: $d.issue, rule: "debt-field-not-normative", detail: "\($d.field): the field is no longer normative, so the exception has nothing to excuse" }
	       elif ($d.review_by < $asof) then
	         { issue: $d.issue, rule: "debt-expired", detail: "\($d.field): review boundary \($d.review_by) passed (as of \($asof)); owner \($d.owner), remediation: \($d.remediation)" }
	       elif $r == null then
	         { issue: $d.issue, rule: "debt-not-planned", detail: "\($d.field): names an issue that is not in the plan" }
	       elif $i == null then
	         { issue: $d.issue, rule: "debt-not-live", detail: "\($d.field): names an issue that is not open" }
	       elif ($d.reason // "") == "" then
	         { issue: $d.issue, rule: "debt-no-reason", detail: "\($d.field): entry carries no machine-readable reason" }
	       elif (($S.reconciliation_debt.classes // {})[$d.reason] == null) then
	         { issue: $d.issue, rule: "debt-unknown-class", detail: "\($d.field): reason \($d.reason) is not a declared debt class" }
	       else
	         (if $d.field == "status" then
	            ([$i.labels[]?.name | select(startswith("status:")) | ltrimstr("status:")]) as $st
	            | if ($st | length) != 1 then { observed: null, plan: $r.status, bad: true }
	              else { observed: $SL["status:" + $st[0]].plan_status, plan: $r.status, bad: false } end
	          elif $d.field == "milestone" then
	            { observed: ($i.milestone.title // null), plan: $r.milestone_title, bad: false }
	          elif $d.field == "priority" then
	            { observed: ([$i.labels[]?.name | select(startswith("priority:")) | ltrimstr("priority:")] | first), plan: $r.priority, bad: false }
	          elif $d.field == "type" then
	            { observed: ([$i.labels[]?.name | select(startswith("type:")) | ltrimstr("type:")] | first), plan: $r.type, bad: false }
	          elif $d.field == "primary_domain" then
	            { observed: ([$i.labels[]?.name | select(startswith("area:")) | ltrimstr("area:")] | first), plan: $r.primary_domain, bad: false }
	          else { observed: null, plan: null, bad: true } end) as $o
	         | if $o.bad then
	             { issue: $d.issue, rule: "debt-unresolvable", detail: "\($d.field): the observed value cannot be determined" }
	           elif $o.observed == $o.plan then
	             { issue: $d.issue, rule: "debt-stale",
	               detail: "\($d.field): STALE — recorded live value \($d.live_value // "none"), current live value \($o.observed // "none"), expected plan value \($o.plan // "none"). The mismatch this entry excused no longer exists, so the exception is obsolete and must be removed. Reason was \($d.reason); owner \($d.owner); source \($d.source)." }
	           elif ($o.plan != $d.plan_value) or ($o.observed != $d.live_value) then
	             { issue: $d.issue, rule: "debt-shape-changed", detail: "\($d.field): recorded \($d.plan_value // "none")/\($d.live_value // "none"), observed \($o.plan // "none")/\($o.observed // "none")" }
	           else empty end
	       end ]) as $debt_v
	| (# A declared class with no entries is stale in the same way an entry is: it has nothing
	   # left to excuse, and it survives only as a slot for the next exemption.
	   # `.key` inside the array below would rebind `.` to each DEBT ENTRY, which has no `key`,
	   # so the comparison would never match. The class key is bound to $ck FIRST, outside the
	   # array, and only $ck is used.
	   [ ($S.reconciliation_debt.classes // {}) | to_entries[]
	     | .key as $ck
	     | if ([$DEBT[] | select(.reason == $ck)] | length) == 0 then
	         { issue: 0, rule: "debt-class-empty", detail: "declared debt class \($ck) has no entries — remove the class with its last entry" }
	       else empty end ]) as $class_v
	| { violations: ($issue_v + $debt_v + $class_v + [$dupnums[] | { issue: ., rule: "live-snapshot-duplicate", detail: "issue appears more than once in the live snapshot" }]),
	    compared: ($P | length),
	    live_count: ($L | length),
	    debt_entries: ($DEBT | length),
	    normative_fields: $NORM }
	') || rb_die "the comparison did not run to completion — treat as unreconciled"

if [ "$AS_JSON" = 1 ]; then
	printf '%s\n' "$_out"
else
	printf '%s' "$_out" | jq -r '.violations[] | "VIOLATION #\(.issue) \(.rule): \(.detail)"'
	printf '%s' "$_out" | jq -r '"compared \(.compared) planned issue(s) against \(.live_count) live issue(s); \(.debt_entries) named debt entry(ies); normative fields: \(.normative_fields | join(", "))"'
fi

# THE ZERO-TARGET GUARD, and the one case it must NOT catch.
#
# An empty plan beside a non-empty backlog is genuine vacuity: every rule above iterates the
# PLAN, so open work that is absent from it is never examined at all, and the comparison would
# report agreement having compared nothing.
#
# Both sides empty is the OPPOSITE — it is the finished state this programme is working toward,
# and it is perfect agreement. A blunt "refuse when either side is empty" guard was written here
# first and it broke exactly that: tests/prod/110 runs this suite against an empty plan with a
# stubbed `gh` returning `[]` precisely because a governance check that fails on completion is a
# check nobody can ever satisfy. That is the same mistake 112's own live half already carries a
# comment about, reintroduced one layer down.
#
# A non-empty plan beside an empty backlog needs no guard: it is already one membership
# violation per planned issue.
_compared=$(printf '%s' "$_out" | jq -r '.compared')
_livec=$(printf '%s' "$_out" | jq -r '.live_count')
if [ "$_compared" -eq 0 ] && [ "$_livec" -gt 0 ]; then
	printf 'reconcile-backlog: refusing to report agreement — the plan is empty while %s live issue(s) are open, so nothing was compared\n' \
		"$_livec" >&2
	exit 1
fi

_v=$(printf '%s' "$_out" | jq -r '.violations | length')
[ "$_v" -eq 0 ] || exit 1
exit 0
