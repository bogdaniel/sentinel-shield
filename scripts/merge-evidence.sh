#!/bin/sh
# Sentinel Shield — trigger-bound merge-evidence oracle (#285).
#
# THE CONTRACT
#
#   CI evidence must be trigger-bound and captured by immutable run identity, while all
#   repository inputs remain frozen.
#
# Run ID and `created_at` do NOT independently prove which tree a run built. They are the
# immutable anchors that — combined with a controlled trigger boundary and frozen master /
# head / merge-ref state — make the proof defensible. Neither half is sufficient alone.
#
# WHY THIS EXISTS
#
# The v2 stack collapse (#143 -> #278, 14 PRs, 13 base transitions) surfaced seven defects in
# the merge oracle. Every one would have either blocked the collapse outright or admitted
# stale evidence as green:
#
#   1. `gh` returns `conclusion` as "" (not null) for in-flight runs; jq `//` never fires
#      -> pending reported as a verdict.
#   2. `pr.baseRefOid` is a sync snapshot, not the live base tip -> blocks every post-merge
#      round.
#   3. `run.pull_requests[].base.sha` is a LIVE POINTER, rewritten retroactively on old runs
#      -> stale runs launder as current. This is the serious one: after #143 merged and #191
#      was closed/reopened, #191's runs from the previous day — never re-executed — began
#      reporting the NEW base, while an untouched control PR still reported the old one.
#   4. A reopen retriggers every workflow; an unfiltered capture never yields the expected
#      pair -> round refused.
#   5. Epoch taken from the local clock and compared against GitHub's `created_at`
#      -> skew-dependent acceptance.
#   6. Merge-ref tripwire baselined BEFORE the trigger that recomputes it -> blocks every
#      round.
#   7. `gh run rerun` preserves the original trigger context -> tested tree unprovable.
#
# The through-line: every field reachable as "evidence" turned out to be a LIVE VIEW rather
# than a RECORD. Only run ID and `created_at` never moved. So this tool reads run identity and
# nothing else about a run's relationship to a base — `pull_requests[].base.sha` is never
# consulted, and tests/prod/114 asserts that it is not.
#
# PHASES
#   trigger  freeze inputs, snapshot pre-trigger run IDs, close/reopen, capture exactly the
#            expected blocking run IDs, baseline the merge ref AFTER the trigger recomputes it
#   verify   poll ONLY the captured immutable run IDs and render a complete accounting
#   merge    re-prove every frozen input, then merge with --match-head-commit
#
# Usage:
#   merge-evidence.sh trigger --pr N [--repo owner/name] [--manifest PATH] [--timeout SECONDS]
#   merge-evidence.sh verify  --pr N [--repo owner/name] [--manifest PATH] [--timeout SECONDS]
#   merge-evidence.sh merge   --pr N [--repo owner/name] [--manifest PATH] [--method squash]
#
# Requires: gh (authenticated), jq, git. Exit 0 = phase succeeded. Non-zero = fail-closed.
#
# LIBRARY MODE: set MERGE_EVIDENCE_LIB_ONLY=1 to define the decision functions without
# executing a phase. tests/prod/114-merge-evidence-oracle.sh uses this to drive every defect
# fixture offline — the classification logic must be provable without a network.
set -eu

# SCRIPT_DIR/ROOT are deliberately NOT set here. In library mode this file is sourced, where
# `$0` is the CALLER's path — deriving ROOT from it would silently point at the caller's
# parent directory and clobber the caller's own ROOT. They are set below, after the library
# guard, where `$0` really is this script. No me_* function depends on them.

