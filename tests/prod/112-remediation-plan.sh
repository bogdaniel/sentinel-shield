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
# Overridable so the empty-plan end state can be exercised by a regression without mutating
# the real plan. Defaults to the shipped file, which is what every ordinary invocation uses.
PLAN="${SENTINEL_PLAN_FILE:-$ROOT/config/remediation-plan.json}"
# The declared label-to-plan mapping. Overridable for the same reason PLAN is: the fixtures
# below exercise broken mappings without touching the shipped one.
SEMANTICS="${SENTINEL_SEMANTICS_FILE:-$ROOT/config/backlog-semantics.json}"

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

# `.issues` must be an ARRAY. Its length is not the test.
#
# This guard used to be `[ "$TOTAL" -gt 0 ] || fail "plan contains no issue records"`, which is
# the same defect as the two above it and the one in ci-backlog-reconciliation: it conflates
# "the file is truncated or malformed" with "the programme finished". A plan with zero records
# is the SUCCESS state of this entire effort, and the check that is supposed to prove the plan
# agrees with reality would have been the last thing to refuse it.
#
# A missing or non-array `.issues` is still fatal — that is the corruption this was guarding
# against, and jq can tell the two apart.
jq -e '(.issues | type) == "array"' "$PLAN" >/dev/null 2>&1 \
	|| { fail "plan has no .issues array — the file is malformed, not merely empty"; exit 1; }
TOTAL=$(jq '.issues | length' "$PLAN")
[ "$TOTAL" -gt 0 ] || pass "plan is empty and well-formed — every issue is closed, which is a valid end state"
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
	# The query is run WITHOUT `-q`, so its success is judged on the exit status and on the
	# response being a JSON array — not on the response being non-empty.
	#
	# This guard used to read `[ ! -s "$TMP/live" ] && fail "... an empty result ... would make
	# this check vacuous"`. The fear was right — a silently-failed query must never read as
	# agreement — but the test was wrong: it also fails a repository whose backlog is
	# LEGITIMATELY EMPTY, which is the state this programme is working toward. An empty backlog
	# with an empty plan is perfect agreement, and the comm comparison below already says so.
	#
	# Failure and emptiness are separated instead: a failed call cannot produce an array, and
	# an array of length zero is a valid answer.
	if _live_json=$(gh issue list -R "$REPO" --state open --limit 1000 --json number,state,labels,milestone 2>/dev/null) \
		&& printf '%s' "$_live_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
		printf '%s' "$_live_json" | jq -r '.[].number' | sort -n > "$TMP/live"
		jq -r '.issues[].issue' "$PLAN" | sort -n > "$TMP/planned"
		_unplanned=$(comm -23 "$TMP/live" "$TMP/planned" | tr '\n' ' ')
		_stale=$(comm -13 "$TMP/live" "$TMP/planned" | tr '\n' ' ')
		[ -z "$_unplanned" ] && pass "every open issue in $REPO appears in the plan" \
			|| fail "open issue(s) missing from the plan: $_unplanned"
		# A closed issue left in the plan is the dangerous direction: it
		# presents finished or abandoned work as scheduled work.
		[ -z "$_stale" ] && pass "no closed issue appears in the plan as active work" \
			|| fail "plan lists issue(s) that are not open: $_stale"
		if [ ! -s "$TMP/live" ] && [ ! -s "$TMP/planned" ]; then
			pass "live backlog and plan are both empty — a valid state, not a vacuous check"
		fi

		# --- 10b. SEMANTIC reconciliation ------------------------------------------------
		# Membership agreement is not semantic agreement. The two checks above hold whenever
		# the same issue NUMBERS appear on both sides; they say nothing about whether an
		# issue's status, priority, type, domain or milestone still matches the plan. That is
		# how this lane stayed green while #345 was status:partial live and `ready` in the
		# plan. The comparison itself lives in scripts/reconcile-backlog.sh and its rules in
		# config/backlog-semantics.json — one implementation, read by the suite and by any
		# future report rather than reimplemented per caller.
		printf '%s' "$_live_json" > "$TMP/live-full.json"
		if sh "$ROOT/scripts/reconcile-backlog.sh" --plan "$PLAN" --live "$TMP/live-full.json" \
			--semantics "$SEMANTICS" > "$TMP/sem.out" 2>&1; then
			_semlines=$(grep -c . "$TMP/sem.out" || true)
			pass "live backlog and plan agree on every normative field ($_semlines line(s) reported)"
		else
			while IFS= read -r _l; do fail "semantic reconciliation: $_l"; done < "$TMP/sem.out"
			[ -s "$TMP/sem.out" ] || fail "semantic reconciliation failed without reporting a reason"
		fi
	else
		fail "gh is authenticated but the issue query for $REPO did not return a JSON array — this check must not pass on an error"
	fi
