#!/bin/sh
# Sentinel Shield production test — config/remediation-plan.json is the single
# machine-readable source of truth for the remediation backlog.
#
# WHY THIS EXISTS
# The v2 audit left 158 open issues with no milestone, no owner and no declared
# dependency order. Organising them in the GitHub UI alone puts the plan in a
# place nothing can validate: a label can be removed, an issue can be filed into
# two waves, a dependency can be written down as prose and then contradicted by
# the order work actually happens in. This suite makes the organisation an
# ASSERTED property of the repository rather than a description of it.
#
# The structural half runs everywhere and is the half that catches real damage:
# duplicate mappings, dangling dependency references, dependency cycles, an
# issue in two implementation waves, a vocabulary typo.
#
# The live half (does the plan still match the real open backlog?) needs an
# authenticated `gh`. It runs when one is available and is reported as SKIPPED —
# loudly, never silently — when it is not. It is not gated behind a flag that
# defaults to off, because a drift check nobody runs is not a check.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PLAN="$ROOT/config/remediation-plan.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { fail "jq is required to run this test"; exit 1; }
[ -f "$PLAN" ] || { fail "config/remediation-plan.json is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` inside the trap: an aborted run must keep its non-zero status. A
# cleanup trap that ends in a successful command is exactly how an interrupted
# suite gets reported as a pass.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# --- vocabularies (kept in step with the GitHub label taxonomy) -------------
VALID_MILESTONES='M0 M1 M2 M3 M4 M5'
VALID_PRIORITIES='p0 p1 p2 deferred'
VALID_STATUSES='ready blocked in-progress partial needs-verification deferred'
VALID_DOMAINS='ci evidence collectors adapters scanners profiles policy installer
sync migration transactions governance documentation external-validation'
VALID_TYPES='defect security architecture documentation validation epic ci'
VALID_EVIDENCE='implementation negative-regression exact-head-ci static-topology-proof
seven-defect-regression-fixtures proof-manifest doc-contract-review
live-consumer-run-artifact captured-evidence-bundle all-children-closed
milestone-exit-criteria-met'

in_list() { # in_list <needle> <space/newline-separated list>
	for _i in $2; do [ "$_i" = "$1" ] && return 0; done
	return 1
}

# --- 1. the document parses and carries a schema version -------------------
if jq -e 'type == "object" and (.schema_version | type) == "number"' "$PLAN" >/dev/null 2>&1; then
	pass "plan parses as a JSON object with a numeric schema_version"
else
	fail "plan is not a JSON object with a numeric schema_version"
	exit 1
fi

TOTAL=$(jq '.issues | length' "$PLAN")
[ "$TOTAL" -gt 0 ] || { fail "plan contains no issue records"; exit 1; }
pass "plan contains $TOTAL issue records"

# --- 2. every record carries every required field, non-empty ---------------
_missing=$(jq -r '
	.issues[]
	| select(
		(.issue | type) != "number"
		or (.primary_domain // "") == ""
		or (.milestone // "") == ""
		or (.priority // "") == ""
		or (.status // "") == ""
		or (.type // "") == ""
		or (.implementation_group // "") == ""
		or (.blocked_by | type) != "array"
		or (.blocks | type) != "array"
		or (.closure_evidence | type) != "array"
		or (.closure_evidence | length) == 0
	)
	| .issue // "unnumbered"
' "$PLAN")
if [ -z "$_missing" ]; then
	pass "every record carries issue/domain/milestone/priority/status/type/group/deps/evidence"
else
	for _i in $_missing; do fail "record #$_i is missing a required field"; done
fi

# --- 3. no issue appears twice; no issue is in two waves -------------------
# Uniqueness of `issue` is what makes "exactly one primary technical domain",
# "one implementation wave" and "one parent epic" true by construction — a
# second record for the same issue is the only way those can conflict.
_dupes=$(jq -r '[.issues[].issue] | group_by(.) | map(select(length > 1) | .[0]) | .[]' "$PLAN")
if [ -z "$_dupes" ]; then
	pass "every issue appears exactly once (no issue belongs to two waves)"
else
	for _i in $_dupes; do fail "issue #$_i appears in more than one record"; done
fi

# --- 4. controlled vocabularies -------------------------------------------
_vocab_bad=0
jq -r '.issues[] | "\(.issue) \(.milestone) \(.priority) \(.status) \(.primary_domain) \(.type)"' "$PLAN" > "$TMP/vocab"
while read -r _n _ms _pr _st _dm _ty; do
	in_list "$_ms" "$VALID_MILESTONES" || { fail "#$_n: unknown milestone '$_ms'"; _vocab_bad=1; }
	in_list "$_pr" "$VALID_PRIORITIES" || { fail "#$_n: unknown priority '$_pr'"; _vocab_bad=1; }
	in_list "$_st" "$VALID_STATUSES"   || { fail "#$_n: unknown status '$_st'"; _vocab_bad=1; }
	in_list "$_dm" "$VALID_DOMAINS"    || { fail "#$_n: unknown domain '$_dm'"; _vocab_bad=1; }
	in_list "$_ty" "$VALID_TYPES"      || { fail "#$_n: unknown type '$_ty'"; _vocab_bad=1; }
done < "$TMP/vocab"
[ "$_vocab_bad" = 0 ] && pass "milestone/priority/status/domain/type are all in vocabulary"

_ev_bad=0
for _e in $(jq -r '[.issues[].closure_evidence[]] | unique | .[]' "$PLAN"); do
	in_list "$_e" "$VALID_EVIDENCE" || { fail "unknown closure_evidence kind '$_e'"; _ev_bad=1; }
done
[ "$_ev_bad" = 0 ] && pass "every closure_evidence kind is in vocabulary"

# --- 5. every referenced issue exists in the plan --------------------------
_dangling=$(jq -r '
	[.issues[].issue] as $known
	| .issues[]
	| . as $r
	| ((.blocked_by + .blocks + (if .parent_epic == null then [] else [.parent_epic] end))[]
	   | select(. as $d | $known | index($d) | not)
	   | "\($r.issue)->\(.)")
' "$PLAN")
if [ -z "$_dangling" ]; then
	pass "every blocked_by / blocks / parent_epic reference resolves to a planned issue"
else
	for _d in $_dangling; do fail "dangling reference $_d"; done
fi

# --- 6. blocks is exactly the inverse of blocked_by ------------------------
# Two hand-maintained directions of the same edge drift. Asserting the inverse
# means a dependency can be read from either end and mean the same thing.
_asym=$(jq -r '
	(reduce .issues[] as $r ({}; reduce ($r.blocked_by[]) as $d (.; .[$d|tostring] += [$r.issue]))) as $inv
	| .issues[]
	| select((.blocks | sort) != (($inv[(.issue|tostring)] // []) | sort))
	| .issue
' "$PLAN")
if [ -z "$_asym" ]; then
	pass "blocks is exactly the inverse of blocked_by across the whole graph"
else
	for _i in $_asym; do fail "#$_i: blocks does not match the inverse of blocked_by"; done
fi

# --- 7. no dependency cycle (Kahn peel; survivors are cycle members) -------
# cycle_nodes: emit the issues that cannot be topologically ordered.
CYCLE_JQ='
def cycle_nodes:
  { rem: . }
  | until(
      (.rem | length) == 0
      or ([.rem | to_entries[] | select(.value | length == 0)] | length) == 0;
      ([.rem | to_entries[] | select(.value | length == 0) | .key]) as $ready
      | .rem |= ( with_entries(select(.key as $k | ($ready | index($k)) | not))
                  | map_values(. - $ready) )
    )
  | .rem | keys;
'
_cycles=$(jq -r "$CYCLE_JQ"'
	(reduce .issues[] as $r ({}; .[$r.issue|tostring] = ($r.blocked_by | map(tostring))))
	| cycle_nodes | .[]
' "$PLAN")
if [ -z "$_cycles" ]; then
	pass "dependency graph is acyclic"
else
	fail "dependency cycle involves: $(echo "$_cycles" | tr '\n' ' ')"
fi

# The cycle detector is itself load-bearing, so prove it detects one. A guard
# that has never rejected anything is indistinguishable from a guard that
# always passes.
printf '{"issues":[{"issue":1,"blocked_by":[2]},{"issue":2,"blocked_by":[1]},{"issue":3,"blocked_by":[]}]}\n' > "$TMP/cyclic.json"
_probe=$(jq -r "$CYCLE_JQ"'
	(reduce .issues[] as $r ({}; .[$r.issue|tostring] = ($r.blocked_by | map(tostring))))
	| cycle_nodes | length
' "$TMP/cyclic.json")
if [ "$_probe" = "2" ]; then
	pass "cycle detector rejects a known 2-node cycle (self-check)"
else
	fail "cycle detector reported $_probe cycle members on a known 2-node cycle — the acyclicity result above cannot be trusted"
fi

# --- 8. status agrees with the dependency graph ---------------------------
_bad_status=$(jq -r '
	.issues[] | select((.blocked_by | length) > 0 and .status == "ready") | .issue
' "$PLAN")
if [ -z "$_bad_status" ]; then
	pass "no issue is marked ready while it still declares a blocker"
else
	for _i in $_bad_status; do fail "#$_i is status:ready but declares blocked_by"; done
fi

# --- 9. milestones resolve to epics that are themselves planned ------------
_ms_bad=$(jq -r '
	[.issues[].issue] as $known
	| .milestones[]
	| select((.epic as $e | $known | index($e) | not) or (.title // "") == "")
	| .key
' "$PLAN")
if [ -z "$_ms_bad" ]; then
	pass "every milestone declares a title and an epic present in the plan"
else
	for _m in $_ms_bad; do fail "milestone $_m has no title or an unplanned epic"; done
fi

# Every non-epic record must hang off a parent epic — "a milestone" is not a
# tracking surface a person can subscribe to or check off.
_orphans=$(jq -r '.issues[] | select(.type != "epic" and .parent_epic == null) | .issue' "$PLAN")
if [ -z "$_orphans" ]; then
	pass "every non-epic issue declares a parent epic"
else
	for _i in $_orphans; do fail "#$_i has no parent_epic"; done
fi

# --- 10. live reconciliation against the real backlog ----------------------
# Structural validity is not freshness. An issue closed last week still
# validates perfectly as "ready" work.
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	REPO=${SENTINEL_PLAN_REPO:-bogdaniel/sentinel-shield}
	if gh issue list -R "$REPO" --state open --limit 1000 --json number -q '.[].number' \
		2>/dev/null | sort -n > "$TMP/live"; then
		jq -r '.issues[].issue' "$PLAN" | sort -n > "$TMP/planned"
		if [ ! -s "$TMP/live" ]; then
			fail "live issue query returned nothing for $REPO — treating an empty result as agreement would make this check vacuous"
		else
			_unplanned=$(comm -23 "$TMP/live" "$TMP/planned" | tr '\n' ' ')
			_stale=$(comm -13 "$TMP/live" "$TMP/planned" | tr '\n' ' ')
			[ -z "$_unplanned" ] && pass "every open issue in $REPO appears in the plan" \
				|| fail "open issue(s) missing from the plan: $_unplanned"
			# A closed issue left in the plan is the dangerous direction: it
			# presents finished or abandoned work as scheduled work.
			[ -z "$_stale" ] && pass "no closed issue appears in the plan as active work" \
				|| fail "plan lists issue(s) that are not open: $_stale"
		fi
	else
		fail "gh is authenticated but the issue query for $REPO failed — this check must not pass on an error"
	fi
else
	skip "live backlog reconciliation (no authenticated gh); structural checks above still ran"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d remediation-plan check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nremediation-plan: OK (%d records)\n' "$TOTAL"
exit 0