me_log() { printf '[merge-evidence] %s\n' "$*" >&2; }
me_die() { printf '[merge-evidence] ERROR: %s\n' "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Decision logic — pure, offline-testable. No network, no globals beyond arguments.
# ---------------------------------------------------------------------------

# me_classify_run <status> <conclusion> <attempt> <head_sha> <frozen_head>
#
# Prints exactly one verdict token:
#   pending                       still running, or GitHub has not rendered a conclusion yet
#   verified                      completed, successful, first attempt, on the frozen head
#   rejected:<reason>             everything else
#
# DEFECT 1: `conclusion` arrives as an EMPTY STRING for an in-flight run, not null. `jq`'s
# `//` operator only substitutes for null and false, so `.conclusion // "pending"` yields ""
# and a naive `[ "$c" != "failure" ]` test reads it as success. Empty is checked FIRST and
# explicitly, before anything else looks at the value.
#
# DEFECT 7: `gh run rerun` preserves the original trigger context, so a rerun proves nothing
# about the tree it appears to describe. attempt > 1 is rejected outright — a rerun is never
# evidence, however green it is.
me_classify_run() {
	_st=${1:-}
	_cn=${2:-}
	_at=${3:-}
	_hs=${4:-}
	_frozen=${5:-}

	# Defect 1: empty string is PENDING, never a verdict.
	if [ "$_st" != "completed" ]; then
		if [ -z "$_cn" ]; then
			printf 'pending\n'
			return 0
		fi
		printf 'rejected:in-flight-with-conclusion\n'
		return 0
	fi
	if [ -z "$_cn" ]; then
		# Completed with no conclusion is not a state GitHub should produce. Fail closed
		# rather than guess which way it resolves.
		printf 'rejected:completed-without-conclusion\n'
		return 0
	fi

	# Defect 7: a rerun preserves the original trigger context.
	case "$_at" in
	'' | *[!0-9]*) printf 'rejected:unparseable-attempt\n'; return 0 ;;
	esac
	if [ "$_at" -ne 1 ]; then
		printf 'rejected:rerun-attempt-%s\n' "$_at"
		return 0
	fi

	# Identity: the run must describe the frozen head. This is the ONLY tree-binding field
	# consulted, precisely because head_sha is a record and base.sha is a live pointer.
	if [ -n "$_frozen" ] && [ "$_hs" != "$_frozen" ]; then
		printf 'rejected:head-sha-mismatch\n'
		return 0
	fi

	case "$_cn" in
	success) printf 'verified\n' ;;
	# A cancelled workflow is a TERMINAL NON-VERDICT: not success, and not necessarily a
	# product failure. A timeout kill is reported as `cancelled`, which is why six
	# consecutive runs once looked like concurrency cancellation rather than a job that
	# never had long enough. It stops the round; it does not condemn the change.
	cancelled) printf 'rejected:cancelled-terminal-non-verdict\n' ;;
	skipped) printf 'rejected:skipped\n' ;;
	*) printf 'rejected:conclusion-%s\n' "$_cn" ;;
	esac
}

# me_account_set <captured-file> <expected-file>
#
# Complete accounting of captured workflow paths against the expected set. Prints one
# `missing:<path>` / `unexpected:<path>` / `duplicate:<path>` line per problem, nothing when
# the sets agree exactly. A spot check is not an accounting: a missing workflow and a passing
# one are indistinguishable unless absence is asserted.
me_account_set() {
	_cap=$1
	_exp=$2
	sort "$_exp" | uniq > "$_cap.exp.sorted"
	sort "$_cap" > "$_cap.sorted"
	sort -u "$_cap" > "$_cap.uniq"
	comm -23 "$_cap.exp.sorted" "$_cap.uniq" | sed 's/^/missing:/'
	comm -13 "$_cap.exp.sorted" "$_cap.uniq" | sed 's/^/unexpected:/'
	uniq -d "$_cap.sorted" | sed 's/^/duplicate:/'
	rm -f "$_cap.exp.sorted" "$_cap.sorted" "$_cap.uniq"
}