elif [ "${SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG:-0}" = "1" ]; then
	# The governance path. `ci-backlog-reconciliation` sets this, so an unauthenticated run
	# there is a FAILURE rather than a skip.
	#
	# Why this flag exists: the skip below is correct for a developer laptop and for the general
	# production sweep, which deliberately carries no `issues: read` scope. But it means plan
	# drift is invisible to any CI that runs this suite unauthenticated — and drift reached
	# master green exactly that way twice (#310 left in the plan after it closed, and the same
	# class before it). A check that reports SKIP under the one condition that matters is not a
	# check; the fix is a workflow that supplies the credential and refuses to proceed without.
	fail "SENTINEL_SHIELD_REQUIRE_LIVE_BACKLOG=1 but gh is not authenticated — the governance check must not pass structurally while the half that detects drift did not run"
else
	skip "live backlog reconciliation (no authenticated gh); structural checks above still ran"
fi

# --- 11. the declared mapping itself ---------------------------------------
# The mapping is what decides what agreement MEANS, so it is validated before anything is
# judged against it. A mapping with a missing key would otherwise make every comparison below
# silently permissive.
if jq -e '(.schema | startswith("sentinel-shield/backlog-semantics@"))
	and ((.field_mapping | type) == "array") and ((.field_mapping | length) > 0)
	and ((.status_labels | type) == "object") and ((.status_labels | length) > 0)
	and ((.reconciliation_debt.entries | type) == "array")
	and ((.reconciliation_debt.classes | type) == "object")' "$SEMANTICS" >/dev/null 2>&1; then
	pass "backlog-semantics declares a schema, a field mapping, a status vocabulary and a debt list"
else
	fail "backlog-semantics is missing a required section — the comparison would be permissive"
fi

# Every status value the PLAN uses must be reachable from some label, or the plan can hold a
# status no live issue could ever agree with.
_unreachable=""
for _ps in $(jq -r '[.issues[].status] | unique | .[]' "$PLAN"); do
	jq -e --arg s "$_ps" '[.status_labels | to_entries[] | select(.value.plan_status == $s)] | length > 0' \
		"$SEMANTICS" >/dev/null 2>&1 || _unreachable="$_unreachable $_ps"
done
[ -z "$_unreachable" ] \
	&& pass "every plan status is reachable from a declared status label" \
	|| fail "plan status(es) no label can produce:$_unreachable"

# Every status label the repository defines must be declared here — mapped, or explicitly
# invalid for open planned work. An undeclared label is the "unknown status" case, and it must
# be a decision rather than an omission.
[ "$(jq -r '[.status_labels | to_entries[] | select((.value.plan_status == null) and (.value.valid_for_open_planned_work != false))] | length' "$SEMANTICS")" = "0" ] \
	&& pass "no status label maps to nothing while still being accepted for open work" \
	|| fail "a status label maps to no plan status yet is accepted for open planned work"

# Each debt entry's reason must name a declared class carrying a resolution. A debt with no
# stated way out is a permanent exemption wearing a different word.
[ "$(jq -r '[.reconciliation_debt.classes | to_entries[] | select((.value.resolution // "") == "")] | length' "$SEMANTICS")" = "0" ] \
	&& pass "every declared debt class states how it is resolved" \
	|| fail "a debt class states no resolution"

# Every shipped entry must satisfy the contract, including the fields that make it actionable and
# time-bounded. An entry with no owner or no review boundary is a permanent allowlist entry.
_required='issue field plan_value live_value reason owner remediation created review_by source'
_contract_bad=""
for _rf in $_required; do
	[ "$(jq -r --arg f "$_rf" '[.reconciliation_debt.entries[] | select(has($f) | not)] | length' "$SEMANTICS")" = "0" ] \
		|| _contract_bad="$_contract_bad $_rf"
done
[ -z "$_contract_bad" ] \
	&& pass "every shipped debt entry carries the full contract (owner, remediation, created, review_by, source)" \
	|| fail "shipped debt entries missing required field(s):$_contract_bad"
