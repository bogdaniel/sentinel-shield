#!/bin/sh
# Sentinel Shield — canonical LOCAL pipeline (authoritative local equivalent of the
# CI release gate).
#
# Chains the EXISTING engine scripts, in the SAME order CI runs them, against a target
# project so a developer can reproduce the release gate locally without GitHub Actions:
#
#   resolve-effective-profile.sh   (canonical composed profile — single source of truth)
#     -> resolve-workflow-plan.sh  (per-stage execution PLAN — read-only)
#       -> CLEAR isolated outputs  (stale raw reports / summary / gate artifacts removed
#                                   BEFORE execution: no previous report may satisfy this run)
#         -> run-tool-plan.sh      (execute the stage's tools; required-tool absence and
#                                   execution failure are reported HONESTLY, never faked)
#           -> build-security-summary.sh  (--profile overlay: honest per-tool policy status)
#             -> resolve-gates.sh         (mode/profile -> machine-readable gate thresholds)
#               -> enforce-gates.sh       (mechanical pass/fail against the FRESH summary)
#                 -> Markdown + JSON pipeline report
#
# This script REUSES the engine scripts; it NEVER reimplements scanning, composition,
# normalization or gate logic. It only orchestrates and maps their exit codes onto the
# shared v2 contract.
#
# GUARANTEES
#   * The raw-report dir, the stage execution manifest, the security summary and the
#     prior gate/enforcement artifacts are removed BEFORE the tools run, so a stale
#     report from an earlier run can never satisfy (or pass) the current run.
#   * The security summary judged by the gate is always freshly generated this run.
#   * A REQUIRED tool (or required one-of group) that is unavailable fails honestly
#     (exit 3) and is NEVER turned into a passing result.
#   * An execution error (a required runner failed) is DISTINCT from findings: exit 4,
#     never folded into the findings/gate-failure code (1).
#   * one-of groups are enforced independently by the reused scripts.
#   * The gate result reflects ONLY the current execution.
#
# Usage:
#   run-local-pipeline.sh --profile <name> --target <path> --stage pr|main|scheduled
#       [--mode report-only|baseline|strict|regulated] [--output-dir <path>]
#       [--format markdown|json|all] [--keep-raw] [--fail-fast] [--non-interactive]
#
#   --profile <name>      Profile to resolve (profiles/<name>/ or combinations/). Required.
#   --target <path>       Consuming project root. Required-tool reports land under
#                         <target>/reports/raw (the runner-declared paths). Default: .
#   --stage <stage>       pr | main | scheduled.
#   --mode <mode>         Force the adoption mode for gate resolution. When omitted the
#                         target's .sentinel-shield/profile.yaml mode (or report-only) is used.
#   --output-dir <path>   Where the summary + gate + pipeline reports are written
#                         (default: <target>/reports). The raw scanner dir is always
#                         <target>/reports/raw because the runners declare those paths.
#   --keep-raw            Keep the raw scanner artifacts after the run (default: remove them).
#   --format <fmt>        Pipeline + enforcement report format: markdown | json | all (default: all).
#   --fail-fast           Stop immediately when the tool stage reports a required tool
#                         unavailable (3) or an execution error (4), instead of continuing
#                         to build a complete (honest) summary + enforcement report.
#   --non-interactive     Assume no prompts (the pipeline never prompts; accepted for CI parity).
#
# Exit codes (shared v2 contract — docs/workflow-execution-model.md#exit-codes):
#   0  the gate PASSED for this execution
#   1  findings / gate failure (enforce-gates blocked the build)
#   2  invalid config/input (bad flags, missing jq, unresolvable profile, bad summary/gates)
#   3  a REQUIRED tool or required one-of group is UNAVAILABLE (honest absence, not a pass)
#   4  execution / report-generation error (a required runner failed, or a stage could not
#      produce its report) — DISTINCT from findings
# When the tool stage reports BOTH unavailability and an execution failure, the more
# severe execution error (4) wins. An upstream 3/4 is never downgraded to a gate
# findings code (1), even when --fail-fast is off and a full report is still produced.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# die_cfg <message...> — configuration/input error -> exit 2.
die_cfg() {
	log_error "$*"
	exit 2
}

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: run-local-pipeline.sh --profile <name> --target <path> --stage pr|main|scheduled [options]

Run the canonical Sentinel Shield release gate locally by chaining the engine scripts.