# me_filter_captured <runs-tsv> <pre-ids-file> <epoch>
#
# From `id<TAB>path<TAB>created_at` lines, keep only the runs this trigger produced.
#
# DEFECT 4: a reopen retriggers EVERY workflow, so the head carries both the old runs and the
# new ones. Two independent filters, both required:
#   * created_at strictly after GitHub's own trigger epoch, and
#   * not present in the pre-trigger ID snapshot.
# Either alone has failed before. The epoch alone admits a run created in the same second by
# something else; the ID snapshot alone cannot distinguish a retrigger from a run that was
# already queued when the snapshot was taken.
me_filter_captured() {
	awk -F'\t' -v e="$3" '$3 > e { print $1 "\t" $2 }' "$1" | sort -u > "$1.epoch"
	# FILENAME==ARGV[1], not the usual NR==FNR two-file idiom.
	#
	# NR==FNR identifies "still reading the first file" by NR having caught up with FNR — which
	# is also true for the FIRST LINE OF THE SECOND FILE when the first file is EMPTY. With an
	# empty pre-trigger snapshot, awk therefore swallowed the first captured run as though it
	# were a pre-existing ID, and (because that line then set pre[...] and `next`) the whole
	# capture came back short. Observed live on PR #311: the PR was triggered before its
	# open-event runs existed, so the snapshot was legitimately empty, the capture returned
	# nothing, and the trigger phase span until its timeout reporting 11 workflows missing.
	#
	# An empty snapshot is a normal state, not an error — it means nothing had run yet — so the
	# filter has to be correct for it rather than assume at least one prior run.
	awk -F'\t' 'FILENAME==ARGV[1]{pre[$0]=1;next} !($1 in pre)' "$2" "$1.epoch"
	rm -f "$1.epoch"
}

# me_expected_workflows <workflows-dir>
#
# The workflows that MUST produce a run for any pull_request: those with a `pull_request:`
# trigger and NO `paths:` filter under it. A path-filtered workflow may legitimately not fire,
# so requiring it would block every round; treating its absence as fine unconditionally would
# hide a real missing check. Splitting them is the only honest option.
#
# Emits `<repo-relative-path>` lines. Full-line comments are stripped so a commented-out
# trigger is documentation, not a registration.
me_expected_workflows() {
	_dir=$1
	for _f in "$_dir"/*.yml "$_dir"/*.yaml; do
		[ -e "$_f" ] || continue
		grep -vE '^[[:space:]]*#' "$_f" | awk -v path=".github/workflows/${_f##*/}" '
			/^on:[[:space:]]*$/ { inon = 1; next }
			inon && /^[^[:space:]]/ { inon = 0 }
			inon && /^  pull_request:[[:space:]]*$/ { inpr = 1; found = 1; next }
			inon && inpr && /^  [A-Za-z_]+:/ { inpr = 0 }
			inon && inpr && /^    paths(-ignore)?:[[:space:]]*$/ { filtered = 1 }
			END { if (found && !filtered) print path }
		'
	done
}

if [ "${MERGE_EVIDENCE_LIB_ONLY:-0}" = "1" ]; then
	# `return` succeeds when sourced; the `|| exit 0` covers a direct invocation. Written as
	# an `if` rather than `[ ] && return`, because under `set -e` a false test in a trailing
	# `&&` list exits the script — which would make library mode silently unusable.
	return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Live phases
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; }

PHASE=${1:-}
case "$PHASE" in
'') usage; exit 2 ;;
-h | --help | help) usage; exit 0 ;;
esac
shift

PR=""; REPO=""; MANIFEST=""; TIMEOUT=5400; METHOD=squash
while [ $# -gt 0 ]; do
	case "$1" in
	--pr) PR=${2:-}; shift 2 ;;
	--repo) REPO=${2:-}; shift 2 ;;
	--manifest) MANIFEST=${2:-}; shift 2 ;;
	--timeout) TIMEOUT=${2:-}; shift 2 ;;
	--method) METHOD=${2:-}; shift 2 ;;
	-h | --help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) me_die "unknown argument: $1" ;;
	esac
done

command -v gh >/dev/null 2>&1 || me_die "gh is required"
command -v jq >/dev/null 2>&1 || me_die "jq is required"
case "$PR" in '' | *[!0-9]*) me_die "--pr <number> is required" ;; esac
[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) ||
	me_die "could not resolve --repo"
[ -n "$MANIFEST" ] || MANIFEST="$ROOT/evidence/merge-oracle/pr-$PR.json"

