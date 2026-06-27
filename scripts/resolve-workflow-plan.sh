#!/bin/sh
# Sentinel Shield — resolve a profile's tool policy into a CI execution PLAN.
#
# Reads a (composed) profile manifest's `tools` map and emits, per execution
# stage (pr / main / scheduled), the enabled tools that the workflow MUST run,
# each with its runner path and normalized report path. This is the bridge
# between the tool-policy contract (docs/profile-tool-policy.md) and the CI
# workflow (templates/workflows/sentinel-shield.yml): a tool is only legitimately
# "active" in CI when a job actually invokes its runner and produces its report.
#
# Composition: if the manifest declares `extends: [base, ...]`, the base profiles'
# `tools` maps merge FIRST (depth-first, deduped) and this profile's `tools`
# override per tool key (precedence handled by last-wins object merge; the child
# profile's whole toolPolicy object replaces a base's for the same key).
#
# Selection: every tool whose policy is NOT `disabled`/`external` and whose
# `execution.<stage>` is true. Each entry carries its `policy` so the consumer can
# filter to the gating set (required / one-of) — required tools are the ones the
# workflow MUST execute; recommended/optional are emitted for completeness.
#
# Output (JSON, stdout). Default (--stage all):
#   { "profile": "...", "tool_policy_version": N|null,
#     "stages": { "pr": [..], "main": [..], "scheduled": [..] } }
# With --stage pr|main|scheduled:
#   { "profile": "...", "stage": "pr", "tools": [..] }
# Each tool entry:
#   { "tool", "policy", "category", "runner", "report", "missing_behavior" }
#
# Usage:
#   resolve-workflow-plan.sh --profile <name> [--stage pr|main|scheduled|all]
#   resolve-workflow-plan.sh --manifest <path> [--stage ...]
# Exit: 0 on success (the plan is the output); 2 for invalid invocation / missing jq.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	printf 'Usage: resolve-workflow-plan.sh (--profile <name> | --manifest <path>) [--stage pr|main|scheduled|all]\n'
}

PROFILE=""
MANIFEST=""
STAGE="all"
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

case "$STAGE" in
	pr | main | scheduled | all) ;;
	*) log_error "--stage must be one of: pr | main | scheduled | all"; exit 2 ;;
esac
command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 2; }

# Resolve the manifest path: --manifest wins; else derive from --profile.
if [ -z "$MANIFEST" ]; then
	[ -n "$PROFILE" ] || { log_error "one of --profile or --manifest is required"; usage >&2; exit 2; }
	MANIFEST=$(cr_manifest_path "$REPO_ROOT" "$PROFILE")
fi
[ -f "$MANIFEST" ] || { log_error "profile manifest not found: $MANIFEST"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "invalid JSON in manifest: $MANIFEST"; exit 2; }
[ -n "$PROFILE" ] || PROFILE=$(jq -r '.profile // "unknown"' "$MANIFEST")

# --- compose tools across `extends` (bases first, child last, deduped) --------
# ORDER collects manifest paths in merge order; VISITED guards against cycles.
ORDER=""
VISITED=""
collect_manifests() {
	# $1 = manifest path
	case " $VISITED " in *" $1 "*) return 0 ;; esac
	VISITED="$VISITED $1"
	_bases=$(jq -r '(.extends // [])[]' "$1" 2>/dev/null || true)
	_oifs=$IFS
	IFS='
'
	for _b in $_bases; do
		IFS=$_oifs
		[ -n "$_b" ] || { IFS='
'; continue; }
		_bm=$(cr_manifest_path "$REPO_ROOT" "$_b")
		if [ -f "$_bm" ]; then
			collect_manifests "$_bm"
		else
			log_warn "extends base manifest not found: $_b ($_bm); ignoring"
		fi
		IFS='
'
	done
	IFS=$_oifs
	ORDER="$ORDER$1
"
}
collect_manifests "$MANIFEST"

# Slurp every manifest in merge order and reduce their `tools` maps (last wins).
_oifs=$IFS
IFS='
'
# shellcheck disable=SC2086
set -- $ORDER
IFS=$_oifs
TOOLS_JSON=$(jq -s 'map(.tools // {}) | reduce .[] as $t ({}; . + $t)' "$@")

TPV=$(jq '.tool_policy_version // null' "$MANIFEST")

# --- render the plan ---------------------------------------------------------
printf '%s' "$TOOLS_JSON" | jq \
	--arg profile "$PROFILE" \
	--argjson tpv "$TPV" \
	--arg stage "$STAGE" '
	def plan($s):
		to_entries
		| map(select((.value.policy // "") | (. != "disabled" and . != "external")))
		| map(select(.value.execution[$s] == true))
		| map({
			tool: .key,
			policy: .value.policy,
			category: (.value.category // null),
			runner: (.value.runner // null),
			report: (.value.report // null),
			missing_behavior: (.value.missing_behavior // null)
		});
	if $stage == "all" then
		{ profile: $profile, tool_policy_version: $tpv,
		  stages: { pr: plan("pr"), main: plan("main"), scheduled: plan("scheduled") } }
	else
		{ profile: $profile, tool_policy_version: $tpv, stage: $stage, tools: plan($stage) }
	end'