Options:
  --profile <name>      Profile to resolve (required).
  --target <path>       Consuming project root (default: .).
  --stage <stage>       pr | main | scheduled (required).
  --mode <mode>         report-only | baseline | strict | regulated (force the gate mode).
  --output-dir <path>   Summary + gate + pipeline report dir (default: <target>/reports).
  --keep-raw            Keep raw scanner artifacts after the run (default: remove them).
  --format <fmt>        markdown | json | all (default: all).
  --fail-fast           Stop immediately on required-tool-unavailable (3) / execution-error (4).
  --non-interactive     Assume no prompts (accepted for CI parity).
  -h, --help            Show this help.

Exit: 0 pass, 1 findings/gate failure, 2 invalid config/input, 3 required tool unavailable,
4 execution/report error. Requires jq.
EOF
}

# --- defaults / CLI ----------------------------------------------------------
PROFILE=""
TARGET="."
STAGE=""
MODE=""
OUTPUT_DIR=""
KEEP_RAW=0
FORMAT="all"
FAIL_FAST=0
NON_INTERACTIVE=0

while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
		--keep-raw) KEEP_RAW=1; shift ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		--fail-fast) FAIL_FAST=1; shift ;;
		--non-interactive) NON_INTERACTIVE=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

# --- validate inputs ---------------------------------------------------------
[ -n "$PROFILE" ] || { log_error "--profile is required"; usage >&2; exit 2; }
case "$STAGE" in
	pr | main | scheduled) ;;
	*) die_cfg "--stage must be one of: pr | main | scheduled" ;;
esac
if [ -n "$MODE" ]; then
	case "$MODE" in
		report-only | baseline | strict | regulated) ;;
		*) die_cfg "--mode must be one of: report-only | baseline | strict | regulated" ;;
	esac
fi
case "$FORMAT" in
	markdown | json | all) ;;
	*) die_cfg "--format must be one of: markdown | json | all" ;;
esac
command_exists jq || die_cfg "jq is required but was not found. Install jq."

[ -d "$TARGET" ] || die_cfg "target directory not found: $TARGET"
TARGET=$(CDPATH= cd -- "$TARGET" && pwd)

