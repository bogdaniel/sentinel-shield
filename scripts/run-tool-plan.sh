#!/bin/sh
# Sentinel Shield — execute a profile's tool plan for one CI stage (v2).
#
# Resolves the CANONICAL effective profile (scripts/resolve-effective-profile.sh —
# never reimplements composition/override/applicability/one-of), selects the tools
# that this stage must run, invokes each tool's runner, records the runner exit and
# whether the expected report exists and is valid JSON, and writes a stage execution
# manifest to reports/<stage>-execution.json. It NEVER fabricates a passing report;
# final policy enforcement is left to enforce-gates.sh.
#
# Selection (per stage): a tool runs when
#   - policy is not `disabled` and not `external`, AND
#   - execution.<stage> == true, AND
#   - applicability != "not-applicable".
# one-of MEMBER tools (pest/phpunit, jest/vitest) are NOT run directly; for each
# one-of GROUP whose group entry runs this stage we run the resolver-SELECTED member
# (.one_of_groups[<g>].selected). If no member is selected the group is recorded
# `unsatisfied` (a required group then makes the stage fail; see exit codes).
#
# Usage:
#   run-tool-plan.sh --profile <name> --target <dir> --stage pr|main|scheduled
#       [--output-dir reports/raw] [--override <path>]
#
#   --profile <name>     Profile to resolve (profiles/<name>/ or combinations/).
#   --target <dir>       Consuming project root. Runners run with this as CWD and
#                        reports land under <target>/<output-dir>.
#   --stage <stage>      pr | main | scheduled.
#   --output-dir <dir>   Raw-report directory (default reports/raw). The execution
#                        manifest is written to its PARENT, i.e. reports/<stage>-execution.json.
#   --override <path>    Optional project tool-policy override, forwarded to the resolver.
#
# Exit codes (shared v2 contract — docs/workflow-execution-model.md#exit-codes):
#   0  the plan ran (a report may still contain findings — the gate decides)
#   2  invalid invocation / configuration (bad args, missing jq, unresolvable profile)
#   3  a REQUIRED tool (or required one-of group) is unavailable (no/invalid report,
#      or no member selected) — its runner did NOT fail, the tool just did not produce
#      a valid report
#   4  a REQUIRED tool's runner FAILED (non-zero runner exit)
# When both a required execution failure and a required unavailability occur, exit 4
# (the more severe execution failure) takes precedence. The execution manifest is
# ALWAYS written before exiting non-zero (3/4).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	printf 'Usage: run-tool-plan.sh --profile <name> --target <dir> --stage pr|main|scheduled [--output-dir reports/raw] [--override <path>]\n'
}

PROFILE=""
TARGET=""
STAGE=""
OUTPUT_DIR="reports/raw"
OVERRIDE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
		--override) OVERRIDE="${2:?--override requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$PROFILE" ] || { log_error "--profile is required"; usage >&2; exit 2; }
[ -n "$TARGET" ] || { log_error "--target is required"; usage >&2; exit 2; }
case "$STAGE" in
	pr | main | scheduled) ;;
	*) log_error "--stage must be one of: pr | main | scheduled"; usage >&2; exit 2 ;;
esac
command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 2; }

if [ -d "$TARGET" ]; then
	TARGET=$(CDPATH= cd -- "$TARGET" && pwd)
else
	log_error "target directory not found: $TARGET"
	exit 2
fi
if [ -n "$OVERRIDE" ] && [ ! -f "$OVERRIDE" ]; then
	log_error "override file not found: $OVERRIDE"
	exit 2
fi

# Resolve the canonical effective profile (with target for applicability + one-of
# satisfaction). Composition/override logic lives ENTIRELY in the resolver.
_ovr_args=""
[ -n "$OVERRIDE" ] && _ovr_args="--override $OVERRIDE"
# shellcheck disable=SC2086
EFF=$(sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$PROFILE" --target "$TARGET" $_ovr_args --format json) \
	|| { log_error "could not resolve effective profile '$PROFILE'"; exit 2; }
printf '%s' "$EFF" | jq -e . >/dev/null 2>&1 || { log_error "effective profile resolver emitted invalid JSON"; exit 2; }

# From here on, runners run with the target project as CWD so their relative report
# paths (reports/raw/<tool>.json) land under the project.
cd -- "$TARGET"

RAW_DIR="$OUTPUT_DIR"
MANIFEST_DIR=$(dirname -- "$RAW_DIR")
MANIFEST_PATH="$MANIFEST_DIR/${STAGE}-execution.json"
ensure_dir "$RAW_DIR"
ensure_dir "$MANIFEST_DIR"

TOOLS_ACC=""
GROUPS_ACC=""
REQ_EXEC_FAIL=0   # a required runner failed (-> exit 4)
REQ_UNAVAIL=0     # a required tool/group is unavailable (-> exit 3)

# eff_get <jq-filter> — read a scalar from the resolved effective profile.
eff_get() { printf '%s' "$EFF" | jq -r "$1"; }

# run_runner <runner-rel-path> <report-path> <log-name> — invoke a runner and
# classify the outcome. Sets globals RC (runner exit as JSON: a number or "null")
# and STATUS (ran | unavailable | error | skipped).
run_runner() {
	_runner="$1"; _report="$2"; _log="$3"
	RC=null
	STATUS=skipped
	# Nothing to run and nothing to verify (e.g. a setup tool like deps-install).
	if [ -z "$_runner" ] && [ -z "$_report" ]; then
		STATUS=skipped
		return 0
	fi
	if [ -n "$_runner" ]; then
		if [ ! -f "$REPO_ROOT/$_runner" ]; then
			log_warn "runner not found: $_runner (tool unavailable)"
			STATUS=unavailable
			RC=null
			return 0
		fi
		_rc=0
		sh "$REPO_ROOT/$_runner" >"$RAW_DIR/${_log}.run.log" 2>&1 || _rc=$?
		RC=$_rc
	fi
	if [ -n "$_report" ]; then
		if jq -e . "$_report" >/dev/null 2>&1; then
			STATUS=ran
		elif [ "$RC" != "null" ] && [ "$RC" -ne 0 ]; then
			STATUS=error
		else
			STATUS=unavailable
		fi
	else
		if [ "$RC" = "null" ]; then STATUS=skipped
		elif [ "$RC" -eq 0 ]; then STATUS=ran
		else STATUS=error
		fi
	fi
}

# note_required_outcome <policy> <status> — accumulate exit-code contributions for
# required tools/groups only.
note_required_outcome() {
	[ "$1" = "required" ] || return 0
	case "$2" in
		error) REQ_EXEC_FAIL=1 ;;
		unavailable | unsatisfied) REQ_UNAVAIL=1 ;;
	esac
}