# api_run <run-id> — the immutable record for one run, by ID. `path` and `workflow_id`
# identify the workflow; `name` is mutable configuration and is never used for identity.
api_run() { gh api "repos/$REPO/actions/runs/$1" 2>/dev/null; }

# live_base_tip — the ACTUAL current tip of the PR's base branch.
#
# DEFECT 2: `pr.baseRefOid` is a sync snapshot, not the live base tip. It goes stale the
# moment anything else merges, which blocked every post-merge round of the stack collapse.
# The ref API is the record; the PR object's copy of it is not.
live_base_tip() {
	_b=$(gh api "repos/$REPO/pulls/$PR" -q .base.ref)
	gh api "repos/$REPO/git/ref/heads/$_b" -q .object.sha
}

pr_head_sha() { gh api "repos/$REPO/pulls/$PR" -q .head.sha; }
pr_state() { gh api "repos/$REPO/pulls/$PR" -q .state; }
# GitHub recomputes the synthetic merge ref asynchronously after any trigger.
pr_merge_ref() { gh api "repos/$REPO/pulls/$PR" -q '.merge_commit_sha // ""'; }

# runs_for_head <sha> — every run for the frozen head as `id<TAB>path<TAB>created_at`.
# `--paginate` so a busy head cannot silently truncate the accounting. Identity is `path`
# (and the run id); `name` is mutable configuration and is deliberately not selected.
runs_for_head() {
	gh api "repos/$REPO/actions/runs?head_sha=$1&per_page=100" --paginate \
		-q '.workflow_runs[] | [(.id | tostring), .path, .created_at] | @tsv' 2>/dev/null
}

phase_trigger() {
	me_log "PR #$PR in $REPO — freezing inputs"
	_head=$(pr_head_sha)
	_base=$(live_base_tip)
	[ "$(pr_state)" = "open" ] || me_die "PR #$PR is not open"

	me_expected_workflows "$ROOT/.github/workflows" | sort > "$TMPD/expected"
	_exp_n=$(wc -l < "$TMPD/expected" | tr -d ' ')
	[ "$_exp_n" -gt 0 ] || me_die "no always-expected pull_request workflows found — refusing to verify against an empty set"
	me_log "expected blocking workflows: $_exp_n"

	# DEFECT 4: a reopen retriggers EVERY workflow. Without a pre-trigger snapshot the
	# capture cannot tell the new runs from the old ones, and an unfiltered capture never
	# converges on the expected set.
	runs_for_head "$_head" | cut -f1 | sort > "$TMPD/pre_ids"
	me_log "pre-trigger run IDs on head: $(wc -l < "$TMPD/pre_ids" | tr -d ' ')"

	me_log "triggering (close/reopen) — a controlled boundary, never 'gh run rerun'"
	gh pr close "$PR" -R "$REPO" >/dev/null
	gh pr reopen "$PR" -R "$REPO" >/dev/null

	# DEFECT 5: the epoch must come from GitHub's OWN event, not the local clock. Comparing a
	# locally-stamped time against GitHub's `created_at` makes acceptance depend on clock skew.
	_epoch=$(gh api "repos/$REPO/issues/$PR/timeline?per_page=100" --paginate \
		-q '[.[] | select(.event == "reopened") | .created_at] | last' 2>/dev/null)
	[ -n "$_epoch" ] && [ "$_epoch" != "null" ] || me_die "could not read the reopened event epoch from GitHub's timeline"
	me_log "trigger epoch (GitHub's own reopened event): $_epoch"

	me_log "capturing post-trigger run IDs (timeout ${TIMEOUT}s)"
	_deadline=$(( $(date +%s) + TIMEOUT ))
	while :; do
		runs_for_head "$_head" > "$TMPD/runs_raw" || true
		me_filter_captured "$TMPD/runs_raw" "$TMPD/pre_ids" "$_epoch" > "$TMPD/captured"
		cut -f2 "$TMPD/captured" | sort > "$TMPD/captured_paths"
		_problems=$(me_account_set "$TMPD/captured_paths" "$TMPD/expected")
		[ -z "$_problems" ] && break
		[ "$(date +%s)" -ge "$_deadline" ] && {
			me_log "accounting still incomplete at timeout:"
			printf '%s\n' "$_problems" >&2
			me_die "could not capture exactly the expected blocking workflows within ${TIMEOUT}s"
		}
		sleep 15
	done
	me_log "captured exactly $(wc -l < "$TMPD/captured" | tr -d ' ') run(s), one per expected workflow"

	# DEFECT 6: the merge ref is recomputed BY the trigger. Baselining it before the trigger
	# guarantees a mismatch and blocks every round. Baseline it here, after.
	_mref=$(pr_merge_ref)

	mkdir -p "$(dirname "$MANIFEST")"
	jq -n \
		--arg repo "$REPO" --arg pr "$PR" --arg head "$_head" --arg base "$_base" \
		--arg mref "$_mref" --arg epoch "$_epoch" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--rawfile cap "$TMPD/captured" --rawfile exp "$TMPD/expected" \
		'{
			schema: "sentinel-shield/merge-evidence@1",
			phase: "trigger",
			repository: $repo,
			pull_request: ($pr | tonumber),
			triggered_at: $at,
			trigger_epoch: $epoch,
			frozen: { head_sha: $head, base_tip: $base, merge_ref: $mref },
			expected_workflows: ($exp | split("\n") | map(select(length > 0))),
			captured_runs: ($cap | split("\n") | map(select(length > 0))
				| map(split("\t") | {id: (.[0] | tonumber), path: .[1]}))
		}' > "$MANIFEST"
	me_log "proof manifest written: $MANIFEST"
}

