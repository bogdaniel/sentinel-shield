#!/bin/sh
# Sentinel Shield — production-readiness orchestrator + independent evidence-review harness
# (MACRO-TASK 5).
#
# One fail-closed tool with four modes:
#
#   run              Orchestrate the local production-readiness gates (shell syntax, shellcheck,
#                    actionlint, schema validation, self-tests, prod tests, adopter scenarios,
#                    consumer validation, security acceptance, release-authorization suites,
#                    archive/artifact adversarial suites, evidence+manifest reproducibility),
#                    then emit a production-readiness-report (.json conforming to
#                    schemas/production-readiness-report.schema.json + a human .md). Each gate is
#                    bounded; a hung gate yields a DISTINCT timeout status and exit code 4.
#
#   review           INDEPENDENT review of a production-readiness-report treated as UNTRUSTED
#                    evidence. It re-derives EVERY trust decision from the caller's own
#                    --expected-* expectations and FAILS CLOSED when any field is missing,
#                    malformed, stale, ambiguous, or does not match: source commit, changed-file
#                    inventory, test applicability, skipped required jobs, workflow identity,
#                    default branch, event type, artifact ownership, artifact content, report
#                    freshness, scanner health, compatibility coverage, adopter score, release
#                    limitations, and tag-target policy. Two profiles: 'ci-gate' (identity +
#                    gates + freshness + tag policy + changed files + engine-only title) and
#                    'release' (everything, default).
#
#   version-decision Recommend v2.0.0-beta.3 (material blockers), v2.0.0-rc.1 (behavior complete,
#                    soak/evidence remains), or v2.0.0 (all engine-only GA criteria pass) from a
#                    report. Advisory; --strict forces beta.3 unless 'review' passes first.
#
#   emit-template    Write integration/production-readiness-report.{json,md} as a structure-only
#                    skeleton (real values filled at integration time). Schema-valid; 'unknown'
#                    source identity never satisfies review.
#
# Engine-only scope: this harness NEVER claims Laravel/Symfony/framework live-validation. The
# report title MUST state engine-only until the framework tracks are independently validated.
#
# Exit: 0 ok/READY/verified; 1 NOT-READY / rejected; 2 invalid invocation / malformed input /
#       refused destructive op; 3 required tool unavailable; 4 bounded operation timed out.
#
# Redaction: the report carries NO secrets, tokens, signing-key paths, or repo-local absolute
# paths — gate detail lines are the gate id + status only.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$SCRIPT_DIR/lib/release-authz.sh"

BOUND_SECS="${PR_BOUND_SECS:-900}"

usage() {
	cat <<'EOF'
Usage:
  run-production-readiness.sh run [--plan <file>] [--facts <file>] [--changed-files <file>] \
      [--source-commit <40hex>] [--workflow <name>] [--event <push|workflow_dispatch|pull_request>] \
      [--default-branch <name>] [--repo-root <dir>] [--base <ref>] \
      [--out-json <file>] [--out-md <file>]

  run-production-readiness.sh review --report <file> --expected-commit <40hex> --expected-workflow <name> \
      [--expected-default-branch <name>] [--expected-event <push|workflow_dispatch>] \
      [--profile ci-gate|release] [--min-adopter-score <n>] [--max-age-seconds <n>] [--now <ISO8601Z>]

  run-production-readiness.sh version-decision --report <file> [--strict --expected-commit <40hex> --expected-workflow <name>]

  run-production-readiness.sh emit-template [--out-json <file>] [--out-md <file>]

Independent review treats the report as UNTRUSTED evidence and fails closed on any mismatch.
EOF
}

MODE="${1:-}"
[ -n "$MODE" ] || { log_error "a mode is required"; usage >&2; exit 2; }
case "$MODE" in
	run | review | version-decision | emit-template) ;;
	-h | --help) usage; exit 0 ;;
	*) log_error "unknown mode: $MODE"; usage >&2; exit 2 ;;
esac
shift

# Refuse destructive tag/release operations in EVERY mode (defence in depth; this tool never
# publishes, but an argv carrying such a flag is a red flag we reject up-front).
ra_guard_destructive "$@" || exit 2

command_exists jq || { log_error "jq is required but was not found"; exit 3; }

