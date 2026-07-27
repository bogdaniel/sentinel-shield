#!/bin/sh
# Sentinel Shield — required-tool PRODUCER COVERAGE for the installed product.
#
# `run-tool-plan.sh` exits 3 when a REQUIRED tool has no valid report. That is correct
# fail-closed behaviour — but it fires just as loudly when the shipped workflow simply has no
# step that PRODUCES the report the profile requires. A fresh installation could therefore fail
# because the workflow and the profile manifest disagreed, not because the consumer had
# findings (Laravel required codeql/osv-scanner/grype/syft/dependency-check at `main` while the
# managed workflow produced none of them, and the profile expected Syft at
# reports/raw/syft.json while the workflow wrote reports/sbom.spdx.json).
#
# This derives the matrix from the RESOLVED EFFECTIVE PROFILE — never from a hand-maintained
# list — and proves that every required tool selected for a stage has EXACTLY ONE producer:
#
#   runner    the effective profile declares `runner`, and that runner exists on disk;
#             run-tool-plan invokes it and it writes the report.
#   workflow  a shipped workflow step writes the exact report path the profile expects.
#
# AMBIGUITY IS A FAILURE: if a tool declares a runner AND a workflow step writes the same
# path, the report produced by the workflow is DELETED by run-tool-plan before the runner runs
# (stale-report protection), so the evidence that reaches the gate is not the evidence the
# workflow produced.
#
# READ-ONLY. Exit: 0 covered; 1 a required tool has no (or an ambiguous) producer;
#                  2 invalid invocation; 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	cat <<'EOF'
Usage:
  verify-producer-coverage.sh [--profile <name> ...] [--all-profiles] [--stage pr|main|scheduled|all]
                              [--workflow <file> ...] [--target <dir>] [--format text|json]

Defaults: --all-profiles --stage all, with the shipped combined + split workflow templates.
READ-ONLY; never writes, never runs a scanner.
EOF
}

PROFILES=""
STAGE="all"
WORKFLOWS=""
TARGET=""
FORMAT=text
ALL_PROFILES=0
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILES="$PROFILES ${2:?--profile requires a value}"; shift 2 ;;
		--all-profiles) ALL_PROFILES=1; shift ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
		--workflow) WORKFLOWS="$WORKFLOWS ${2:?--workflow requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done
case "$STAGE" in pr | main | scheduled | all) ;; *) log_error "--stage must be pr|main|scheduled|all"; exit 2 ;; esac
case "$FORMAT" in text | json) ;; *) log_error "--format must be text|json"; exit 2 ;; esac
command_exists jq || { log_error "jq is required"; exit 3; }

