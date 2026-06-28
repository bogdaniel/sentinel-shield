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
# Composition: ALL composition (extends, strongest-policy precedence, override,
# applicability, one-of, cycle/fail-closed) is delegated to the ONE canonical
# resolver (scripts/resolve-effective-profile.sh). This script implements NO
# composition of its own (Significant fix 11); both --profile and --manifest just
# call the resolver and render the per-stage plan from its `.tools`.
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
#   resolve-workflow-plan.sh --profile <name> [--target <dir>] [--stage pr|main|scheduled|all]
#   resolve-workflow-plan.sh --manifest <path> [--target <dir>] [--stage ...]
#
# --target is the consuming project root; it is passed through to the canonical
# resolver so applicability (and one-of selection) is evaluated against the real
# project. Without it, applicability is "unknown" and project-local tools (e.g.
# typescript without tsconfig.json) cannot be filtered out of the plan.
# Exit: 0 on success (the plan is the output); 2 for invalid invocation / missing jq.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	printf 'Usage: resolve-workflow-plan.sh (--profile <name> | --manifest <path>) [--target <dir>] [--stage pr|main|scheduled|all]\n'
}

PROFILE=""
MANIFEST=""
TARGET=""
STAGE="all"
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
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

# render_plan <profile> <tpv-json> <stage> — read a composed tools{} JSON map on
# stdin and emit the per-stage plan. Shared by BOTH resolution paths so the output
# shape (stages.pr/main/scheduled tool lists) is identical regardless of source.
render_plan() {
	jq \
		--arg profile "$1" \
		--argjson tpv "$2" \
		--arg stage "$3" '
		def plan($s):
			to_entries
			| map(select((.value.policy // "") | (. != "disabled" and . != "external")))
			| map(select((.value.applicability // "unknown") != "not-applicable"))
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
}

# BOTH modes delegate ALL composition to the canonical resolver (Significant fix
# 11 — no independent composition algorithm lives here). The resolver is
# fail-closed (exit 2 on unknown/missing parent, cycle, invalid policy), so an
# extends-unknown profile/manifest produces NO plan and a non-zero exit instead
# of a silently-degraded one. --target (when given) is forwarded so applicability
# is evaluated against the real project and not-applicable tools are filtered out.
# (Issue 8) NEVER flatten --target into an unquoted scalar — that breaks paths with
# spaces or glob characters. Use explicit, fully-quoted argument branches instead.
RESOLVER="$SCRIPT_DIR/resolve-effective-profile.sh"
[ -z "$TARGET" ] || [ -d "$TARGET" ] || { log_error "target directory not found: $TARGET"; exit 2; }
if [ -n "$MANIFEST" ]; then
	[ -f "$MANIFEST" ] || { log_error "profile manifest not found: $MANIFEST"; exit 2; }
	if [ -n "$TARGET" ]; then
		EFF=$(sh "$RESOLVER" --manifest "$MANIFEST" --target "$TARGET" --format json) || exit $?
	else
		EFF=$(sh "$RESOLVER" --manifest "$MANIFEST" --format json) || exit $?
	fi
else
	[ -n "$PROFILE" ] || { log_error "one of --profile or --manifest is required"; usage >&2; exit 2; }
	if [ -n "$TARGET" ]; then
		EFF=$(sh "$RESOLVER" --profile "$PROFILE" --target "$TARGET" --format json) || exit $?
	else
		EFF=$(sh "$RESOLVER" --profile "$PROFILE" --format json) || exit $?
	fi
fi
[ -n "$PROFILE" ] || PROFILE=$(printf '%s' "$EFF" | jq -r '.profile')
TPV=$(printf '%s' "$EFF" | jq '.tool_policy_version')
printf '%s' "$EFF" | jq '.tools' | render_plan "$PROFILE" "$TPV" "$STAGE"
