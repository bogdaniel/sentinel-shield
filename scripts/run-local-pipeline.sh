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
#       [--purpose developer|release] [--format markdown|json|all] [--keep-raw]
#       [--fail-fast] [--non-interactive]
#
#   --profile <name>      Profile to resolve (profiles/<name>/ or combinations/). Required.
#   --target <path>       Consuming project root. Required-tool reports land under
#                         <target>/reports/raw (the runner-declared paths). Default: .
#   --stage <stage>       pr | main | scheduled.
#   --mode <mode>         Force the adoption mode for gate resolution. When omitted the
#                         target's .sentinel-shield/profile.yaml mode (or report-only) is used.
#   --output-dir <path>   Where the summary + gate + pipeline reports are written
#                         (default: <target>/reports). *** PARTIAL (Finding 7): the engine
#                         runners hard-code reports/raw/<tool>.json and the stage execution
#                         manifest at reports/<stage>-execution.json — run-tool-plan invokes
#                         each runner with NO positional path and the profile .report fields
#                         are fixed — so raw evidence CANNOT be relocated this release. To
#                         avoid a SILENT split of the evidence root, --output-dir is REQUIRED
#                         to be <target>/reports or a subdirectory of it; anything else is
#                         rejected (exit 2). FOLLOW-UP MIGRATION: thread an absolute
#                         report-root through run-tool-plan.sh -> each runner (positional
#                         $1) and through the profile .report paths, then drive ALL evidence
#                         (raw/, *-execution.json, summary, gates, enforcement, pipeline) under
#                         a single arbitrary --output-dir.
#   --purpose <p>         developer | release (default: developer).
#                           developer : raw scanner artifacts MAY be removed after the run
#                                       (default cleanup) — the raw-evidence manifest and its
#                                       per-report SHA-256 hashes are STILL written and survive.
#                           release   : raw scanner artifacts are RETAINED and made immutable
#                                       (read-only) for the run; hashes are recorded. The
#                                       security summary never outlives the hashes + execution
#                                       metadata needed to verify how it was produced.
#   --keep-raw            Keep the raw scanner artifacts after the run (default: remove them;
#                         implied by --purpose release).
#   --format <fmt>        Pipeline + enforcement report format: markdown | json | all (default: all).
#   --fail-fast           Stop immediately when the tool stage reports a required tool
#                         unavailable (3) or an execution error (4), instead of continuing
#                         to build a complete (honest) summary + enforcement report.
#   --non-interactive     Assume no prompts (the pipeline never prompts; accepted for CI parity).
#
# CONCURRENCY (Finding 7): because raw evidence shares a fixed root (<target>/reports/raw)
# that this run clears BEFORE execution, two concurrent runs against the same target would
# delete/replace each other's raw reports. A run lock (<target>/reports/.pipeline-lock,
# created with an atomic mkdir) prevents this: if another run holds it the pipeline REFUSES
# and exits 4 (execution failure) rather than racing. The lock is released on exit.
#
# RAW-EVIDENCE MANIFEST (Finding 8): regardless of --purpose, a durable per-tool manifest is
# written to <output-dir>/raw-evidence-manifest.json recording, for every executed tool/group:
# tool, runner, runner_exit, status, report_path, report_sha256, produced_at,
# preserved_or_deleted and duration — so the summary can always be traced back to how it was
# produced even after raw reports are cleaned up.
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
                        PARTIAL: must be <target>/reports or a subdir (raw evidence root is
                        fixed); anything else is rejected (exit 2).
  --purpose <p>         developer | release (default: developer). release retains + freezes raw.
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
PURPOSE="developer"
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
		--purpose) PURPOSE="${2:?--purpose requires a value}"; shift 2 ;;
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
case "$PURPOSE" in
	developer | release) ;;
	*) die_cfg "--purpose must be one of: developer | release" ;;
esac
# release retains raw evidence (and freezes it immutable below); developer may clean it up.
[ "$PURPOSE" = release ] && KEEP_RAW=1
command_exists jq || die_cfg "jq is required but was not found. Install jq."

[ -d "$TARGET" ] || die_cfg "target directory not found: $TARGET"
TARGET=$(CDPATH= cd -- "$TARGET" && pwd)

[ -n "$OUTPUT_DIR" ] || OUTPUT_DIR="$TARGET/reports"
mkdir -p "$OUTPUT_DIR" || die_cfg "cannot create output dir: $OUTPUT_DIR"
OUTPUT_DIR=$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)

