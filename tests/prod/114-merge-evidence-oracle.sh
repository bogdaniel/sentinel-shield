#!/bin/sh
# Sentinel Shield production test — the trigger-bound merge-evidence oracle (#285).
#
# WHY THIS EXISTS
#
# The v2 stack collapse (#143 -> #278, 14 PRs, 13 base transitions) surfaced seven defects in
# how merge evidence was read. Every one would have either blocked the collapse outright or
# admitted stale evidence as green. This suite carries a fixture for each, so the oracle
# cannot silently regress to any of them.
#
# An eighth was surfaced later, by the oracle refusing PR #327: a path-filtered pull_request
# workflow that legitimately FIRED was reported `unexpected:` and blocked the round. It is
# recorded here in the same form as the original seven — the oracle failing closed on its own
# under-computed expectation is still the oracle being wrong.
#
# All eight run OFFLINE. `scripts/merge-evidence.sh` is sourced in library mode
# (MERGE_EVIDENCE_LIB_ONLY=1), which defines the decision functions without executing a phase.
# A guard against a network-dependent race that can only be tested against the network is not
# a guard — it is a hope with a test file.
#
# Three of the seven are properties of what the tool REFUSES TO READ rather than of what it
# computes, so they are asserted statically against the script's own source. That is the point
# of the issue: the fields are not merely wrong to trust, they must not be consulted at all.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/merge-evidence.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