[ "$(jq -r '[.reconciliation_debt.entries[] | select((.review_by // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)] | length' "$SEMANTICS")" = "0" ] \
	&& pass "every shipped debt entry states a dated review boundary" \
	|| fail "a shipped debt entry has no parseable review boundary — it would never expire"
_emptycls=""
for _c in $(jq -r '.reconciliation_debt.classes | keys[]' "$SEMANTICS"); do
	_n=$(jq -r --arg c "$_c" '[.reconciliation_debt.entries[] | select(.reason == $c)] | length' "$SEMANTICS")
	[ "$_n" -gt 0 ] || _emptycls="$_emptycls $_c"
done
[ -z "$_emptycls" ] \
	&& pass "every declared debt class still has entries — a discharged class is removed, not kept" \
	|| fail "declared debt class(es) with no entries:$_emptycls"

_dupkeys=$(jq -r '[.reconciliation_debt.entries[] | "\(.issue)/\(.field)"] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$SEMANTICS")
[ -z "$_dupkeys" ] \
	&& pass "debt entries are uniquely keyed by (issue, field)" \
	|| fail "duplicate debt key(s): $_dupkeys"

# --- 12. the reconciler, proven against fixtures ---------------------------
# Every rule the live half depends on is proven here, offline, against a snapshot in exactly
# the shape `gh issue list --json number,state,labels,milestone` returns. A rule that only
# ever runs against the real backlog is a rule nobody has seen fail.
RECON="$ROOT/scripts/reconcile-backlog.sh"
SFIX="$ROOT/tests/fixtures/backlog-semantics"
_rec() { # _rec <live-fixture> [semantics-fixture] [plan-fixture] [as-of] -> reconciler exit status
	sh "$RECON" --plan "$SFIX/${3:-plan.json}" --live "$SFIX/$1" \
		--semantics "$SFIX/${2:-semantics.json}" --as-of "${4:-2026-08-17}" >/dev/null 2>&1
}
if [ -x "$RECON" ] || [ -f "$RECON" ]; then
	_rec good-all-agree.json \
		&& pass "reconciler CONTROL: a fully agreeing backlog is accepted" \
		|| fail "reconciler CONTROL: an agreeing backlog was rejected — every rejection below proves nothing"
	_rec good-9-non-normative-differs.json \
		&& pass "reconciler CONTROL: a rewritten title and an extra non-normative label are ignored" \
		|| fail "reconciler CONTROL: a non-normative difference was treated as drift"
	# The nine required negatives, each its own fixture so a rejection is attributable.
	_recf() { # _recf <fixture> <description> [semantics] [plan]
		_rec "$1" "${3:-}" "${4:-}" && fail "reconciler: $2 was accepted" || pass "reconciler: $2 is rejected"
	}
	_recf bad-1-plan-ready-live-partial.json "plan ready against live partial"
	_recf bad-2-plan-partial-live-ready.json "plan partial against live ready"
	_recf bad-3-no-status-label.json "an issue with no status label"
	_recf bad-4-two-status-labels.json "an issue with two status labels"
	_recf bad-5-unknown-status-label.json "an undeclared status label"
	_recf bad-6-membership-agrees-status-differs.json "membership agreeing while status differs"
	_recf bad-7-priority-differs.json "a priority that differs from the plan"
	_recf bad-8-type-differs.json "a type that differs from the plan"
	_recf bad-domain-differs.json "an area label that differs from primary_domain"
	_recf bad-milestone-differs.json "a milestone that differs from the plan"
	_recf bad-milestone-unassigned.json "a planned issue with no milestone"
	_recf bad-status-verified-on-open.json "status:verified on an open planned issue"
	_recf bad-duplicate-in-snapshot.json "the same issue twice in one snapshot"
	_recf bad-missing-from-live.json "a planned issue absent from the live snapshot"
	# THE THREE EMPTINESS CASES, separated. Only one of them is vacuity, and the wrong guard here
	# breaks the finished state this programme is working toward — tests/prod/110 runs this suite
	# against an empty plan with a stubbed `gh` for exactly that reason.
	_recf bad-empty-live.json "a non-empty plan beside an empty backlog (one membership violation per planned issue)"
	_recf good-all-agree.json "an EMPTY PLAN beside open live work — nothing would be compared at all" semantics.json plan-empty.json
	_rec good-empty-live.json semantics.json plan-empty.json \
		&& pass "reconciler: both sides empty is the FINISHED state and is accepted, not vacuity" \
		|| fail "reconciler: a completed programme fails its own reconciliation — the guard cannot be satisfied by finishing"
	# The debt list may only shrink.
	_rec bad-1-plan-ready-live-partial.json semantics-with-debt.json \
		&& pass "reconciler: a named debt entry permits exactly its recorded pair" \
		|| fail "reconciler: a named debt entry did not permit its own recorded pair"
	_recf bad-debt-stale.json "a debt entry whose issue no longer drifts" semantics-with-debt.json
	_recf bad-debt-shape-changed.json "a debt entry whose observed pair changed" semantics-with-debt.json
	_recf bad-1-plan-ready-live-partial.json "a debt entry citing an undeclared class" semantics-debt-unknown-class.json

	# --- THE DEBT CONTRACT: an exception is not an allowlist ---------------------------
	# Every entry is keyed by (issue, field) and must carry an expected plan value, an observed
	# live value, a reason naming a declared class, an owner, a remediation, a creation date, a
	# review boundary and a source reference. Each rule below turns an entry that has outlived
	# its own terms from an exception into an error.
	_rec bad-1-plan-ready-live-partial.json semantics-debt-complete.json \
		&& pass "debt CONTROL: a complete, in-date entry excuses exactly its own mismatch" \
		|| fail "debt CONTROL: a complete entry did not excuse its own mismatch — every rejection below proves nothing"
	_recf bad-1-plan-ready-live-partial.json "an entry missing a required contract field" semantics-debt-incomplete.json
	_recf bad-1-plan-ready-live-partial.json "an entry for a field that is no longer normative" semantics-debt-not-normative.json
	_recf bad-1-plan-ready-live-partial.json "an entry whose review boundary has passed" semantics-debt-expired.json
	_recf bad-1-plan-ready-live-partial.json "a declared class with no entries — a discharged category kept as a slot" semantics-debt-empty-class.json
	# The boundary is a DATE, so it is proven in both directions rather than left to the calendar.
	_rec bad-1-plan-ready-live-partial.json semantics-debt-expired.json plan.json 2026-01-01 \
		&& pass "debt: the same entry is honoured BEFORE its review boundary — expiry is a date, not a state" \
		|| fail "debt: an in-date entry was refused, so the expiry check does not depend on the date"

	# --- THE MILESTONE STALENESS CASE, mirroring #344/#345/#348 ------------------------
	# The live repair for those three had not landed when this was written, so the property is
	# proven here instead of by a one-off observation — which is the stronger form anyway: it
	# fails forever if the mechanism ever starts tolerating an obsolete exception.
	_rec bad-milestone-unassigned-issue1.json semantics-debt-milestone.json \
		&& pass "debt: a milestone entry is honoured while the milestone is genuinely unassigned" \
		|| fail "debt: an accurate milestone entry was refused"
	_recf good-all-agree.json "a milestone entry once the milestone AGREES — an obsolete exception" semantics-debt-milestone.json

	# --- 13. mutation proof of the defect this replaces --------------------
	# The original live half compared NUMBERS. Reproduced here over the drift fixture: it
	# agrees, which is precisely why the real drift went unseen. If this ever fails, the
	# membership comparison has changed shape and the claim below must be re-examined.
	jq -r '.[].number' "$SFIX/bad-1-plan-ready-live-partial.json" | sort -n > "$TMP/mut-live"
	jq -r '.issues[].issue' "$SFIX/plan.json" | sort -n > "$TMP/mut-plan"
	if [ -z "$(comm -23 "$TMP/mut-live" "$TMP/mut-plan")" ] && [ -z "$(comm -13 "$TMP/mut-live" "$TMP/mut-plan")" ]; then
		pass "MUTATION: membership-only comparison ACCEPTS the ready/partial drift — the defect is reproduced"
	else
		fail "MUTATION: membership-only comparison rejected the drift fixture; it should not distinguish it, so this proof no longer demonstrates the defect"
	fi
	if _rec bad-1-plan-ready-live-partial.json; then
		fail "MUTATION: the semantic reconciler also accepts it — the repair is not in place"
	else
		pass "MUTATION: the semantic reconciler REJECTS the same input the membership check accepts"
	fi
else
	fail "scripts/reconcile-backlog.sh is missing — the semantic half of this suite cannot be proven"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d remediation-plan check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nremediation-plan: OK (%d records)\n' "$TOTAL"
exit 0