# --- flag parsing (union across modes) ---------------------------------------
PLAN=""; FACTS=""; CHANGED_FILES=""; SOURCE_COMMIT=""; WORKFLOW=""; EVENT=""
DEFAULT_BRANCH=""; RR=""; BASE=""; OUT_JSON=""; OUT_MD=""
REPORT=""; EXP_COMMIT=""; EXP_WORKFLOW=""; EXP_BRANCH=""; EXP_EVENT=""
PROFILE="release"; MIN_ADOPTER="90"; MAX_AGE="86400"; NOW=""; STRICT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--plan) PLAN="${2:?}"; shift 2 ;;
		--facts) FACTS="${2:?}"; shift 2 ;;
		--changed-files) CHANGED_FILES="${2:?}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?}"; shift 2 ;;
		--workflow) WORKFLOW="${2:?}"; shift 2 ;;
		--event) EVENT="${2:?}"; shift 2 ;;
		--default-branch) DEFAULT_BRANCH="${2:?}"; shift 2 ;;
		--repo-root) RR="${2:?}"; shift 2 ;;
		--base) BASE="${2:?}"; shift 2 ;;
		--out-json) OUT_JSON="${2:?}"; shift 2 ;;
		--out-md) OUT_MD="${2:?}"; shift 2 ;;
		--report) REPORT="${2:?}"; shift 2 ;;
		--expected-commit) EXP_COMMIT="${2:?}"; shift 2 ;;
		--expected-workflow) EXP_WORKFLOW="${2:?}"; shift 2 ;;
		--expected-default-branch) EXP_BRANCH="${2:?}"; shift 2 ;;
		--expected-event) EXP_EVENT="${2:?}"; shift 2 ;;
		--profile) PROFILE="${2:?}"; shift 2 ;;
		--min-adopter-score) MIN_ADOPTER="${2:?}"; shift 2 ;;
		--max-age-seconds) MAX_AGE="${2:?}"; shift 2 ;;
		--now) NOW="${2:?}"; shift 2 ;;
		--strict) STRICT=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

# ============================================================================
# shared helpers
# ============================================================================

# pr_now_iso — current instant as ISO-8601 UTC, overridable for deterministic tests via
# --now, then SENTINEL_SHIELD_REVIEW_NOW, then SENTINEL_SHIELD_RELEASE_NOW (date-only is
# widened to T00:00:00Z), then date(1).
pr_now_iso() {
	if [ -n "$NOW" ]; then printf '%s' "$NOW"; return 0; fi
	if [ -n "${SENTINEL_SHIELD_REVIEW_NOW:-}" ]; then printf '%s' "$SENTINEL_SHIELD_REVIEW_NOW"; return 0; fi
	if [ -n "${SENTINEL_SHIELD_RELEASE_NOW:-}" ]; then
		case "$SENTINEL_SHIELD_RELEASE_NOW" in
			[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) printf '%sT00:00:00Z' "$SENTINEL_SHIELD_RELEASE_NOW" ;;
			*) printf '%s' "$SENTINEL_SHIELD_RELEASE_NOW" ;;
		esac
		return 0
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ
}