phase_verify() {
	[ -f "$MANIFEST" ] || me_die "no manifest at $MANIFEST — run the trigger phase first"
	_head=$(jq -r .frozen.head_sha "$MANIFEST")
	jq -r '.expected_workflows[]' "$MANIFEST" | sort > "$TMPD/expected"

	_deadline=$(( $(date +%s) + TIMEOUT ))
	while :; do
		: > "$TMPD/results"
		_pending=0
		# Poll ONLY the captured immutable run IDs. Never a fresh head-only query: that would
		# re-admit whatever runs happen to exist now, which is the whole failure mode.
		# (#251) One run id per LINE, not word-split command substitution.
		_meids=$(jq -r '.captured_runs[].id' "$MANIFEST")
		while IFS= read -r _id; do
			[ -n "$_id" ] || continue
			# stdin is the id heredoc; keep `gh` from consuming the remaining ids.
			_j=$(api_run "$_id" </dev/null) || me_die "could not read run $_id"
			_v=$(me_classify_run \
				"$(printf '%s' "$_j" | jq -r '.status // ""')" \
				"$(printf '%s' "$_j" | jq -r '.conclusion // ""')" \
				"$(printf '%s' "$_j" | jq -r '.run_attempt // ""')" \
				"$(printf '%s' "$_j" | jq -r '.head_sha // ""')" \
				"$_head")
			printf '%s\t%s\t%s\n' "$_id" "$(printf '%s' "$_j" | jq -r '.path // ""')" "$_v" >> "$TMPD/results"
			[ "$_v" = "pending" ] && _pending=$((_pending + 1))
		done <<ME_IDS1
$_meids
ME_IDS1
		[ "$_pending" -eq 0 ] && break
		[ "$(date +%s)" -ge "$_deadline" ] && me_die "$_pending run(s) still pending at timeout — pending is not a verdict"
		me_log "$_pending run(s) pending; waiting"
		sleep 30
	done

	awk -F'\t' '{print $2}' "$TMPD/results" | sort > "$TMPD/captured_paths"
	_problems=$(me_account_set "$TMPD/captured_paths" "$TMPD/expected")
	_rejected=$(awk -F'\t' '$3 != "verified"' "$TMPD/results")

	if [ -n "$_problems" ] || [ -n "$_rejected" ]; then
		[ -n "$_problems" ] && { me_log "accounting problems:"; printf '%s\n' "$_problems" >&2; }
		[ -n "$_rejected" ] && { me_log "non-verified runs:"; printf '%s\n' "$_rejected" >&2; }
		_verdict=rejected
	else
		_verdict=verified
	fi

	jq --arg v "$_verdict" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--rawfile res "$TMPD/results" \
		'.phase = "verify" | .verified_at = $at | .verdict = $v
		 | .run_verdicts = ($res | split("\n") | map(select(length > 0))
			| map(split("\t") | {id: (.[0] | tonumber), path: .[1], verdict: .[2]}))' \
		"$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

	[ "$_verdict" = verified ] || me_die "verdict: rejected"
	me_log "verdict: verified ($(wc -l < "$TMPD/results" | tr -d ' ') runs, all attempt 1, all on $_head)"
}