# Default profile set: every shipped standalone profile plus every combination.
if [ -z "$PROFILES" ] || [ "$ALL_PROFILES" -eq 1 ]; then
	for _d in "$REPO_ROOT"/profiles/*/profile.manifest.json; do
		[ -e "$_d" ] || continue
		_n=$(basename "$(dirname "$_d")")
		PROFILES="$PROFILES $_n"
	done
	for _c in "$REPO_ROOT"/profiles/combinations/*.manifest.json; do
		[ -e "$_c" ] || continue
		_n=$(basename "$_c"); _n="${_n%.manifest.json}"
		PROFILES="$PROFILES $_n"
	done
fi
# The workflows a consumer actually receives, mapped to the STAGE they run AND the VARIANT
# they belong to. Two things this encodes that a flat file list cannot:
#
#   * a step in the nightly workflow is NOT a producer for the main gate — the main-gate job
#     would still find no report and exit 3;
#   * the COMBINED template (what install-baseline writes) and the SPLIT per-job templates are
#     two independently installable products, so each must cover the stage on its own. A
#     report produced only by the split main workflow does not help a combined-template
#     adopter.
#
#   <variant>|<stage>|<file>[#<job>]
WORKFLOW_MAP="combined|pr|templates/workflows/sentinel-shield.yml#pr-fast
combined|main|templates/workflows/sentinel-shield.yml#main-gate
split|pr|templates/workflows/sentinel-shield-pr-fast.yml
split|main|templates/workflows/sentinel-shield-main.yml
split|scheduled|templates/workflows/sentinel-shield-scheduled.yml
split|scheduled|templates/workflows/sentinel-shield-dependency-check.yml"
if [ -n "$WORKFLOWS" ]; then
	# A user-supplied --workflow path is checked HERE, before any coverage decision. A path
	# the tool cannot read must fail loudly: silently reporting "no producer" for a file that
	# was never opened turns a typo into a security finding (or, worse, hides one).
	for _w in $WORKFLOWS; do
		case "$_w" in
			/*) [ -f "$_w" ] || { log_error "--workflow file not found: $_w"; exit 2; } ;;
			*) [ -f "$REPO_ROOT/$_w" ] || [ -f "$_w" ] || { log_error "--workflow file not found: $_w (looked in '$REPO_ROOT/$_w' and '$_w')"; exit 2; } ;;
		esac
	done
	WORKFLOW_MAP=$(for _w in $WORKFLOWS; do for _s in pr main scheduled; do printf 'custom|%s|%s\n' "$_s" "$_w"; done; done)
fi

# variants_for_stage <stage> — the variants that ship a workflow for this stage.
variants_for_stage() {
	printf '%s\n' "$WORKFLOW_MAP" | awk -F'|' -v s="$1" '$2 == s { print $1 }' | sort -u
}


STAGES="$STAGE"
[ "$STAGE" = all ] && STAGES="pr main scheduled"

FAILURES=0
ROWS=""
pass() { [ "$FORMAT" = text ] && printf '  PASS  %s\n' "$*"; return 0; }
fail() { FAILURES=$((FAILURES + 1)); [ "$FORMAT" = text ] && printf '  FAIL  %s\n' "$*"; return 0; }

# workflow_section <file> <job|""> — print the file, or just one job block of it. The block
# runs from `^  <job>:` to the next key at the same indent, which is how a GitHub workflow
# nests jobs; slicing by indent keeps this dependency-free (no yq needed to read a template).
workflow_section() {
	# An ABSOLUTE path became "$REPO_ROOT//tmp/…", `[ -f ]` failed, and the function returned
	# nothing — so the tool reported "no producer" for a file it never opened, and the
	# negative control asserting that passed for the wrong reason.
	case "$1" in
		/*) _ws_f="$1" ;;
		*) if [ -f "$REPO_ROOT/$1" ]; then _ws_f="$REPO_ROOT/$1"; else _ws_f="$1"; fi ;;
	esac
	_ws_job="${2:-}"
	if [ ! -f "$_ws_f" ]; then
		log_error "workflow file not found: $1 (resolved '$_ws_f') — refusing to report 'no producer' for a file that was never read"
		exit 2
	fi
	if [ -z "$_ws_job" ]; then cat "$_ws_f"; return 0; fi
	awk -v job="$_ws_job" '
		$0 ~ "^  " job ":[[:space:]]*$" { inb = 1; print; next }
		inb && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inb = 0 }
		inb { print }
	' "$_ws_f"
}

# workflow_superseded <file[#job]> <report-path> — 0 when every reference to <report-path> in
# that workflow section comes BEFORE the run-tool-plan invocation.
#
# This is the ONLY safe form of a runner/workflow duplication, and it is safe for a proven
# reason: scripts/run-tool-plan.sh removes a tool's declared report immediately before
# invoking its runner (B17) and classifies status only from artifacts produced by that
# invocation. So a workflow step that writes the same path EARLIER is redundant work whose
# output is discarded, while a step that writes it LATER overwrites the runner's evidence —
# a genuine stale-report hazard, and still a failure.
workflow_superseded() {
	_wsp_e="$1"; _wsp_path="$2"
	_wsp_job=""; _wsp_f="$_wsp_e"
	case "$_wsp_e" in *"#"*) _wsp_job="${_wsp_e#*#}"; _wsp_f="${_wsp_e%%#*}" ;; esac
	_wsp_sec=$(workflow_section "$_wsp_f" "$_wsp_job")
	_wsp_plan=$(printf '%s\n' "$_wsp_sec" | grep -n 'run-tool-plan\.sh' | head -n1 | cut -d: -f1)
	# No run-tool-plan in this section: the runner is never executed here, so the workflow
	# step is the SOLE producer at this stage and there is nothing to race.
	[ -n "$_wsp_plan" ] || return 0
	_wsp_last=$(printf '%s\n' "$_wsp_sec" | grep -Fn "$_wsp_path" | tail -n1 | cut -d: -f1)
	[ -n "$_wsp_last" ] || return 1
	[ "$_wsp_last" -lt "$_wsp_plan" ]
}

# workflow_producers <report-path> <stage> <variant> — echo the workflow (file[#job]) entries
# of THIS variant, mapped to THIS stage, that reference this exact report path. Referencing the
# path is what makes a step a producer for it.
workflow_producers() {
	_wp_path="$1"; _wp_stage="$2"; _wp_variant="$3"
	printf '%s\n' "$WORKFLOW_MAP" | while IFS= read -r _entry; do
		[ -n "$_entry" ] || continue
		_ev=$(printf '%s' "$_entry" | cut -d'|' -f1)
		_es=$(printf '%s' "$_entry" | cut -d'|' -f2)
		_ef=$(printf '%s' "$_entry" | cut -d'|' -f3)
		[ "$_ev" = "$_wp_variant" ] && [ "$_es" = "$_wp_stage" ] || continue
		_ejob=""
		case "$_ef" in *"#"*) _ejob="${_ef#*#}"; _ef="${_ef%%#*}" ;; esac
		if workflow_section "$_ef" "$_ejob" | grep -Fq "$_wp_path"; then
			printf '%s%s\n' "$_ef" "${_ejob:+#$_ejob}"
		fi
	done
	return 0
}

for _p in $PROFILES; do
	_eff=$(sh "$SCRIPT_DIR/resolve-effective-profile.sh" --profile "$_p" ${TARGET:+--target "$TARGET"} --format json 2>/dev/null) || {
		fail "$_p: the effective profile could not be resolved"
		continue
	}
	for _s in $STAGES; do
	for _v in $(variants_for_stage "$_s"); do
		[ "$FORMAT" = text ] && printf '\n== profile=%s stage=%s variant=%s ==\n' "$_p" "$_s" "$_v"
		_required=$(printf '%s' "$_eff" | jq -r --arg s "$_s" '
			.tools | to_entries
			| map(select((.value.policy // "") == "required"))
			| map(select(.value.execution[$s] == true))
			| map(select((.value.applicability // "unknown") != "not-applicable"))
			| .[].key')
		[ -n "$_required" ] || { pass "$_p/$_s: no required tools selected"; continue; }
		for _k in $_required; do
			_runner=$(printf '%s' "$_eff" | jq -r --arg k "$_k" '.tools[$k].runner // ""')
			_report=$(printf '%s' "$_eff" | jq -r --arg k "$_k" '.tools[$k].report // ""')
			_wfp=$(workflow_producers "$_report" "$_s" "$_v")
			_wfn=0
			[ -n "$_report" ] && _wfn=$(printf '%s' "$_wfp" | grep -c . || true)
			case "$_wfn" in '' | *[!0-9]*) _wfn=0 ;; esac

			if [ -z "$_report" ]; then
				# A setup-only tool (no report) is satisfied by its runner alone.
				if [ -n "$_runner" ] && [ -f "$REPO_ROOT/$_runner" ]; then
					pass "$_p/$_s/$_v/$_k: runner-only tool ($_runner), no report contract"
				elif [ -z "$_runner" ]; then
					pass "$_p/$_s/$_v/$_k: declares neither runner nor report (nothing to enforce)"
				else
					fail "$_p/$_s/$_v/$_k: declares runner '$_runner' which does not exist"
				fi
				continue
			fi

			if [ -n "$_runner" ]; then
				if [ ! -f "$REPO_ROOT/$_runner" ]; then
					fail "$_p/$_s/$_v/$_k: declared runner '$_runner' does not exist (no producer for $_report)"
					continue
				fi
				if [ "$_wfn" -gt 0 ]; then
					# codeql is the DOCUMENTED exception, and it is now written as one: the
					# workflow uploads SARIF through the CodeQL action into a separate
					# directory and the runner EXPORTS it to the report path, so both mention
					# the path without racing.
					#
					# The previous condition was "the runner file mentions the report path" —
					# true of EVERY runner that writes its own output, so it absolved almost
					# every ambiguous pairing and turned the stale-report check into a no-op.
					# (`printf '%s' "$_wfp" | grep -q .` was also always true here: _wfn > 0.)
					if [ "$_k" = "codeql" ] && grep -Fq "$_report" "$REPO_ROOT/$_runner" 2>/dev/null; then
						pass "$_p/$_s/$_v/$_k: producer=runner:$_runner (exports into $_report)"
					elif _all_before=1; for _wf1 in $_wfp; do
							workflow_superseded "$_wf1" "$_report" || _all_before=0
						done; [ "$_all_before" -eq 1 ]; then
						# Redundant, not racy: every workflow reference precedes run-tool-plan,
						# which deletes the report before the runner writes it.
						pass "$_p/$_s/$_v/$_k: producer=runner:$_runner (workflow step(s) [$(printf '%s' "$_wfp" | tr '\n' ' ')] write $_report BEFORE run-tool-plan removes it — redundant work, superseded)"
					else
						fail "$_p/$_s/$_v/$_k: AMBIGUOUS producer — runner '$_runner' AND workflow step(s) [$(printf '%s' "$_wfp" | tr '\n' ' ')] both target $_report; run-tool-plan deletes the workflow's report before the runner runs"
					fi
					continue
				fi
				pass "$_p/$_s/$_v/$_k: producer=runner:$_runner -> $_report"
				continue
			fi

			if [ "$_wfn" -eq 0 ]; then
				fail "$_p/$_s/$_v/$_k: NO PRODUCER for required report $_report — a fresh install exits 3 for a wiring gap, not for findings"
				continue
			fi
			pass "$_p/$_s/$_v/$_k: producer=workflow:$(printf '%s' "$_wfp" | tr '\n' ' ') -> $_report"
			ROWS="$ROWS$_p	$_s	$_v	$_k	$_report
"
		done
	done
	done
done

if [ "$FORMAT" = json ]; then
	printf '{"failures":%d}\n' "$FAILURES"
	[ "$FAILURES" -eq 0 ] && exit 0 || exit 1
fi

printf '\n----\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'verify-producer-coverage: every required tool has exactly one producer\n'
	exit 0
fi
printf 'verify-producer-coverage: %d required tool(s) have no (or an ambiguous) producer; fail closed\n' "$FAILURES"
exit 1