# pr_iso_to_epoch <YYYY-MM-DDTHH:MM:SSZ> — print Unix epoch seconds using a portable
# civil-to-days computation in awk (no reliance on GNU/BSD date extensions). Returns 1 on a
# malformed timestamp.
pr_iso_to_epoch() {
	case "${1:-}" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
		*) return 1 ;;
	esac
	_pe_y=${1%%-*}
	_pe_r=${1#*-}
	_pe_mo=${_pe_r%%-*}
	_pe_r=${_pe_r#*-}
	_pe_d=${_pe_r%%T*}
	_pe_t=${_pe_r#*T}
	_pe_hh=${_pe_t%%:*}
	_pe_t=${_pe_t#*:}
	_pe_mi=${_pe_t%%:*}
	_pe_ss=${_pe_t#*:}
	_pe_ss=${_pe_ss%Z}
	awk -v y="$_pe_y" -v m="$_pe_mo" -v d="$_pe_d" -v hh="$_pe_hh" -v mi="$_pe_mi" -v ss="$_pe_ss" 'BEGIN{
		y+=0; m+=0; d+=0; hh+=0; mi+=0; ss+=0;
		if (m <= 2) y -= 1;
		era = (y >= 0 ? y : y - 399);
		era = int(era / 400);
		yoe = y - era * 400;
		mm = (m > 2 ? m - 3 : m + 9);
		doy = int((153 * mm + 2) / 5) + d - 1;
		doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy;
		days = era * 146097 + doe - 719468;
		printf "%d\n", days * 86400 + hh * 3600 + mi * 60 + ss;
	}'
}

# pr_validate_report <path> — fail-closed STRUCTURAL conformance to
# schemas/production-readiness-report.schema.json (the parts jq can express). 0 valid,
# 2 malformed/non-conformant.
pr_validate_report() {
	ra_json_ok "$1" || { log_error "pr_validate_report: '${1:-}' missing/empty/not JSON (fail closed)"; return 2; }
	jq -e '
		def isodt: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
		(.schema_version == "1")
		and (.kind == "production-readiness-report")
		and (.generated_at | isodt)
		and (.title | type == "string" and test("engine-only"))
		and (.release_scope | . == "engine-only" or . == "framework-validated" or . == "full-platform")
		and (.source | type == "object")
		and (.source.commit | type == "string" and test("^([0-9a-f]{40}|unknown)$"))
		and (.source.default_branch | type == "string" and (length > 0))
		and (.source.event | . == "push" or . == "workflow_dispatch" or . == "pull_request" or . == "unknown")
		and (.source.workflow | type == "string" and (length > 0))
		and (.gates | type == "array")
		and (.gates | all((.id | type == "string" and (length > 0))
			and (.status | . == "pass" or . == "fail" or . == "skipped" or . == "timeout")
			and (.required | type == "boolean")))
		and (.summary | type == "object")
		and (.summary.total | type == "number")
		and (.summary.passed | type == "number")
		and (.summary.failed | type == "number")
		and (.summary.skipped | type == "number")
		and (.summary.timed_out | type == "number")
		and (.version_recommendation | type == "object")
		and (.version_recommendation.version | . == "v2.0.0-beta.3" or . == "v2.0.0-rc.1" or . == "v2.0.0")
		and (.version_recommendation.rationale | type == "string" and (length > 0))
	' "$1" >/dev/null 2>&1 || { log_error "pr_validate_report: '$1' does not conform to production-readiness-report.schema.json"; return 2; }
	return 0
}

# pr_decide_version <report> — emit the recommendation object {version,rationale,blockers[]}
# purely from the report's fields (which are untrusted; version-decision --strict gates on
# 'review' first). Pure jq: no shell branching on evidence.
pr_decide_version() {
	jq '
		. as $r
		| ([ $r.gates[]? | select(.required == true and .status != "pass") | ("gate:" + .id) ]) as $gatefail
		| ([
			(if ($r.security.accepted // false) != true then "security-acceptance-not-green" else empty end),
			(if ($r.compatibility.complete // false) != true then "compatibility-incomplete" else empty end),
			(if (($r.compatibility.missing // []) | length) > 0 then "compatibility-missing" else empty end),
			(if ($r.adopter.result // "unknown") != "pass" then "adopter-not-pass" else empty end),
			(if ($r.limitations.documented // false) != true then "limitations-undeclared" else empty end),
			(if ($r.release_scope // "") != "engine-only" then "scope-not-engine-only" else empty end)
		  ]) as $matbase
		| ($gatefail + $matbase) as $mat
		| if ($mat | length) > 0 then
			{ version: "v2.0.0-beta.3",
			  rationale: ("Material blockers remain — engine-only GA/RC criteria not met: " + ($mat | join(", "))),
			  blockers: $mat }
		  else
			([
				(if ($r.evidence.default_branch_ci // false) != true then "default-branch-ci-evidence" else empty end),
				(if ($r.evidence.evidence_complete // false) != true then "release-evidence-bundle" else empty end),
				(if ($r.evidence.soak_complete // false) != true then "soak-window" else empty end)
			]) as $remain
			| if ($remain | length) == 0 then
				{ version: "v2.0.0",
				  rationale: "All engine-only GA criteria pass (behavior complete, evidence complete, soak elapsed). Engine-only scope; framework tracks are validated independently.",
				  blockers: [] }
			  else
				{ version: "v2.0.0-rc.1",
				  rationale: ("Behavior complete for engine-only scope; soak/evidence remains: " + ($remain | join(", "))),
				  blockers: $remain }
			  end
		  end
	' "$1"
}

# ============================================================================
# mode: emit-template — structure-only skeleton
# ============================================================================
if [ "$MODE" = emit-template ]; then
	[ -n "$OUT_JSON" ] || OUT_JSON="$REPO_ROOT/integration/production-readiness-report.json"
	[ -n "$OUT_MD" ] || OUT_MD="$REPO_ROOT/integration/production-readiness-report.md"
	_gen=$(pr_now_iso)
	TEMPLATE=$(jq -n --arg at "$_gen" '
		{
			schema_version: "1",
			kind: "production-readiness-report",
			generated_at: $at,
			title: "Sentinel Shield production-readiness — engine-only (framework tracks not independently validated)",
			release_scope: "engine-only",
			source: { commit: "unknown", default_branch: "master", event: "unknown", workflow: "ci-production-readiness" },
			changed_files: [],
			gates: [],
			summary: { total: 0, passed: 0, failed: 0, skipped: 0, timed_out: 0 },
			compatibility: { complete: false, covered: [], missing: [] },
			adopter: { result: "unknown", score: 0 },
			security: { accepted: false },
			scanners: [],
			artifacts: [],
			limitations: { documented: false, framework_live_validation: false },
			evidence: { default_branch_ci: false, evidence_complete: false, soak_complete: false },
			tag_policy: { destructive_ops_performed: false, tag_targets_source_commit: false },
			version_recommendation: {
				version: "v2.0.0-beta.3",
				rationale: "Structure-only template — real values are filled at integration time by run-production-readiness.sh run.",
				blockers: ["template-not-yet-populated"]
			}
		}')
	_tmp=$(mktemp 2>/dev/null || mktemp -t sspr); printf '%s\n' "$TEMPLATE" > "$_tmp"
	pr_validate_report "$_tmp" || { rm -f "$_tmp"; log_error "emit-template: skeleton failed self-validation (fail closed)"; exit 2; }
	rm -f "$_tmp"
	ensure_dir "$(dirname -- "$OUT_JSON")"
	printf '%s\n' "$TEMPLATE" > "$OUT_JSON"
	ensure_dir "$(dirname -- "$OUT_MD")"
	{
		printf '# Sentinel Shield — Production-Readiness Report (STRUCTURE-ONLY TEMPLATE)\n\n'
		printf '**Engine-only scope.** Framework live-validation (Laravel/Symfony) is NOT claimed here and\n'
		printf 'remains independently validated on its own track. This file is a structure-only skeleton;\n'
		printf 'real values are filled at integration time by `run-production-readiness.sh run` and then\n'
		printf 'independently re-verified by `run-production-readiness.sh review` (UNTRUSTED-evidence mode).\n\n'
		printf -- '- Generated: `%s`\n' "$_gen"
		printf -- '- Source commit: `unknown` (placeholder — never satisfies review)\n'
		printf -- '- Recommendation: `v2.0.0-beta.3` (template not yet populated)\n\n'
		printf 'See `schemas/production-readiness-report.schema.json` for the full field contract and\n'
		printf '`docs/production-release-runbook.md` for how this report gates the release.\n'
	} > "$OUT_MD"
	log_info "emit-template: wrote $OUT_JSON and $OUT_MD (structure-only)"
	exit 0
fi

# ============================================================================
# mode: version-decision
# ============================================================================
if [ "$MODE" = version-decision ]; then
	[ -n "$REPORT" ] && [ -f "$REPORT" ] || { log_error "version-decision: --report <file> is required"; exit 2; }
	pr_validate_report "$REPORT" || exit 2
	if [ "$STRICT" = 1 ]; then
		# In strict mode a recommendation above beta.3 is only permitted when independent review
		# passes; otherwise we cannot trust the evidence and fall back to beta.3.
		[ -n "$EXP_COMMIT" ] && [ -n "$EXP_WORKFLOW" ] || { log_error "version-decision --strict requires --expected-commit and --expected-workflow"; exit 2; }
		_self="$SCRIPT_DIR/$(basename -- "$0")"
		_strict_now=$(pr_now_iso)
		if ! sh "$_self" review --report "$REPORT" \
			--expected-commit "$EXP_COMMIT" --expected-workflow "$EXP_WORKFLOW" \
			--expected-default-branch "${EXP_BRANCH:-master}" \
			--now "$_strict_now" --max-age-seconds "$MAX_AGE" --min-adopter-score "$MIN_ADOPTER" >/dev/null 2>&1; then
			jq -n '{version:"v2.0.0-beta.3",rationale:"Independent review did not pass — evidence is untrusted; recommending the safe floor.",blockers:["review-not-passed"]}'
			printf 'version-decision: v2.0.0-beta.3 (review not passed — safe floor)\n' >&2
			exit 0
		fi
	fi
	REC=$(pr_decide_version "$REPORT")
	printf '%s\n' "$REC"
	_v=$(printf '%s' "$REC" | jq -r '.version')
	_ra=$(printf '%s' "$REC" | jq -r '.rationale')
	printf 'version-decision: %s — %s\n' "$_v" "$_ra" >&2
	exit 0
fi

# ============================================================================
# mode: review — INDEPENDENT review of an UNTRUSTED report
# ============================================================================
if [ "$MODE" = review ]; then
	[ -n "$REPORT" ] && [ -f "$REPORT" ] || { log_error "review: --report <file> is required"; exit 2; }
	case "$PROFILE" in ci-gate | release) ;; *) log_error "review: --profile must be ci-gate|release"; exit 2 ;; esac
	ra_is_hex40 "$EXP_COMMIT" || { log_error "review: --expected-commit must be a 40-hex SHA (fail closed)"; exit 2; }
	[ -n "$EXP_WORKFLOW" ] || { log_error "review: --expected-workflow is required (fail closed)"; exit 2; }
	[ -n "$EXP_BRANCH" ] || EXP_BRANCH="master"
	case "$MAX_AGE" in '' | *[!0-9]*) log_error "review: --max-age-seconds must be a non-negative integer"; exit 2 ;; esac
	EXP_COMMIT=$(printf '%s' "$EXP_COMMIT" | tr 'A-F' 'a-f')

	# Structural conformance FIRST — a malformed report is unreviewable (fail closed).
	pr_validate_report "$REPORT" || exit 2

	_fails=0
	_pass() { printf '  PASS  %s\n' "$*"; }
	_fail() { _fails=$((_fails + 1)); printf '  FAIL  %s\n' "$*"; }

	printf 'Sentinel Shield — INDEPENDENT production-readiness review (profile=%s; evidence treated as UNTRUSTED)\n\n' "$PROFILE"

	# (1) SOURCE COMMIT — must equal the caller's independent expectation; 'unknown' never passes.
	_rc_commit=$(jq -r '.source.commit' "$REPORT" | tr 'A-F' 'a-f')
	if [ "$_rc_commit" = unknown ]; then _fail "SOURCE_COMMIT_UNKNOWN — report source.commit is the 'unknown' placeholder; not a proven commit"
	elif [ "$_rc_commit" = "$EXP_COMMIT" ]; then _pass "source commit matches expected ($EXP_COMMIT)"
	else _fail "SOURCE_COMMIT_MISMATCH — report source.commit=$_rc_commit expected=$EXP_COMMIT"; fi

	# (2) WORKFLOW IDENTITY — the report must have been produced by the expected workflow.
	_rc_wf=$(jq -r '.source.workflow' "$REPORT")
	if [ "$_rc_wf" = "$EXP_WORKFLOW" ]; then _pass "workflow identity matches expected ($EXP_WORKFLOW)"
	else _fail "WORKFLOW_IDENTITY_MISMATCH — report source.workflow='$_rc_wf' expected='$EXP_WORKFLOW'"; fi

	# (3) DEFAULT BRANCH — the source must be the default branch (not a topic branch).
	_rc_br=$(jq -r '.source.default_branch' "$REPORT")
	if [ "$_rc_br" = "$EXP_BRANCH" ]; then _pass "default branch matches expected ($EXP_BRANCH)"
	else _fail "DEFAULT_BRANCH_MISMATCH — report source.default_branch='$_rc_br' expected='$EXP_BRANCH'"; fi

	# (4) EVENT TYPE — only push/workflow_dispatch is release proof; pull_request/unknown never is.
	_rc_ev=$(jq -r '.source.event' "$REPORT")
	if [ -n "$EXP_EVENT" ]; then
		if [ "$_rc_ev" = "$EXP_EVENT" ]; then _pass "event type matches expected ($EXP_EVENT)"
		else _fail "EVENT_MISMATCH — report source.event='$_rc_ev' expected='$EXP_EVENT'"; fi
	else
		case "$_rc_ev" in
			push | workflow_dispatch) _pass "event type is release proof ($_rc_ev)" ;;
			*) _fail "EVENT_NOT_RELEASE_PROOF — event='$_rc_ev' is not a default-branch push/workflow_dispatch" ;;
		esac
	fi

	# (5) REPORT FRESHNESS — must be parseable, not future-dated, and within --max-age-seconds.
	_gen=$(jq -r '.generated_at' "$REPORT")
	_gen_epoch=$(pr_iso_to_epoch "$_gen" 2>/dev/null) || _gen_epoch=""
	_now_iso=$(pr_now_iso)
	_now_epoch=$(pr_iso_to_epoch "$_now_iso" 2>/dev/null) || _now_epoch=""
	if [ -z "$_gen_epoch" ] || [ -z "$_now_epoch" ]; then
		_fail "FRESHNESS_UNVERIFIABLE — could not parse generated_at ('$_gen') or now ('$_now_iso') (fail closed)"
	elif [ "$_gen_epoch" -gt "$_now_epoch" ]; then
		_fail "REPORT_FUTURE_DATED — generated_at ($_gen) is after now ($_now_iso)"
	else
		_age=$((_now_epoch - _gen_epoch))
		if [ "$_age" -le "$MAX_AGE" ]; then _pass "report is fresh (age ${_age}s <= ${MAX_AGE}s)"
		else _fail "REPORT_STALE — age ${_age}s exceeds max ${MAX_AGE}s (generated_at=$_gen)"; fi
	fi

	# (6) CHANGED-FILE INVENTORY / TEST APPLICABILITY — the report must enumerate what changed.
	_cf=$(jq -r '(.changed_files // []) | length' "$REPORT")
	if [ "$_cf" -ge 1 ]; then _pass "changed-file inventory present ($_cf file(s))"
	else _fail "CHANGED_FILES_MISSING — empty changed-file inventory; test applicability cannot be established"; fi

	# (7) SUMMARY CONSISTENCY — recomputed gate counts must match the declared summary (no ambiguity).
	_ok_sum=$(jq -e '
		def cnt($s): [ .gates[] | select(.status == $s) ] | length;
		(.summary.total == (.gates | length))
		and (.summary.passed == cnt("pass"))
		and (.summary.failed == cnt("fail"))
		and (.summary.skipped == cnt("skipped"))
		and (.summary.timed_out == cnt("timeout"))
	' "$REPORT" >/dev/null 2>&1 && printf 'yes' || printf 'no')
	if [ "$_ok_sum" = yes ]; then _pass "summary counts are consistent with the gate list"
	else _fail "SUMMARY_INCONSISTENT — declared summary does not match recomputed gate counts (ambiguous evidence)"; fi

	# (8) SKIPPED REQUIRED JOBS — a required gate that did not run cannot be trusted.
	_skipreq=$(jq -r '[ .gates[] | select(.required == true and .status == "skipped") | .id ] | join(",")' "$REPORT")
	if [ -z "$_skipreq" ]; then _pass "no required gate was skipped"
	else _fail "REQUIRED_GATE_SKIPPED — required gate(s) did not run: $_skipreq"; fi

	# (9) GATE RESULTS — no required gate may fail or time out.
	_badgates=$(jq -r '[ .gates[] | select(.required == true and (.status == "fail" or .status == "timeout")) | (.id + ":" + .status) ] | join(",")' "$REPORT")
	if [ -z "$_badgates" ]; then _pass "all required gates passed"
	else _fail "REQUIRED_GATE_FAILED — $_badgates"; fi

	# (10) TAG-TARGET POLICY — no destructive tag/release operation may have been performed.
	_destr=$(jq -r '(.tag_policy.destructive_ops_performed // false) | tostring' "$REPORT")
	if [ "$_destr" = false ]; then _pass "tag-target policy: no destructive tag/release operation performed"
	else _fail "DESTRUCTIVE_TAG_OP — tag_policy.destructive_ops_performed is true (Sentinel Shield never deletes/moves a tag)"; fi

	# (11) TITLE — must state engine-only until framework tracks are independently validated.
	_title=$(jq -r '.title' "$REPORT")
	case "$_title" in
		*engine-only*) _pass "title states engine-only scope" ;;
		*) _fail "TITLE_NOT_ENGINE_ONLY — the report title must state engine-only until framework tracks are independently validated" ;;
	esac

	# ---- release-profile checks (skipped in ci-gate, which only proves what CI can prove) ----
	if [ "$PROFILE" = release ]; then
		# (12) SCANNER HEALTH — no scanner-error/parser-error (unparseable output is never clean).
		_badscan=$(jq -r '[ .scanners[]? | select(.health == "scanner-error" or .health == "parser-error") | .tool ] | join(",")' "$REPORT")
		_nscan=$(jq -r '(.scanners // []) | length' "$REPORT")
		if [ "$_nscan" -lt 1 ]; then _fail "SCANNER_EVIDENCE_MISSING — release profile requires scanner health evidence"
		elif [ -z "$_badscan" ]; then _pass "scanner health is clean ($_nscan scanner(s), none unhealthy)"
		else _fail "SCANNER_UNHEALTHY — scanner(s) reported an error state: $_badscan"; fi

		# (13) COMPATIBILITY COVERAGE — matrix complete and nothing missing.
		_compat_ok=$(jq -e '(.compatibility.complete == true) and (((.compatibility.missing // []) | length) == 0)' "$REPORT" >/dev/null 2>&1 && printf 'yes' || printf 'no')
		if [ "$_compat_ok" = yes ]; then _pass "compatibility matrix is complete (no missing coverage)"
		else _fail "COMPAT_INCOMPLETE — compatibility matrix is incomplete or has missing coverage"; fi

		# (14) ADOPTER SCORE — scorecard passed and score meets the floor.
		_ado_ok=$(jq -e --argjson min "$MIN_ADOPTER" '(.adopter.result == "pass") and ((.adopter.score // 0) >= $min)' "$REPORT" >/dev/null 2>&1 && printf 'yes' || printf 'no')
		if [ "$_ado_ok" = yes ]; then _pass "adopter scorecard passed (score >= $MIN_ADOPTER)"
		else _fail "ADOPTER_INSUFFICIENT — adopter scorecard not pass or score below $MIN_ADOPTER"; fi

		# (15) SECURITY ACCEPTANCE.
		_sec=$(jq -r '(.security.accepted // false) | tostring' "$REPORT")
		if [ "$_sec" = true ]; then _pass "production security acceptance is green"
		else _fail "SECURITY_NOT_ACCEPTED — production security acceptance is not green"; fi

		# (16) RELEASE LIMITATIONS — documented, and framework live-validation NOT claimed.
		_lim_ok=$(jq -e '(.limitations.documented == true) and ((.limitations.framework_live_validation // false) == false)' "$REPORT" >/dev/null 2>&1 && printf 'yes' || printf 'no')
		if [ "$_lim_ok" = yes ]; then _pass "published limitations documented; framework live-validation not claimed"
		else _fail "LIMITATIONS_UNDECLARED — limitations not documented, or framework live-validation is (wrongly) claimed"; fi

		# (17) ARTIFACT OWNERSHIP + CONTENT — every listed artifact must be owned + content-verified.
		_bad_art=$(jq -r '[ .artifacts[]? | select((.ownership_ok != true) or ((.content_verified // false) != true) or ((.sha256 // "") | test("^[0-9a-f]{64}$") | not)) | .name ] | join(",")' "$REPORT")
		if [ -z "$_bad_art" ]; then _pass "all listed artifacts are owned + content-verified with a 64-hex digest"
		else _fail "ARTIFACT_UNVERIFIED — artifact(s) not owned/content-verified/digested: $_bad_art"; fi
	fi

	printf '\n----\n'
	if [ "$_fails" -eq 0 ]; then
		printf 'production-readiness review: VERIFIED (profile=%s; %s)\n' "$PROFILE" "$EXP_COMMIT"
		exit 0
	fi
	printf 'production-readiness review: REJECTED (%d check(s) failed; profile=%s); fail closed\n' "$_fails" "$PROFILE"
	exit 1
fi

# ============================================================================
# mode: run — orchestrate local gates and emit the report
# ============================================================================
# run reaches here. Build the gate plan, execute each bounded gate, assemble the report.

[ -n "$RR" ] || RR="$REPO_ROOT"
[ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="master"
[ -n "$WORKFLOW" ] || WORKFLOW="ci-production-readiness"
[ -n "$EVENT" ] || EVENT="unknown"
if [ -n "$SOURCE_COMMIT" ]; then
	ra_is_hex40 "$SOURCE_COMMIT" || { log_error "run: --source-commit must be a 40-hex SHA"; exit 2; }
	SOURCE_COMMIT=$(printf '%s' "$SOURCE_COMMIT" | tr 'A-F' 'a-f')
else
	SOURCE_COMMIT="unknown"
fi

# Default plan: newline-delimited records "id|required|skip_if_missing|cmd". A default plan is
# used when --plan is not supplied. skip_if_missing names a tool whose absence yields 'skipped'
# instead of a failing gate.
default_plan_json() {
	jq -n '[
		{ id: "shell-syntax", required: true, skip_if_missing: "",
		  cmd: "for f in scripts/*.sh scripts/lib/*.sh scripts/audits/*.sh scripts/collectors/*.sh scripts/runners/*.sh tests/prod/*.sh; do sh -n \"$f\" || exit 1; done" },
		{ id: "shellcheck", required: true, skip_if_missing: "shellcheck",
		  cmd: "shellcheck -s sh -S error scripts/run-production-readiness.sh" },
		{ id: "actionlint", required: true, skip_if_missing: "actionlint",
		  cmd: "actionlint .github/workflows/ci-production-readiness.yml" },
		{ id: "schema-validation", required: true, skip_if_missing: "",
		  cmd: "for s in schemas/*.json; do jq -e . \"$s\" >/dev/null || exit 1; done" },
		{ id: "self-test-production-readiness", required: true, skip_if_missing: "",
		  cmd: "sh scripts/self-test.sh production-readiness" },
		{ id: "adopter-scenarios", required: true, skip_if_missing: "",
		  cmd: "sh tests/adopter/adopter-scenarios.sh" },
		{ id: "release-authorization-suite", required: true, skip_if_missing: "",
		  cmd: "sh tests/prod/262-production-release.sh" },
		{ id: "self-test-all", required: true, skip_if_missing: "",
		  cmd: "sh scripts/self-test.sh all" }
	]'
}

if [ -n "$PLAN" ]; then
	[ -f "$PLAN" ] || { log_error "run: --plan not found: $PLAN"; exit 2; }
	ra_json_ok "$PLAN" || { log_error "run: --plan is not valid JSON"; exit 2; }
	jq -e 'type == "array" and all(.id and has("cmd") and (.required | type == "boolean"))' "$PLAN" >/dev/null 2>&1 \
		|| { log_error "run: --plan must be an array of {id, cmd, required[, skip_if_missing]}"; exit 2; }
	PLAN_JSON=$(cat "$PLAN")
else
	PLAN_JSON=$(default_plan_json)
fi

# Optional facts object (compatibility/adopter/security/scanners/artifacts/limitations/evidence/
# tag_policy) merged into the report. Fail closed on malformed facts.
FACTS_JSON='{}'
if [ -n "$FACTS" ]; then
	[ -f "$FACTS" ] || { log_error "run: --facts not found: $FACTS"; exit 2; }
	ra_json_ok "$FACTS" || { log_error "run: --facts is not valid JSON"; exit 2; }
	jq -e 'type == "object"' "$FACTS" >/dev/null 2>&1 || { log_error "run: --facts must be a JSON object"; exit 2; }
	FACTS_JSON=$(cat "$FACTS")
fi

# Changed-file inventory: explicit file wins; else derive from git; else empty.
CHANGED_JSON='[]'
if [ -n "$CHANGED_FILES" ]; then
	[ -f "$CHANGED_FILES" ] || { log_error "run: --changed-files not found: $CHANGED_FILES"; exit 2; }
	CHANGED_JSON=$(jq -R . < "$CHANGED_FILES" | jq -sc 'map(select(length > 0))')
elif [ -n "$BASE" ] && command_exists git && [ -d "$RR/.git" ]; then
	CHANGED_JSON=$(git -C "$RR" diff --name-only "$BASE"...HEAD 2>/dev/null | jq -R . | jq -sc 'map(select(length > 0))') || CHANGED_JSON='[]'
fi

# Execute the plan. Accumulate one gate object per line into a temp file.
GATES_TMP=$(mktemp 2>/dev/null || mktemp -t ssprg)
trap 'rm -f "$GATES_TMP"' EXIT INT TERM
_n=$(printf '%s' "$PLAN_JSON" | jq 'length')
_i=0
_any_timeout=0
while [ "$_i" -lt "$_n" ]; do
	_gid=$(printf '%s' "$PLAN_JSON" | jq -r ".[$_i].id")
	_greq=$(printf '%s' "$PLAN_JSON" | jq -r ".[$_i].required")
	_gskip=$(printf '%s' "$PLAN_JSON" | jq -r ".[$_i].skip_if_missing // \"\"")
	_gcmd=$(printf '%s' "$PLAN_JSON" | jq -r ".[$_i].cmd")
	_gexplicit=$(printf '%s' "$PLAN_JSON" | jq -r ".[$_i].skip // false")
	_status=""; _ec=0
	if [ "$_gexplicit" = true ] || [ -z "$_gcmd" ]; then
		_status="skipped"; _ec=0
		log_info "run: gate '$_gid' skipped (explicit)"
	elif [ -n "$_gskip" ] && ! command_exists "$_gskip"; then
		_status="skipped"; _ec=0
		log_warn "run: gate '$_gid' skipped — tool '$_gskip' not available"
	else
		log_info "run: gate '$_gid' — executing (bounded ${BOUND_SECS}s)"
		_ec=0
		( cd "$RR" && ra_bounded "$BOUND_SECS" sh -c "$_gcmd" ) >/dev/null 2>&1 || _ec=$?
		if [ "$_ec" = 124 ]; then _status="timeout"; _any_timeout=1
		elif [ "$_ec" = 0 ]; then _status="pass"
		else _status="fail"; fi
	fi
	jq -nc --arg id "$_gid" --arg st "$_status" --argjson req "$_greq" --argjson ec "$_ec" \
		'{ id:$id, status:$st, required:$req, exit_code:$ec }' >> "$GATES_TMP"
	_i=$((_i + 1))
done
GATES_JSON=$(jq -sc '.' < "$GATES_TMP")

# Summary.
SUMMARY_JSON=$(printf '%s' "$GATES_JSON" | jq -c '
	{ total: length,
	  passed: ([ .[] | select(.status == "pass") ] | length),
	  failed: ([ .[] | select(.status == "fail") ] | length),
	  skipped: ([ .[] | select(.status == "skipped") ] | length),
	  timed_out: ([ .[] | select(.status == "timeout") ] | length) }')

_gen=$(pr_now_iso)
SOURCE_JSON=$(jq -nc --arg c "$SOURCE_COMMIT" --arg br "$DEFAULT_BRANCH" --arg ev "$EVENT" --arg wf "$WORKFLOW" \
	'{ commit:$c, default_branch:$br, event:$ev, workflow:$wf }')

# Assemble the report WITHOUT the recommendation first, then derive the recommendation from it.
PROVISIONAL=$(jq -n \
	--arg at "$_gen" \
	--argjson src "$SOURCE_JSON" \
	--argjson changed "$CHANGED_JSON" \
	--argjson gates "$GATES_JSON" \
	--argjson summary "$SUMMARY_JSON" \
	--argjson facts "$FACTS_JSON" '
	{
		schema_version: "1",
		kind: "production-readiness-report",
		generated_at: $at,
		title: "Sentinel Shield production-readiness — engine-only (framework tracks not independently validated)",
		release_scope: "engine-only",
		source: $src,
		changed_files: $changed,
		gates: $gates,
		summary: $summary
	} + $facts')

_ptmp=$(mktemp 2>/dev/null || mktemp -t ssprp); printf '%s\n' "$PROVISIONAL" > "$_ptmp"
REC_JSON=$(pr_decide_version "$_ptmp")
rm -f "$_ptmp"

REPORT_JSON=$(printf '%s' "$PROVISIONAL" | jq -c --argjson rec "$REC_JSON" '. + { version_recommendation: $rec }')

# Self-validate before emitting (fail closed on a non-conforming report).
_rtmp=$(mktemp 2>/dev/null || mktemp -t ssprr); printf '%s\n' "$REPORT_JSON" > "$_rtmp"
pr_validate_report "$_rtmp" || { rm -f "$_rtmp"; log_error "run: assembled report failed self-validation (fail closed)"; exit 2; }
rm -f "$_rtmp"

[ -n "$OUT_JSON" ] || OUT_JSON="$REPO_ROOT/integration/production-readiness-report.json"
[ -n "$OUT_MD" ] || OUT_MD="$REPO_ROOT/integration/production-readiness-report.md"
ensure_dir "$(dirname -- "$OUT_JSON")"
printf '%s\n' "$REPORT_JSON" | jq '.' > "$OUT_JSON"

# Human report.
_rv=$(printf '%s' "$REC_JSON" | jq -r '.version')
_rr=$(printf '%s' "$REC_JSON" | jq -r '.rationale')
ensure_dir "$(dirname -- "$OUT_MD")"
{
	printf '# Sentinel Shield — Production-Readiness Report\n\n'
	printf '**Engine-only scope.** Framework live-validation (Laravel/Symfony) is NOT claimed here; the\n'
	printf 'framework tracks are validated independently. This report is UNTRUSTED input to\n'
	printf '`run-production-readiness.sh review`, which re-derives every trust decision.\n\n'
	printf -- '- Generated: `%s`\n' "$_gen"
	printf -- '- Source commit: `%s`\n' "$SOURCE_COMMIT"
	printf -- '- Default branch / event / workflow: `%s` / `%s` / `%s`\n' "$DEFAULT_BRANCH" "$EVENT" "$WORKFLOW"
	printf -- '- Recommendation: **`%s`** — %s\n\n' "$_rv" "$_rr"
	printf '## Gate results\n\n'
	printf '| Gate | Required | Status |\n| --- | --- | --- |\n'
	printf '%s' "$GATES_JSON" | jq -r '.[] | "| \(.id) | \(.required) | \(.status) |"'
	printf '\n## Summary\n\n'
	printf '%s' "$SUMMARY_JSON" | jq -r '"- total: \(.total)  passed: \(.passed)  failed: \(.failed)  skipped: \(.skipped)  timed_out: \(.timed_out)"'
	printf '\n'
} > "$OUT_MD"

log_info "run: wrote $OUT_JSON and $OUT_MD"

# Exit code: distinct timeout floor, then required-gate failures.
_req_fail=$(printf '%s' "$GATES_JSON" | jq '[ .[] | select(.required == true and (.status == "fail" or .status == "timeout")) ] | length')
if [ "$_any_timeout" = 1 ]; then
	printf 'run: production-readiness FAILED — a required gate TIMED OUT (fail closed)\n'
	exit 4
fi
if [ "$_req_fail" -gt 0 ]; then
	printf 'run: production-readiness NOT READY — %s required gate(s) failed; fail closed\n' "$_req_fail"
	exit 1
fi
printf 'run: production-readiness gates PASSED (%s); recommendation %s\n' "$WORKFLOW" "$_rv"
exit 0