# --- normal (non one-of) tools ----------------------------------------------
NORMAL_KEYS=$(eff_get '
	.tools | to_entries
	| map(select((.value.policy // "") as $p | ($p != "disabled" and $p != "external" and $p != "one-of")))
	| map(select(.value.execution["'"$STAGE"'"] == true))
	| map(select((.value.applicability // "unknown") != "not-applicable"))
	| .[].key')

_oifs=$IFS
IFS='
'
for KEY in $NORMAL_KEYS; do
	IFS=$_oifs
	[ -n "$KEY" ] || { IFS='
'; continue; }
	POLICY=$(eff_get '.tools["'"$KEY"'"].policy')
	RUNNER=$(eff_get '.tools["'"$KEY"'"].runner // ""')
	REPORT=$(eff_get '.tools["'"$KEY"'"].report // ""')
	run_runner "$RUNNER" "$REPORT" "$KEY"
	note_required_outcome "$POLICY" "$STATUS"
	log_info "tool $KEY: policy=$POLICY status=$STATUS runner_exit=$RC"
	TOOLS_ACC="${TOOLS_ACC}$(jq -nc --arg k "$KEY" --arg p "$POLICY" --argjson re "$RC" --arg st "$STATUS" --arg rep "$REPORT" \
		'{key:$k, policy:$p, runner_exit:$re, status:$st, report:(if $rep=="" then null else $rep end)}')
"
	IFS='
'
done
IFS=$_oifs

# --- one-of groups -----------------------------------------------------------
GROUP_KEYS=$(eff_get '.one_of_groups | keys[]?')

_oifs=$IFS
IFS='
'
for GKEY in $GROUP_KEYS; do
	IFS=$_oifs
	[ -n "$GKEY" ] || { IFS='
'; continue; }
	GRP_EXEC=$(eff_get '.tools["'"$GKEY"'"].execution["'"$STAGE"'"] // false')
	[ "$GRP_EXEC" = "true" ] || { IFS='
'; continue; }
	GPOLICY=$(eff_get '.one_of_groups["'"$GKEY"'"].policy')
	SEL=$(eff_get '.one_of_groups["'"$GKEY"'"].selected // ""')
	GREPORT=$(eff_get '.tools["'"$GKEY"'"].report // ""')
	if [ -z "$SEL" ]; then
		STATUS=unsatisfied
		RC=null
		log_warn "one-of group $GKEY: no member selected (unsatisfied)"
	else
		MRUNNER=$(eff_get '.tools["'"$SEL"'"].runner // ""')
		MREPORT="$GREPORT"
		[ -n "$MREPORT" ] || MREPORT=$(eff_get '.tools["'"$SEL"'"].report // ""')
		run_runner "$MRUNNER" "$MREPORT" "$GKEY"
		[ -n "$GREPORT" ] || GREPORT="$MREPORT"
		log_info "one-of group $GKEY: selected=$SEL status=$STATUS runner_exit=$RC"
	fi
	note_required_outcome "$GPOLICY" "$STATUS"
	GROUPS_ACC="${GROUPS_ACC}$(jq -nc --arg k "$GKEY" --arg p "$GPOLICY" --arg sel "$SEL" --argjson re "$RC" --arg st "$STATUS" --arg rep "$GREPORT" \
		'{key:$k, policy:$p, selected:(if $sel=="" then null else $sel end), status:$st, runner_exit:$re, report:(if $rep=="" then null else $rep end)}')
"
	IFS='
'
done
IFS=$_oifs

# --- write the stage execution manifest (ALWAYS, before any non-zero exit) ----
TOOLS_JSON=$(printf '%s' "$TOOLS_ACC" | jq -s 'map({(.key): {policy:.policy, runner_exit:.runner_exit, status:.status, report:.report}}) | add // {}')
GROUPS_JSON=$(printf '%s' "$GROUPS_ACC" | jq -s 'map({(.key): {policy:.policy, selected:.selected, status:.status, runner_exit:.runner_exit, report:.report}}) | add // {}')
jq -n \
	--arg profile "$PROFILE" \
	--arg stage "$STAGE" \
	--argjson tools "$TOOLS_JSON" \
	--argjson groups "$GROUPS_JSON" \
	'{profile:$profile, stage:$stage, tools:$tools, one_of_groups:$groups}' > "$MANIFEST_PATH"
log_info "wrote execution manifest: $MANIFEST_PATH"

if [ "$REQ_EXEC_FAIL" -eq 1 ]; then
	log_error "a required tool's runner failed; see $MANIFEST_PATH"
	exit 4
elif [ "$REQ_UNAVAIL" -eq 1 ]; then
	log_error "a required tool or one-of group is unavailable; see $MANIFEST_PATH"
	exit 3
fi
exit 0