# FINDING 7 (PARTIAL): the engine runners hard-code reports/raw/<tool>.json and the stage
# execution manifest at reports/<stage>-execution.json (run-tool-plan invokes runners with no
# positional path; the profile .report fields are fixed), so raw evidence cannot be relocated
# this release. Refuse any --output-dir that is not <target>/reports or a subdirectory of it,
# so we never SILENTLY split final artifacts away from the raw evidence root. Canonicalize
# first so '..'/symlink tricks cannot escape the reports root.
mkdir -p "$TARGET/reports" || die_cfg "cannot create reports dir: $TARGET/reports"
REPORTS_ROOT=$(CDPATH= cd -- "$TARGET/reports" && pwd)
case "$OUTPUT_DIR" in
	"$REPORTS_ROOT" | "$REPORTS_ROOT"/*) ;;
	*) die_cfg "--output-dir must be <target>/reports or a subdirectory of it ($REPORTS_ROOT); refusing to split the evidence root: $OUTPUT_DIR" ;;
esac

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
RAW_MANIFEST="$OUTPUT_DIR/raw-evidence-manifest.json"
PROFILE_YAML="$TARGET/.sentinel-shield/profile.yaml"
ACCEPTED_RISKS="$TARGET/.sentinel-shield/accepted-risks.json"
CONTROL_WAIVERS="$TARGET/.sentinel-shield/control-waivers.json"

TS=$(timestamp_utc)

# --- concurrency lock (Finding 7) --------------------------------------------
# Two concurrent runs against the same target share the fixed raw root and would clear
# each other's reports. Acquire an exclusive lock with an atomic mkdir; fail closed (exit 4)
# if another run holds it. The lock is released on exit ONLY if we acquired it (so a held
# lock owned by another run is never removed by us).
LOCK_DIR="$REPORTS_ROOT/.pipeline-lock"
LOCK_HELD=0
release_lock() {
	[ "$LOCK_HELD" -eq 1 ] || return 0
	rm -rf -- "$LOCK_DIR" 2>/dev/null || true
}
# On signal: release the lock AND stop immediately (the bare EXIT trap below only cleans
# up, it must NOT exit). Without the explicit exit, INT/TERM would clean the lock yet let
# the pipeline keep running. release_lock is idempotent, so the re-entry via the EXIT trap
# when we exit here is harmless.
trap release_lock EXIT
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM
if mkdir "$LOCK_DIR" 2>/dev/null; then
	LOCK_HELD=1
	printf '{"pid":%s,"started_at":"%s","stage":"%s","target":"%s"}\n' \
		"$$" "$TS" "$STAGE" "$TARGET" > "$LOCK_DIR/lock.json" 2>/dev/null || true
else
	log_error "another local pipeline run holds the lock ($LOCK_DIR); refusing to race (concurrent run)"
	exit 4
fi

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

# file_sha256 <path> — print the hex SHA-256 of a file, or nothing if it cannot be hashed.
file_sha256() {
	[ -f "$1" ] || return 0
	if command_exists sha256sum; then sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
	elif command_exists shasum; then shasum -a 256 -- "$1" 2>/dev/null | cut -d' ' -f1
	elif command_exists openssl; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
	fi
}

# iso_to_epoch <iso8601-zulu> — print epoch seconds (GNU or BSD date), or nothing.
iso_to_epoch() {
	[ -n "$1" ] || return 0
	date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true
}

# write_raw_evidence_manifest — Finding 8. Produce a durable per-tool manifest from the
# stage execution manifest (written by run-tool-plan) joined with the resolved effective
# profile (for runner paths) and freshly-computed report SHA-256 hashes. Written BEFORE any
# raw cleanup so the hashes describe the reports as produced this run. Best-effort: never
# aborts the pipeline (the exit-code contract is owned by the stage logic).
write_raw_evidence_manifest() {
	[ -f "$EXEC_MANIFEST" ] || return 0
	command_exists jq || return 0
	_preserved="deleted"
	[ "$KEEP_RAW" -eq 1 ] && _preserved="preserved"

	# SHA-256 per produced report (key<TAB>relative-report-path; both non-empty).
	_sha_map='{}'
	_sha_lines=$(jq -r '
		[ (.tools // {} | to_entries[]), (.one_of_groups // {} | to_entries[]) ]
		| .[] | select(.value.report != null and .value.report != "")
		| "\(.key)\t\(.value.report)"' "$EXEC_MANIFEST" 2>/dev/null || true)
	_oifs=$IFS
	IFS='
'
	for _l in $_sha_lines; do
		IFS=$_oifs
		_k=${_l%%	*}
		_rep=${_l#*	}
		_h=$(file_sha256 "$TARGET/$_rep" || true)
		[ -n "$_h" ] && _sha_map=$(printf '%s' "$_sha_map" | jq --arg k "$_k" --arg v "$_h" '. + {($k): $v}')
		IFS='
'
	done
	IFS=$_oifs

	# Duration per entry that actually ran (key<TAB>started<TAB>finished).
	_dur_map='{}'
	_dur_lines=$(jq -r '
		[ (.tools // {} | to_entries[]), (.one_of_groups // {} | to_entries[]) ]
		| .[] | select(.value.started_at != null and .value.started_at != "")
		| "\(.key)\t\(.value.started_at)\t\(.value.finished_at // "")"' "$EXEC_MANIFEST" 2>/dev/null || true)
	IFS='
'
	for _l in $_dur_lines; do
		IFS=$_oifs
		_k=${_l%%	*}
		_rest=${_l#*	}
		_st=${_rest%%	*}
		_fi=${_rest#*	}
		[ "$_fi" != "$_rest" ] || _fi=""
		_se=$(iso_to_epoch "$_st" || true)
		_fe=$(iso_to_epoch "$_fi" || true)
		if [ -n "$_se" ] && [ -n "$_fe" ]; then
			_dur_map=$(printf '%s' "$_dur_map" | jq --arg k "$_k" --argjson v "$((_fe - _se))" '. + {($k): $v}')
		fi
		IFS='
'
	done
	IFS=$_oifs

	jq -n \
		--slurpfile exec "$EXEC_MANIFEST" \
		--argjson eff "$(cat "$EFFECTIVE_JSON" 2>/dev/null || printf '{}')" \
		--argjson sha "$_sha_map" \
		--argjson dur "$_dur_map" \
		--arg preserved "$_preserved" \
		--arg generated_at "$TS" \
		--arg purpose "$PURPOSE" \
		--arg target "$TARGET" \
		'
		($exec[0] // {}) as $m
		| ($eff.tools // {}) as $efftools
		| def entry($key; $v; $runner):
			{
				tool: $key,
				runner: ($runner // null),
				runner_exit: ($v.runner_exit // null),
				status: ($v.status // null),
				report_path: ($v.report // null),
				report_sha256: ($sha[$key] // null),
				produced_at: ($v.finished_at // null),
				preserved_or_deleted: (if ($v.report_present // false) then $preserved else "absent" end),
				duration: ($dur[$key] // null)
			};
		{
			version: "1.0",
			generated_at: $generated_at,
			purpose: $purpose,
			profile: ($m.profile // null),
			stage: ($m.stage // null),
			target: $target,
			tools: [
				($m.tools // {} | to_entries[]
					| entry(.key; .value; ($efftools[.key].runner // null))),
				($m.one_of_groups // {} | to_entries[]
					| entry(.key; .value; (if .value.selected then ($efftools[.value.selected].runner // null) else null end))
					  + {selected: (.value.selected // null)})
			]
		}' > "$RAW_MANIFEST" 2>/dev/null || {
		log_warn "could not write raw-evidence manifest: $RAW_MANIFEST"
		return 0
	}
	log_info "wrote $RAW_MANIFEST"
}

# finish <exit> <result> [message] — emit reports, write the durable raw-evidence manifest
# (Finding 8), then clean up or freeze raw per --purpose/--keep-raw, exit.
finish() {
	_fec="$1"; _fres="$2"; _fmsg="${3:-}"
	emit_reports "$_fres" "$_fec" "$_fmsg"
	# Manifest + hashes are written BEFORE any raw removal so they outlive the reports.
	write_raw_evidence_manifest
	if [ "$KEEP_RAW" -eq 0 ]; then
		# developer default: raw may be removed (manifest + hashes already persisted).
		rm -rf -- "$RAW_DIR" 2>/dev/null || true
	elif [ "$PURPOSE" = release ]; then
		# release: raw reports are RETAINED and made immutable (read-only) for the run.
		find "$RAW_DIR" -type f -exec chmod a-w {} + 2>/dev/null || true
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