[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$TARGET/reports"
mkdir -p "$OUTPUT_DIR" || die_cfg "cannot create output dir: $OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)

# Raw reports + the stage execution manifest are dictated by the runner-declared paths,
# which are relative to the target cwd (reports/raw/<tool>.json). They therefore ALWAYS
# live under <target>/reports regardless of --output-dir.
RAW_DIR="$TARGET/reports/raw"
EXEC_MANIFEST="$TARGET/reports/${STAGE}-execution.json"
SUMMARY="$OUTPUT_DIR/security-summary.json"
GATES_ENV="$OUTPUT_DIR/sentinel-shield-gates.env"
EFFECTIVE_JSON="$OUTPUT_DIR/effective-profile.json"
WORKFLOW_PLAN="$OUTPUT_DIR/workflow-plan.json"
PIPELINE_JSON="$OUTPUT_DIR/pipeline-report.json"
PIPELINE_MD="$OUTPUT_DIR/pipeline-report.md"
PROFILE_YAML="$TARGET/.sentinel-shield/profile.yaml"
ACCEPTED_RISKS="$TARGET/.sentinel-shield/accepted-risks.json"
CONTROL_WAIVERS="$TARGET/.sentinel-shield/control-waivers.json"

TS=$(timestamp_utc)

# --- stage bookkeeping -------------------------------------------------------
STAGES_ACC=""   # newline-delimited "name|status|exit"
# record_stage <name> <status> <exit> — append one stage outcome.
record_stage() {
	STAGES_ACC="${STAGES_ACC}$1|$2|$3
"
}

# stages_json — render the accumulated stage outcomes as a JSON array.
stages_json() {
	printf '%s' "$STAGES_ACC" | jq -R -s '
		split("\n") | map(select(length > 0) | split("|"))
		| map({ stage: .[0], status: .[1], exit: (.[2] | tonumber? // null) })'
}

# emit_reports <result> <exit> <message> — write the pipeline Markdown/JSON report(s)
# per --format. Always reflects ONLY the current execution.
emit_reports() {
	_result="$1"; _ec="$2"; _msg="${3:-}"
	_stages=$(stages_json)
	if [ "$FORMAT" = "json" ] || [ "$FORMAT" = "all" ]; then
		jq -n \
			--arg version "1.0" \
			--arg generated_at "$TS" \
			--arg profile "$PROFILE" \
			--arg target "$TARGET" \
			--arg stage "$STAGE" \
			--arg mode "$MODE" \
			--arg output_dir "$OUTPUT_DIR" \
			--arg result "$_result" \
			--argjson exit "$_ec" \
			--arg message "$_msg" \
			--argjson stages "$_stages" \
			--arg summary "$SUMMARY" \
			'{
				version: $version,
				generated_at: $generated_at,
				profile: $profile,
				target: $target,
				stage: $stage,
				mode: (if $mode == "" then null else $mode end),
				output_dir: $output_dir,
				result: $result,
				exit: $exit,
				message: (if $message == "" then null else $message end),
				security_summary: $summary,
				stages: $stages
			}' > "$PIPELINE_JSON"
		log_info "wrote $PIPELINE_JSON"
	fi
	if [ "$FORMAT" = "markdown" ] || [ "$FORMAT" = "all" ]; then
		{
			printf '# Sentinel Shield — Local Pipeline\n\n'
			printf -- '- Profile: `%s`\n' "$PROFILE"
			printf -- '- Target: `%s`\n' "$TARGET"
			printf -- '- Stage: **%s**\n' "$STAGE"
			printf -- '- Mode: %s\n' "${MODE:-(from profile / default)}"
			printf -- '- Generated: %s\n' "$TS"
			printf -- '- Output dir: `%s`\n\n' "$OUTPUT_DIR"
			printf -- '## Result: %s (exit %s)\n\n' "$(printf '%s' "$_result" | tr '[:lower:]' '[:upper:]')" "$_ec"
			[ -n "$_msg" ] && printf -- '> %s\n\n' "$_msg"
			printf '## Stages\n\n'
			printf -- '| Stage | Status | Exit |\n| --- | --- | --- |\n'
			printf '%s' "$STAGES_ACC" | while IFS='|' read -r _n _s _x; do
				[ -n "$_n" ] || continue
				printf -- '| %s | %s | %s |\n' "$_n" "$_s" "$_x"
			done
			printf '\n'
			printf -- '- Security summary: `%s`\n' "$SUMMARY"
			printf -- '- Resolved gates: `%s`\n' "$GATES_ENV"
			printf -- '- Enforcement: `%s`\n' "$OUTPUT_DIR/sentinel-shield-enforcement.json"
		} > "$PIPELINE_MD"
		log_info "wrote $PIPELINE_MD"
	fi
}

# finish <exit> <result> [message] — emit reports, clean up raw (unless --keep-raw), exit.
finish() {
	_fec="$1"; _fres="$2"; _fmsg="${3:-}"
	emit_reports "$_fres" "$_fec" "$_fmsg"
	if [ "$KEEP_RAW" -eq 0 ]; then
		rm -rf -- "$RAW_DIR" 2>/dev/null || true
	fi
	log_info "local-pipeline complete: stage=$STAGE result=$_fres exit=$_fec"
	exit "$_fec"
}

# --- 1. resolve the canonical effective profile (plan; validates the profile) ----
if sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$PROFILE" --target "$TARGET" --format json > "$EFFECTIVE_JSON" 2>/dev/null; then
	record_stage resolve-effective-profile ok 0
else
	record_stage resolve-effective-profile error 2
	finish 2 "config-error" "could not resolve effective profile '$PROFILE'"
fi

# --- 2. resolve the per-stage workflow execution plan (read-only) -----------------
if sh "$SCRIPT_DIR/resolve-workflow-plan.sh" --profile "$PROFILE" --target "$TARGET" --stage "$STAGE" > "$WORKFLOW_PLAN" 2>/dev/null; then
	record_stage resolve-workflow-plan ok 0
else
	record_stage resolve-workflow-plan error 2
	finish 2 "config-error" "could not resolve workflow plan for stage '$STAGE'"
fi

# --- 3. CLEAR isolated outputs BEFORE execution ----------------------------------
# Remove every report this run will CONSUME or PRODUCE downstream so no stale artifact
# can satisfy or pass the current run. The freshly-generated plan files above are kept.
rm -rf -- "$RAW_DIR"
mkdir -p "$RAW_DIR"
rm -f -- "$EXEC_MANIFEST" "$SUMMARY" \
	"$OUTPUT_DIR/sentinel-shield-gates.env" "$OUTPUT_DIR/sentinel-shield-gates.json" "$OUTPUT_DIR/sentinel-shield-gates.md" \
	"$OUTPUT_DIR/sentinel-shield-enforcement.json" "$OUTPUT_DIR/sentinel-shield-enforcement.md"
log_info "cleared stale execution outputs (raw dir, summary, gate + enforcement artifacts)"

# --- 4. execute the stage's tool plan (honest required-tool / execution handling) -
RTP_RC=0
sh "$SCRIPT_DIR/run-tool-plan.sh" --profile "$PROFILE" --target "$TARGET" --stage "$STAGE" --output-dir "reports/raw" >/dev/null 2>&1 || RTP_RC=$?
case "$RTP_RC" in
	0) record_stage run-tool-plan ok 0 ;;
	2) record_stage run-tool-plan error 2; finish 2 "config-error" "run-tool-plan: invalid configuration" ;;
	3) record_stage run-tool-plan unavailable 3 ;;
	4) record_stage run-tool-plan error 4 ;;
	*) record_stage run-tool-plan error 4; RTP_RC=4 ;;