phase_merge() {
	[ -f "$MANIFEST" ] || me_die "no manifest at $MANIFEST"
	[ "$(jq -r .verdict "$MANIFEST")" = verified ] || me_die "manifest verdict is not 'verified' — refusing to merge"
	_head=$(jq -r .frozen.head_sha "$MANIFEST")
	_base=$(jq -r .frozen.base_tip "$MANIFEST")
	_mref=$(jq -r .frozen.merge_ref "$MANIFEST")

	# Re-prove EVERY frozen input. Verification and merge are separated in time, and anything
	# that moved in between invalidates the evidence rather than merely aging it.
	me_log "re-proving frozen inputs"
	[ "$(pr_state)" = "open" ] || me_die "PR #$PR is no longer open"
	_now_head=$(pr_head_sha)
	[ "$_now_head" = "$_head" ] || me_die "head moved: frozen $_head, now $_now_head"
	_now_base=$(live_base_tip)
	[ "$_now_base" = "$_base" ] || me_die "base tip moved: frozen $_base, now $_now_base — the verified runs describe a superseded tree"
	_now_mref=$(pr_merge_ref)
	[ "$_now_mref" = "$_mref" ] || me_die "merge ref moved: frozen $_mref, now $_now_mref"

	# Re-read the captured runs too: a rerun launched after verification would change attempt.
	# (#251) One run id per LINE, not word-split command substitution.
	_meids=$(jq -r '.captured_runs[].id' "$MANIFEST")
	while IFS= read -r _id; do
		[ -n "$_id" ] || continue
		# stdin is the id heredoc; keep `gh` from consuming the remaining ids.
		_j=$(api_run "$_id" </dev/null) || me_die "could not re-read run $_id"
		_v=$(me_classify_run \
			"$(printf '%s' "$_j" | jq -r '.status // ""')" \
			"$(printf '%s' "$_j" | jq -r '.conclusion // ""')" \
			"$(printf '%s' "$_j" | jq -r '.run_attempt // ""')" \
			"$(printf '%s' "$_j" | jq -r '.head_sha // ""')" \
			"$_head")
		[ "$_v" = verified ] || me_die "run $_id no longer verifies: $_v"
	done <<ME_IDS2
$_meids
ME_IDS2

	me_log "merging with --match-head-commit $_head"
	gh pr merge "$PR" -R "$REPO" "--$METHOD" --match-head-commit "$_head" --delete-branch ||
		me_die "gh pr merge refused — the head moved between the re-proof and the merge"

	_mc=$(gh api "repos/$REPO/pulls/$PR" -q '.merge_commit_sha // ""')
	jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg mc "$_mc" \
		'.phase = "merge" | .merged_at = $at | .merge_commit = $mc' \
		"$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
	me_log "merged: $_mc"
}

TMPD=$(mktemp -d)
# No `exit` in the trap: an aborted phase must keep its non-zero status.
trap 'rm -rf "$TMPD" 2>/dev/null || :' EXIT

case "$PHASE" in
trigger) phase_trigger ;;
verify) phase_verify ;;
merge) phase_merge ;;
*) me_die "unknown phase: $PHASE (expected trigger|verify|merge)" ;;
esac