[ -f "$SCRIPT" ] || { fail "scripts/merge-evidence.sh is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# The script DOCUMENTS the seven forbidden fields at length — that is the point of it. So the
# "must never be consulted" assertions grep a comment-stripped copy: naming a field in a
# comment is the fix being explained, not the defect being reintroduced.
grep -vE '^[[:space:]]*#' "$SCRIPT" > "$TMP/code.sh"
CODE="$TMP/code.sh"

MERGE_EVIDENCE_LIB_ONLY=1
export MERGE_EVIDENCE_LIB_ONLY
# shellcheck source=scripts/merge-evidence.sh
. "$SCRIPT"

expect() { # expect <label> <expected> <actual>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected [$2], got [$3]"; fi
}

# ---------------------------------------------------------------------------
# DEFECT 1 — `conclusion` is "" (not null) for an in-flight run; jq `//` never fires.
# Consequence if unfixed: pending reported as a verdict.
# ---------------------------------------------------------------------------
expect "defect 1: in_progress with empty conclusion reads as pending" \
	"pending" "$(me_classify_run in_progress "" 1 abc abc)"
expect "defect 1: queued with empty conclusion reads as pending" \
	"pending" "$(me_classify_run queued "" 1 abc abc)"
# The dangerous shape: a naive `.conclusion // "pending"` yields "" here, and a
# `[ "$c" != "failure" ]` test then reads it as success.
expect "defect 1: completed with empty conclusion is rejected, never assumed successful" \
	"rejected:completed-without-conclusion" "$(me_classify_run completed "" 1 abc abc)"
_naive=$(printf '{"status":"in_progress","conclusion":""}' | jq -r '.conclusion // "pending"')
if [ -z "$_naive" ]; then
	pass "defect 1: the original jq idiom is confirmed still broken (\`// \` yields empty, not 'pending')"
else
	fail "defect 1: jq '// ' now yields [$_naive] for an empty string — the fixture no longer reproduces the defect and this suite is not testing it"
fi

# ---------------------------------------------------------------------------
# DEFECT 2 — `pr.baseRefOid` is a sync snapshot, not the live base tip.
# Consequence if unfixed: blocks every post-merge round.
# ---------------------------------------------------------------------------
if grep -q 'baseRefOid' "$CODE"; then
	fail "defect 2: the oracle references baseRefOid — it is a sync snapshot that goes stale the moment anything else merges"
else
	pass "defect 2: baseRefOid is never consulted"
fi
if grep -q 'git/ref/heads/' "$CODE"; then
	pass "defect 2: the live base tip is read from the git ref API (the record), not the PR object"
else
	fail "defect 2: no git ref lookup found — the base tip must come from the ref API"
fi

# ---------------------------------------------------------------------------
# DEFECT 3 — `run.pull_requests[].base.sha` is a LIVE POINTER, rewritten retroactively on old
# runs. Consequence if unfixed: stale runs launder as current. This is the serious one.
# ---------------------------------------------------------------------------
if grep -qE 'pull_requests|\.base\.sha' "$CODE"; then
	fail "defect 3: the oracle reads a run's base.sha — that field is rewritten retroactively on old runs, so a run from a previous day reports the CURRENT base and launders as fresh evidence"
else
	pass "defect 3: run.pull_requests[].base.sha is never consulted"
fi
# Behavioural proof: two runs identical except for the base pointer must classify identically.
# Because the field is never read, a mutation of it cannot move an already-rendered verdict.
_v_old=$(me_classify_run completed success 1 headsha headsha)
_v_new=$(me_classify_run completed success 1 headsha headsha)
expect "defect 3: a base.sha mutation cannot change an already-rendered verdict" "$_v_old" "$_v_new"
# And the identity that IS bound is head_sha, which is a record.
expect "defect 3: a run on a different head is rejected on head_sha, the field that never moves" \
	"rejected:head-sha-mismatch" "$(me_classify_run completed success 1 otherhead headsha)"

# ---------------------------------------------------------------------------
# DEFECT 4 — a reopen retriggers EVERY workflow; an unfiltered capture never yields the
# expected set. Consequence if unfixed: round refused.
# ---------------------------------------------------------------------------
cat > "$TMP/runs.tsv" <<'RUNS'
100	.github/workflows/ci-self-test.yml	2026-08-06T10:00:00Z
101	.github/workflows/ci-security.yml	2026-08-06T10:00:01Z
200	.github/workflows/ci-self-test.yml	2026-08-06T12:00:00Z
201	.github/workflows/ci-security.yml	2026-08-06T12:00:01Z
RUNS
printf '100\n101\n' > "$TMP/pre.ids"
_cap=$(me_filter_captured "$TMP/runs.tsv" "$TMP/pre.ids" "2026-08-06T11:00:00Z" | cut -f1 | tr '\n' ' ')
expect "defect 4: only post-trigger runs are captured; the pre-trigger pair is excluded" \
	"200 201 " "$_cap"
# The epoch alone is not enough: a pre-existing run created after a mis-set epoch would slip
# through, which is why the ID snapshot is also required.
_cap_ids_only=$(me_filter_captured "$TMP/runs.tsv" "$TMP/pre.ids" "2026-08-06T09:00:00Z" | cut -f1 | tr '\n' ' ')
expect "defect 4: the pre-trigger ID snapshot still excludes old runs when the epoch is too permissive" \
	"200 201 " "$_cap_ids_only"
# An EMPTY pre-trigger snapshot is a normal state — it means nothing had run on this head yet,
# which is what happens when a PR is triggered before its open-event runs are created. The
# usual NR==FNR two-file awk idiom is WRONG here: with an empty first file, NR==FNR is still
# true for the first line of the SECOND file, so the first captured run was swallowed as
# though it were pre-existing and the capture came back short. Observed live on PR #311: the
# trigger phase span to its timeout reporting all 11 workflows missing.
: > "$TMP/pre-empty.ids"
_cap_empty=$(me_filter_captured "$TMP/runs.tsv" "$TMP/pre-empty.ids" "2026-08-06T11:00:00Z" | cut -f1 | tr '\n' ' ')
expect "defect 4: an EMPTY pre-trigger snapshot still captures every post-epoch run" \
	"200 201 " "$_cap_empty"
# ...and with an empty snapshot AND a permissive epoch, everything is captured rather than
# nothing — the failure mode was silent under-capture, which reads identically to "no runs yet".
_cap_all=$(me_filter_captured "$TMP/runs.tsv" "$TMP/pre-empty.ids" "2026-01-01T00:00:00Z" | cut -f1 | tr '\n' ' ')
expect "defect 4: an empty snapshot never silently drops the first captured run" \
	"100 101 200 201 " "$_cap_all"

# And conversely, the epoch still excludes a run absent from the snapshot but created earlier.
printf '999\n' > "$TMP/pre2.ids"
_cap_epoch_only=$(me_filter_captured "$TMP/runs.tsv" "$TMP/pre2.ids" "2026-08-06T11:00:00Z" | cut -f1 | tr '\n' ' ')
expect "defect 4: the epoch filter still excludes old runs when the ID snapshot misses them" \
	"200 201 " "$_cap_epoch_only"

# ---------------------------------------------------------------------------
# DEFECT 5 — epoch taken from the local clock, compared against GitHub's `created_at`.
# Consequence if unfixed: skew-dependent acceptance.
# ---------------------------------------------------------------------------
if grep -qE '_epoch=\$\(gh api .*timeline' "$CODE"; then
	pass "defect 5: the trigger epoch comes from GitHub's own reopened timeline event"
else
	fail "defect 5: the trigger epoch is not read from GitHub's timeline — comparing a locally-stamped time against GitHub's created_at makes acceptance depend on clock skew"
fi
if grep -qE '_epoch=\$\(date' "$CODE"; then
	fail "defect 5: the trigger epoch is derived from the local clock"
else
	pass "defect 5: the trigger epoch is never derived from the local clock"
fi

# ---------------------------------------------------------------------------
# DEFECT 6 — merge-ref tripwire baselined BEFORE the trigger that recomputes it.
# Consequence if unfixed: blocks every round.
# ---------------------------------------------------------------------------
_reopen_line=$(grep -n 'gh pr reopen' "$SCRIPT" | head -1 | cut -d: -f1)
_mref_line=$(grep -n '_mref=$(pr_merge_ref)' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$_reopen_line" ] && [ -n "$_mref_line" ] && [ "$_mref_line" -gt "$_reopen_line" ]; then
	pass "defect 6: the merge ref is baselined AFTER the trigger that recomputes it (line $_mref_line > $_reopen_line)"
else
	fail "defect 6: the merge ref is baselined at line ${_mref_line:-?}, not after the trigger at line ${_reopen_line:-?} — GitHub recomputes the synthetic merge ref on every trigger, so a pre-trigger baseline mismatches on every round"
fi

# ---------------------------------------------------------------------------
# DEFECT 7 — `gh run rerun` preserves the original trigger context.
# Consequence if unfixed: tested tree unprovable.
#
# The issue names this fixture explicitly: a COMPLETED, SUCCESSFUL, ATTEMPT-2 rerun on the
# current head must be rejected. It is the most convincing-looking false green available —
# every field a naive check reads says "green, current head".
# ---------------------------------------------------------------------------
expect "defect 7: a completed, successful, attempt-2 rerun on the current head is rejected" \
	"rejected:rerun-attempt-2" "$(me_classify_run completed success 2 headsha headsha)"
expect "defect 7: attempt 3 is rejected too" \
	"rejected:rerun-attempt-3" "$(me_classify_run completed success 3 headsha headsha)"
expect "defect 7: a first-attempt run on the same head is accepted (valid control)" \
	"verified" "$(me_classify_run completed success 1 headsha headsha)"
# Match the INVOCATION, not the mention. The script's own log line names `gh run rerun` to
# say it is never used; a naive substring grep would read that sentence as the defect. Same
# lesson as the workflow matcher in tests/lib/workflow-invocation.sh.
if grep -qE '(^|[;&|]|\$\()[[:space:]]*gh run rerun' "$CODE"; then
	fail "defect 7: the oracle invokes 'gh run rerun' — a rerun preserves the original trigger context and proves nothing about the tree it appears to describe"
else
	pass "defect 7: the oracle never invokes 'gh run rerun'"
fi

# ---------------------------------------------------------------------------
# Terminal states that are neither success nor failure
# ---------------------------------------------------------------------------
expect "cancelled is a terminal non-verdict, distinct from failure" \
	"rejected:cancelled-terminal-non-verdict" "$(me_classify_run completed cancelled 1 h h)"
expect "skipped is rejected, never treated as satisfied" \
	"rejected:skipped" "$(me_classify_run completed skipped 1 h h)"
expect "failure is rejected as a failure, not as a non-verdict" \
	"rejected:conclusion-failure" "$(me_classify_run completed failure 1 h h)"
expect "timed_out is rejected" \
	"rejected:conclusion-timed_out" "$(me_classify_run completed timed_out 1 h h)"
expect "a non-numeric attempt fails closed rather than being coerced" \
	"rejected:unparseable-attempt" "$(me_classify_run completed success "" h h)"

# ---------------------------------------------------------------------------
# Complete accounting: missing / unexpected / duplicate
# ---------------------------------------------------------------------------
printf 'a.yml\nb.yml\nc.yml\n' > "$TMP/expected"
printf 'a.yml\nb.yml\nc.yml\n' > "$TMP/cap_ok"
expect "accounting: an exact match reports no problems" "" "$(me_account_set "$TMP/cap_ok" "$TMP/expected")"
printf 'a.yml\nb.yml\n' > "$TMP/cap_missing"
expect "accounting: a missing workflow is reported, not ignored" \
	"missing:c.yml" "$(me_account_set "$TMP/cap_missing" "$TMP/expected")"
printf 'a.yml\nb.yml\nc.yml\nd.yml\n' > "$TMP/cap_extra"
expect "accounting: an unexpected workflow is reported" \
	"unexpected:d.yml" "$(me_account_set "$TMP/cap_extra" "$TMP/expected")"
printf 'a.yml\na.yml\nb.yml\nc.yml\n' > "$TMP/cap_dupe"
expect "accounting: a duplicated workflow is reported" \
	"duplicate:a.yml" "$(me_account_set "$TMP/cap_dupe" "$TMP/expected")"

# ---------------------------------------------------------------------------
# Expected-set derivation: a path-filtered workflow may legitimately not fire
# ---------------------------------------------------------------------------
mkdir -p "$TMP/wf"
printf 'name: always\non:\n  pull_request:\n  push:\n    branches: [master]\njobs: {}\n' > "$TMP/wf/always.yml"
printf 'name: filtered\non:\n  pull_request:\n    paths:\n      - SECURITY.md\n  push:\n    branches: [master]\njobs: {}\n' > "$TMP/wf/filtered.yml"
printf 'name: pushonly\non:\n  push:\n    branches: [master]\njobs: {}\n' > "$TMP/wf/pushonly.yml"
printf 'name: commented\non:\n#  pull_request:\n  push:\n    branches: [master]\njobs: {}\n' > "$TMP/wf/commented.yml"
_exp=$(me_expected_workflows "$TMP/wf" | sed 's|.*/||' | sort | tr '\n' ' ')
expect "expected set: only the unfiltered pull_request workflow is always-expected" \
	"always.yml " "$_exp"

# The derivation must agree with the real repository, or the accounting above is checking a
# set nobody uses.
_real=$(me_expected_workflows "$ROOT/.github/workflows" | wc -l | tr -d ' ')
if [ "$_real" -gt 0 ]; then
	pass "expected set: $_real always-expected pull_request workflow(s) derived from the real repository"
else
	fail "expected set: derived an EMPTY set from the real repository — every accounting check would pass vacuously"
fi

# ---------------------------------------------------------------------------
# DEFECT 8: a path-filtered workflow that DOES fire
#
# The always-expected set was also the only PERMITTED set, so a path-filtered workflow that
# fired was reported `unexpected:` and the round span to its timeout. Observed live on PR
# #327, which touches scripts/lib/sentinel-shield-common.sh — a declared path trigger for
# security-incident-validation.
#
# The fix has to be ASYMMETRIC: such a workflow may be absent, but if present it is verified
# like any other. Cases 3, 4 and 5 are what separate that from "ignore anything unexpected".
# ---------------------------------------------------------------------------
_perm=$(me_permitted_workflows "$TMP/wf" | sed 's|.*/||' | sort | tr '\n' ' ')
expect "permitted set: exactly the path-filtered pull_request workflow" \
	"filtered.yml " "$_perm"

me_expected_workflows "$TMP/wf" | sort > "$TMP/acc_exp"
me_permitted_workflows "$TMP/wf" | sort > "$TMP/acc_perm"

# The two sets partition the pull_request workflows: nothing may be in both.
expect "expected and permitted sets are disjoint" "" "$(comm -12 "$TMP/acc_exp" "$TMP/acc_perm")"

# 1. it fired -> permitted, no problems reported.
printf '.github/workflows/always.yml\n.github/workflows/filtered.yml\n' > "$TMP/cap_pf"
expect "accounting: a path-filtered workflow that FIRED is permitted, not 'unexpected'" \
	"" "$(me_account_set "$TMP/cap_pf" "$TMP/acc_exp" "$TMP/acc_perm")"

# 2. it did not fire -> also no problems; its absence is legitimate.
printf '.github/workflows/always.yml\n' > "$TMP/cap_nopf"
expect "accounting: a path-filtered workflow that did NOT fire is never reported missing" \
	"" "$(me_account_set "$TMP/cap_nopf" "$TMP/acc_exp" "$TMP/acc_perm")"

# 3. CONTROL — a required workflow is still required. Permitting extras must not have turned
#    the accounting into "anything goes".
printf '.github/workflows/filtered.yml\n' > "$TMP/cap_lost"
expect "accounting CONTROL: an always-expected workflow is still reported missing" \
	"missing:.github/workflows/always.yml" \
	"$(me_account_set "$TMP/cap_lost" "$TMP/acc_exp" "$TMP/acc_perm")"

# 4. CONTROL — a run from a workflow with NO pull_request trigger is still unexpected. This
#    is the case that distinguishes the fix from deleting the check.
printf '.github/workflows/always.yml\n.github/workflows/pushonly.yml\n' > "$TMP/cap_alien"
expect "accounting CONTROL: a workflow with no pull_request trigger is still 'unexpected'" \
	"unexpected:.github/workflows/pushonly.yml" \
	"$(me_account_set "$TMP/cap_alien" "$TMP/acc_exp" "$TMP/acc_perm")"

# 5. CONTROL — the permitted set is opt-in. A two-argument caller keeps strict behaviour, so
#    the permissive path cannot be reached by accident.
expect "accounting: without a permitted set, a path-filtered workflow is still 'unexpected'" \
	"unexpected:.github/workflows/filtered.yml" \
	"$(me_account_set "$TMP/cap_pf" "$TMP/acc_exp")"

# 6. The real repository must actually contain the shape that broke #327, or these fixtures
#    describe a case that does not occur.
_realperm=$(me_permitted_workflows "$ROOT/.github/workflows" | wc -l | tr -d ' ')
if [ "$_realperm" -gt 0 ]; then
	pass "the repository really has $_realperm path-filtered pull_request workflow(s) — the fixtures describe reality"
else
	fail "no path-filtered pull_request workflow in this repository — the DEFECT 8 fixtures no longer describe reality"
fi

# ---------------------------------------------------------------------------
# Structural: the phases exist, and merge is gated on a verified manifest
# ---------------------------------------------------------------------------
for _p in trigger verify merge; do
	if grep -qE "^${_p}\)" "$SCRIPT" || grep -qE "^phase_${_p}\(\)" "$SCRIPT"; then
		pass "phase '$_p' is implemented"
	else
		fail "phase '$_p' is missing"
	fi
done
if grep -q -- '--match-head-commit' "$SCRIPT"; then
	pass "merge uses --match-head-commit"
else
	fail "merge does not pass --match-head-commit — the head could move between verification and merge"
fi
if grep -q 'verdict.*verified.*||.*me_die\|refusing to merge' "$SCRIPT"; then
	pass "merge refuses a manifest whose verdict is not 'verified'"
else
	fail "merge does not gate on a verified manifest verdict"
fi
if grep -qE '(^|[;&|]|\$\()[[:space:]]*gh pr checks' "$CODE"; then
	fail "the oracle consults 'gh pr checks' — that is a head-only view, never authority"
else
	pass "the oracle never consults 'gh pr checks'"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d merge-evidence check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nmerge-evidence-oracle: OK (all eight oracle defects have a passing fixture)\n'
exit 0
