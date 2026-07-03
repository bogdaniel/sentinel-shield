#!/bin/sh
# Sentinel Shield — collect-release-evidence: GENERATE engine_ci[] evidence from
# the GitHub Actions API (Task 06.1).
#
# validate-release-evidence.sh already VERIFIES a hand-authored evidence file; this
# script is the missing GENERATOR. It queries the engine repository (through $GH_BIN,
# default 'gh', so tests can stub it) for the workflow runs that exercised one EXACT
# engine commit and emits a CANDIDATE release-evidence document (engine_ci[] populated,
# consumer_runs[] empty, required_evidence all false) to stdout or --output.
#
# It is deliberately fail-CLOSED and NEVER guesses:
#   * repository match      run.repository.full_name must equal --repo.
#   * default branch        run.head_branch must equal the repo default branch.
#   * approved event        run.event must be one of --events (default push,workflow_dispatch);
#                           a pull_request / schedule run is never release push evidence.
#   * exact workflow name   run.name must equal an expected --workflow.
#   * exact head SHA        run.head_sha must equal --commit.
#   * completed + success   run.status=="completed" and run.conclusion=="success".
# Runs that fail those filters are rejected with a precise reason:
#   missing-run | wrong-branch | failed-conclusion | cancelled | ambiguous-rerun.
# The "latest successful attempt" is deterministic: the GitHub runs list returns one
# entry per run_id (its latest attempt); exactly ONE completed+success run per workflow
# is required. Two DISTINCT successful runs for the same workflow+commit are ambiguous
# and REJECTED — the tool refuses to pick an authoritative run for you.
#
# This is a GENERATOR, not a writer: the candidate goes to stdout/--output. It NEVER
# writes evidence/releases/*.json. Feed the result to validate-release-evidence.sh.
#
# Usage:
#   collect-release-evidence.sh --repo <owner/name> --commit <40hex>
#       --workflow <name> [--workflow <name> ...]
#       --version <v> --stage <alpha|beta|rc|ga>
#       [--scope engine-only|framework-validated|full-platform]
#       [--events push,workflow_dispatch]
#       [--release-commit <40hex>] [--output <path>]
#
# Exit:
#   0 = a candidate evidence document was produced (every expected workflow matched)
#   1 = collection UNMET: an expected workflow had no unambiguous successful run
#   2 = invalid invocation / malformed API response
#   3 = required tool unavailable (jq, or gh)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

usage() {
	printf 'Usage: collect-release-evidence.sh --repo <owner/name> --commit <40hex> --workflow <name> [--workflow <name> ...] --version <v> --stage <alpha|beta|rc|ga> [--scope <engine-only|framework-validated|full-platform>] [--events push,workflow_dispatch] [--release-commit <40hex>] [--output <path>]\n'
}

REPO=""
COMMIT=""
WORKFLOWS=""
VERSION=""
STAGE=""
SCOPE="engine-only"
EVENTS="push,workflow_dispatch"
RELEASE_COMMIT=""
OUTPUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--workflow) WORKFLOWS="$WORKFLOWS
${2:?--workflow requires a value}"; shift 2 ;;
		--version) VERSION="${2:?--version requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--scope) SCOPE="${2:?--scope requires a value}"; shift 2 ;;
		--events) EVENTS="${2:?--events requires a value}"; shift 2 ;;
		--release-commit) RELEASE_COMMIT="${2:?--release-commit requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$REPO" ] || { log_error "--repo is required"; usage >&2; exit 2; }
[ -n "$COMMIT" ] || { log_error "--commit is required"; usage >&2; exit 2; }
[ -n "$VERSION" ] || { log_error "--version is required"; usage >&2; exit 2; }
[ -n "$STAGE" ] || { log_error "--stage is required"; usage >&2; exit 2; }
printf '%s' "$WORKFLOWS" | grep -q '[^[:space:]]' || { log_error "at least one --workflow is required"; usage >&2; exit 2; }