esac

# Honest stop: with --fail-fast we do NOT proceed past a required-tool-unavailable (3)
# or execution-error (4) — there is nothing to gate honestly. Without --fail-fast we
# continue to produce a complete summary + enforcement report (with honest unavailable
# / execution-error per-tool statuses), but the final exit still reflects the upstream
# severity (3/4), never a downgraded findings code.
if [ "$RTP_RC" -eq 3 ] && [ "$FAIL_FAST" -eq 1 ]; then
	finish 3 "tool-unavailable" "a required tool or one-of group is unavailable (fail-fast)"
fi
if [ "$RTP_RC" -eq 4 ] && [ "$FAIL_FAST" -eq 1 ]; then
	finish 4 "execution-error" "a required tool's runner failed (fail-fast)"
fi

# --- 5. build the FRESH security summary (with --profile policy overlay) ----------
BSS_RC=0
sh "$SCRIPT_DIR/build-security-summary.sh" \
	--raw-dir "$RAW_DIR" --output "$SUMMARY" \
	--profile "$PROFILE" --target "$TARGET" \
	--project-name "$(basename -- "$TARGET")" --project-type "$PROFILE" \
	--commit local --branch local --workflow local-pipeline >/dev/null 2>&1 || BSS_RC=$?
case "$BSS_RC" in
	0) record_stage build-security-summary ok 0 ;;
	2) record_stage build-security-summary error 2; finish 2 "config-error" "build-security-summary: config/input error" ;;
	*) record_stage build-security-summary error 4; finish 4 "execution-error" "build-security-summary: report-generation error" ;;
esac

# --- 6. resolve the gate thresholds ----------------------------------------------
set -- --output-dir "$OUTPUT_DIR" --format all
[ -f "$PROFILE_YAML" ] && set -- --profile "$PROFILE_YAML" "$@"
[ -n "$MODE" ] && set -- "$@" --mode "$MODE"
RG_RC=0
sh "$SCRIPT_DIR/resolve-gates.sh" "$@" >/dev/null 2>&1 || RG_RC=$?
case "$RG_RC" in
	0) record_stage resolve-gates ok 0 ;;
	*) record_stage resolve-gates error 2; finish 2 "config-error" "resolve-gates: config/input error" ;;
esac

# --- 7. enforce the gates against the FRESH summary ------------------------------
set -- --gates-env "$GATES_ENV" --summary "$SUMMARY" --output-dir "$OUTPUT_DIR" --format "$FORMAT"
[ -f "$ACCEPTED_RISKS" ] && set -- "$@" --accepted-risks "$ACCEPTED_RISKS"
[ -f "$CONTROL_WAIVERS" ] && set -- "$@" --control-waivers "$CONTROL_WAIVERS"
ENF_RC=0
sh "$SCRIPT_DIR/enforce-gates.sh" "$@" >/dev/null 2>&1 || ENF_RC=$?
case "$ENF_RC" in
	0) record_stage enforce-gates pass 0 ;;
	1) record_stage enforce-gates fail 1 ;;
	2) record_stage enforce-gates error 2; finish 2 "config-error" "enforce-gates: config/input error" ;;
	*) record_stage enforce-gates error 4; finish 4 "execution-error" "enforce-gates: unexpected error" ;;
esac

# --- 8. final exit: upstream honest severity wins over a findings code ------------
if [ "$RTP_RC" -eq 4 ]; then
	finish 4 "execution-error" "a required tool's runner failed; see the enforcement report"
elif [ "$RTP_RC" -eq 3 ]; then
	finish 3 "tool-unavailable" "a required tool or one-of group is unavailable; see the enforcement report"
elif [ "$ENF_RC" -eq 1 ]; then
	finish 1 "fail" "one or more active gates failed"
else
	finish 0 "pass" "all active gates passed for this execution"
fi