case "$REPO" in */*) ;; *) log_error "--repo must be owner/name"; exit 2 ;; esac
printf '%s' "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "--commit must be 40 lowercase hex"; exit 2; }
[ -z "$RELEASE_COMMIT" ] || printf '%s' "$RELEASE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "--release-commit must be 40 lowercase hex"; exit 2; }
case "$STAGE" in alpha | beta | rc | ga) ;; *) log_error "--stage must be alpha|beta|rc|ga"; exit 2 ;; esac
case "$SCOPE" in engine-only | framework-validated | full-platform) ;; *) log_error "--scope invalid"; exit 2 ;; esac

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
: "${GH_BIN:=gh}"
command_exists "$GH_BIN" || { log_error "GitHub API access requested but '$GH_BIN' is not available"; exit 3; }

# Approved-events JSON array from the comma list.
EVENTS_JSON=$(printf '%s' "$EVENTS" | tr ',' '\n' | grep -v '^$' | jq -R . | jq -sc .)

# Default branch (release evidence must be default-branch proof).
REPO_JSON=$("$GH_BIN" api "repos/$REPO" 2>/dev/null) || { log_error "could not fetch repository metadata for $REPO"; exit 2; }
printf '%s' "$REPO_JSON" | jq -e . >/dev/null 2>&1 || { log_error "malformed repository metadata for $REPO"; exit 2; }
DEFAULT_BRANCH=$(printf '%s' "$REPO_JSON" | jq -r '.default_branch // ""')
[ -n "$DEFAULT_BRANCH" ] || { log_error "repository $REPO reports no default_branch"; exit 2; }

# All runs for this commit (one entry per run_id == its latest attempt).
RUNS_JSON=$("$GH_BIN" api "repos/$REPO/actions/runs?head_sha=$COMMIT&per_page=100" 2>/dev/null) || {
	log_error "could not list workflow runs for $REPO at $COMMIT"; exit 2; }
printf '%s' "$RUNS_JSON" | jq -e . >/dev/null 2>&1 || { log_error "malformed runs response for $REPO"; exit 2; }

# select_run <workflow> — echo the single matching run object as compact JSON on
# stdout and return 0; on failure echo "REJECT:<reason>" and return 1.
select_run() {
	_wf="$1"
	printf '%s' "$RUNS_JSON" | jq -c \
		--arg wf "$_wf" --arg repo "$REPO" --arg commit "$COMMIT" \
		--arg branch "$DEFAULT_BRANCH" --argjson events "$EVENTS_JSON" '
		[ (.workflow_runs // [])[]
		  | select((.name == $wf) and ((.head_sha // "") == $commit)) ] as $named
		| ( [ $named[]
			  | . as $r
			  | select((($r.repository.full_name // $repo) == $repo)
					   and (($r.head_branch // "") == $branch)
					   and (($events | index($r.event // "")) != null)
					   and (($r.status // "") == "completed")
					   and (($r.conclusion // "") == "success")) ]
			| unique_by(.id) ) as $ok
		| if ($ok | length) == 1 then $ok[0]
		  elif ($ok | length) > 1 then { reject: "ambiguous-rerun", ids: [ $ok[].id ] }
		  elif ([ $named[] | select((.head_branch // "") != $branch) ] | length) > 0
			   and ([ $named[] | select((.head_branch // "") == $branch) ] | length) == 0
			then { reject: "wrong-branch" }
		  elif ([ $named[] | select((.conclusion // "") == "failure") ] | length) > 0
			then { reject: "failed-conclusion" }
		  elif ([ $named[] | select((.conclusion // "") == "cancelled") ] | length) > 0
			then { reject: "cancelled" }
		  else { reject: "missing-run" }
		  end
	'
}

VERIFIED_AT=$(timestamp_utc)
ENGINE_CI="[]"
UNMET=""

# Iterate expected workflows (newline-separated, de-duplicated, order-stable).
_seen=""
printf '%s\n' "$WORKFLOWS" | grep -v '^[[:space:]]*$' | while IFS= read -r _; do :; done
for _wf in $(printf '%s\n' "$WORKFLOWS" | grep -v '^[[:space:]]*$'); do
	case " $_seen " in *" $_wf "*) continue ;; esac
	_seen="$_seen $_wf"
	_run=$(select_run "$_wf")
	_reject=$(printf '%s' "$_run" | jq -r 'if type=="object" and has("reject") then .reject else empty end')
	if [ -n "$_reject" ]; then
		_detail=$(printf '%s' "$_run" | jq -r 'if has("ids") then " (run ids: \(.ids|join(",")))" else "" end')
		log_error "workflow '$_wf' at $COMMIT: $_reject$_detail"
		UNMET="$UNMET $_wf:$_reject"
		continue
	fi
	# Build the engine_ci entry. artifacts[] is emitted EMPTY (artifacts_verified
	# false): this GENERATOR proves only that the run exists and is default-branch
	# success. verify-release-artifacts.sh (Task 06.2) is what fetches each archive,
	# integrity-checks it, and rewrites artifacts[]/artifacts_verified. Emitting an
	# empty, honest artifacts[] keeps this candidate independently VALID under
	# validate-release-evidence.sh (whose invariant is: every LISTED artifact must be
	# verified=true) — a candidate must never carry an unverified artifact claim.
	ENGINE_CI=$(printf '%s' "$_run" | jq -c \
		--argjson prev "$ENGINE_CI" --arg at "$VERIFIED_AT" '
		. as $r
		| $prev + [ {
			workflow_name: $r.name,
			repository: $r.repository.full_name,
			commit: $r.head_sha,
			event: $r.event,
			workflow_run_id: $r.id,
			workflow_url: $r.html_url,
			result: $r.conclusion,
			artifacts: [],
			artifacts_verified: false,
			verified_at: $at,
			verification_method: "github-api"
		} ]')
done

# Assemble the candidate evidence document (deterministic key order).
CANDIDATE=$(jq -n \
	--arg version "$VERSION" --arg stage "$STAGE" --arg scope "$SCOPE" \
	--arg engine_commit "$COMMIT" --arg release_commit "$RELEASE_COMMIT" \
	--argjson engine_ci "$ENGINE_CI" '
	{ version: $version, stage: $stage, release_scope: $scope, engine_commit: $engine_commit }
	+ (if $release_commit == "" then {} else { release_commit: $release_commit } end)
	+ { engine_ci: $engine_ci,
		consumer_runs: [],
		required_evidence: { laravel:false, symfony:false, php_library:false, node_react:false,
			combined_profile:false, bootstrap_apply:false, rollback_npm:false, rollback_pnpm:false, rollback_yarn:false } }')

if [ -n "$OUTPUT" ]; then
	printf '%s\n' "$CANDIDATE" > "$OUTPUT"
else
	printf '%s\n' "$CANDIDATE"
fi

if [ -n "$UNMET" ]; then
	log_error "collection UNMET; the following expected workflows had no unambiguous successful run:$UNMET"
	log_error "the candidate above is INCOMPLETE and MUST NOT be promoted; re-collect once CI is green"
	exit 1
fi

log_info "collected $(printf '%s' "$ENGINE_CI" | jq 'length') engine_ci run(s) for $REPO at $COMMIT"
exit 0
