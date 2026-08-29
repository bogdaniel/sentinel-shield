#!/bin/sh
# Sentinel Shield — gate enforcer.
#
# Consumes the resolved gate flags (reports/sentinel-shield-gates.env) and a
# normalized findings document (reports/security-summary.json), then decides
# pass/fail per the active SENTINEL_SHIELD_FAIL_ON_* flags.
#
# Design goals: strict, boring, explicit, predictable.
#   - POSIX sh only (no Bash arrays / [[ ]] / local).
#   - The gates .env is NEVER blind-sourced. Each line is validated against a
#     strict allow-list pattern; anything suspicious is rejected (exit 2).
#   - JSON is parsed with jq. Sentinel Shield intentionally does NOT parse JSON
#     with fragile shell hacks; jq is required for enforcement (exit 2 if absent).
#
# Exit codes:
#   0  all active gates pass
#   1  one or more active gates fail
#   2  configuration / input / parsing error
#
# Shared exit-code contract reconciliation (v2): the gate is the FINAL decision point.
# A required tool that is unavailable (contract code 3) or that produced no valid report
# / execution-error (contract code 4) is surfaced HERE as a gate failure (exit 1), not as
# 3/4 — those codes belong to the runners/orchestrator upstream. enforce-gates only ever
# returns 0/1/2.
#
# See docs/security-summary-schema.md and docs/gate-resolution.md.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"

# die_cfg <message...> — configuration/input/parsing error -> exit 2.
die_cfg() {
	log_error "$*"
	exit 2
}

# NOTE: there is deliberately NO single "GATE_KEYS" list here.
#
# There used to be one. It was referenced NOWHERE, and it listed 16 of the ~41 gates this
# script actually evaluates — so it read as an authoritative inventory while omitting the
# quality, architecture and testing-discipline channels entirely. A maintainer trusting it
# would have concluded those gates did not exist.
#
# The real inventory is the set of *_KEYS lists below, each paired with the evaluator that
# consumes it, plus the explicit eval_* calls further down. scripts/resolve-gates.sh
# FAIL_ON_KEYS is the authority on which flags are emitted; tests/prod/269 asserts the two
# sides reconcile exactly, so a gate can no longer be resolved-but-never-evaluated (or the
# reverse) without a test failing.

# Integer summary keys that must be present (the two missing_* are booleans and
# are validated separately).
INT_SUMMARY_KEYS="secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions expired_exceptions"

# Third-party supply-chain gates (v0.1.5). Evaluated like count gates, but NOT in the
# required INT_SUMMARY_KEYS set: an older summary that omits them is treated as 0
# (absent), not a config error. v1 defaults keep them non-blocking except in
# strict/regulated (see resolve-gates.sh).
THIRD_PARTY_KEYS="third_party_suspicious_code third_party_install_script_risk third_party_obfuscation third_party_network_behavior"

# Enterprise scanner count gates (v0.1.12). Evaluated like count gates; optional (an
# older summary that omits them reads as 0, not a config error). Mode defaults gate
# these (see resolve-gates.sh): baseline blocks php_syntax_errors +
# dependency_policy_violations; strict adds style/iac/container; regulated adds
# dast/repository_health; ai_review_findings is non-gating unless explicitly enabled.
# NOTE: finding-scoped accepted-risk remains implemented ONLY for unsafe_docker; these
# keys support broad gate:<key> suppression only (reported as broad). secrets is never
# suppressible and is unaffected.
ENTERPRISE_COUNT_KEYS="php_syntax_errors style_violations dependency_policy_violations iac_violations container_image_violations dast_findings repository_health_warnings ai_review_findings"

# Engineering-quality count gates (v2.1). Evaluated like count gates; optional (an
# older summary that omits them reads as 0, not a config error). Mode defaults gate
# these (see resolve-gates.sh): strict blocks coverage threshold/regression + complexity +
# duplication; regulated adds mutation + dead-code. These are a SEPARATE channel from
# security counters — quality findings are never folded into vulnerability counts, and
# vice-versa. NOT suppressible by accepted-risk (loud and visible by design); disable via
# an explicit gates.fail_on override or a lower mode.
QUALITY_COUNT_KEYS="coverage_threshold_violations coverage_regression mutation_score_violations complexity_violations duplication_violations dead_code_violations changed_lines_coverage_violations skipped_tests focused_test_violations skipped_test_marker_violations debug_code_violations large_file_violations large_function_violations"

# Boolean quality gates (v2.1) — evaluated with eval_bool_gate (absent key reads as false).
QUALITY_BOOL_KEYS="missing_coverage_evidence missing_test_evidence empty_test_suite"

# Architecture-governance gates (v2.1.0). architecture_violations is the long-standing COUNT
# gate (evaluated with the security counters below); missing_architecture_evidence is the new
# boolean evidence gate: strict/regulated fail when an APPLICABLE architecture producer
# produced no valid evidence, so "we never ran it" cannot read as "we are clean". Architecture
# findings are their own channel — never folded into vulnerability counters.
ARCHITECTURE_BOOL_KEYS="missing_architecture_evidence"

# Informational architecture metrics surfaced in the enforcement report (never gate directly).
ARCHITECTURE_INFO_KEYS="architecture_rule_count architecture_tool_count architecture_context_count"

# Testing-discipline gates (v2.2.0). COUNT gates evaluated like every other count gate; absent
# keys read as 0 (an older summary stays valid). These are their OWN channel — a missing test
# never becomes a vulnerability, and a vulnerability never becomes a testing-discipline finding.
#
# production_change_without_test_change is a TDD PROXY, not proof of TDD: Sentinel Shield
# cannot know whether a test was written before the code it covers. It gates the one thing that
# IS observable — production behavior changed and no test changed with it.
TESTING_DISCIPLINE_COUNT_KEYS="production_change_without_test_change orphan_behavior_specifications acceptance_test_failures"

# Boolean testing-discipline evidence gates (v2.2.0) — evaluated with eval_bool_gate (absent
# key reads as false). The builder (run with --profile) sets each only when that evidence was
# EXPECTED by the profile or the project's testing-discipline policy, so a library is never
# failed for BDD/ATDD it never adopted.
TESTING_DISCIPLINE_BOOL_KEYS="missing_test_change_evidence missing_behavior_specification missing_acceptance_evidence"

# Informational testing-discipline metrics surfaced in the report (never gate directly).
TESTING_DISCIPLINE_INFO_KEYS="behavior_spec_count acceptance_test_count"

# Informational quality metrics surfaced in the enforcement report (never gate directly).
QUALITY_INFO_KEYS="coverage_line_percent coverage_branch_percent coverage_method_percent coverage_class_percent mutation_score_percent complexity_max complexity_average duplication_percent dead_code_count changed_lines_coverage_percent test_count max_file_lines max_function_lines"

# --- defaults / CLI ----------------------------------------------------------
GATES_ENV_FILE="reports/sentinel-shield-gates.env"
SUMMARY="reports/security-summary.json"
# An INDEPENDENTLY produced source-attestation record (scripts/verify-source-attestation.sh).
# Empty means none was supplied, which `regulated` refuses.
ATTESTATION_FILE=""
OUTPUT_DIR="reports"
FORMAT="all"
STRICT_SUMMARY=0
ACCEPTED_RISKS_FILE=".sentinel-shield/accepted-risks.json"
CONTROL_WAIVERS_FILE=".sentinel-shield/control-waivers.json"  # required-tool waivers (schemas/control-waiver.schema.json)
RAW_HADOLINT=""        # default derived from --summary dir (reports/raw/hadolint.json)
RAW_DOCKER_BASE=""     # default derived from --summary dir (reports/raw/docker-base-digest.json)
RAW_DIR=""             # default derived from --summary dir (reports/raw); finding-scope sources
# Execution plan (run-tool-plan.sh) used to RECONCILE required-tool scope claims.
TOOL_PLAN=""

# Gates that an approved accepted-risk record MAY suppress (v0.1.3). Deliberately
# narrow. NEVER suppressible: secrets, expired_exceptions, missing_release_evidence,
# missing_sbom, and the critical/high vuln gates.
SUPPRESSIBLE_GATES="unsafe_docker medium_vulnerabilities"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: enforce-gates.sh [options]

Enforce resolved gate flags against a normalized security-summary.json.

Options:
  --gates-env <path>   Resolved gate flags (default: reports/sentinel-shield-gates.env)
  --summary <path>     Normalized findings (default: reports/security-summary.json)
  --output-dir <path>  Output directory (default: reports)
  --format <fmt>       markdown | json | all   (default: all)
  --strict-summary     Opt into the COMPLETE structural validation (source, evidence, tool
                       statuses, version) in report-only. It is applied automatically —
                       and cannot be turned off — in baseline/strict/regulated.
  --attestation <path> An INDEPENDENTLY verified source-attestation record, produced by
                       scripts/verify-source-attestation.sh. REQUIRED by `regulated`: a
                       summary cannot attest to itself (whoever writes it can write
                       'verified: true' into it) and cannot bind its own sha256, so the
                       binding has to come from outside the document. The record must bind
                       repository, commit, workflow, run_id and an artifact digest equal to
                       the sha256 of the summary being enforced.
  --accepted-risks <path>  Accepted-risk records (default: .sentinel-shield/accepted-risks.json).
                       An APPROVED, unexpired, owned record may suppress a
                       suppressible gate (unsafe_docker, medium_vulnerabilities).
                       v0.1.8: records are FINDING-SCOPED by default (match rule_id+files);
                       broad gate suppression requires explicit "scope":"gate".
                       Never suppresses secrets/expired_exceptions/missing_release_evidence.
  --raw-dir <path>       Raw scanner reports used for finding-scoped acceptance on
                       vulnerability gates (default: <summary dir>/raw).
  --tool-plan <path>     Execution plan written by run-tool-plan.sh
                       (reports/<stage>-execution.json). A SEPARATE artifact used to
                       RECONCILE required-tool scope: applicability, stage selection and
                       policy are taken from it, and a summary field that disagrees is a
                       failure. Without it, strict/regulated do not honour a scope
                       exemption the summary claims about itself.
  --hadolint-raw <path>  Raw Hadolint report for unsafe_docker finding-scope matching
                       (default: <summary-dir>/raw/hadolint.json).
  --control-waivers <path>  Required-tool control waivers (default: .sentinel-shield/control-waivers.json,
                       schemas/control-waiver.schema.json). An UNEXPIRED waiver for a required
                       tool downgrades its unavailable/not-configured/disabled failure to a
                       prominently-reported waiver (NOT a normal accepted-risk). Does NOT
                       suppress findings.
  --docker-base-digest-raw <path>  Raw Docker base-digest report (v0.1.10) — the OTHER
                       unsafe_docker source (rule_id SS_DOCKER_BASE_DIGEST). Default:
                       <summary-dir>/raw/docker-base-digest.json.
                       Finding-scope matching normalizes BOTH sources; if a source's raw
                       report is missing while summary.unsafe_docker accounts for it, the
                       unaccounted findings are treated as UNACCEPTED (gate fails closed).
  -h, --help           Show this help

Outputs:
  <output-dir>/sentinel-shield-enforcement.md
  <output-dir>/sentinel-shield-enforcement.json

Exit: 0 pass, 1 fail, 2 configuration/input/parsing error.
Requires jq (JSON is not parsed with fragile shell hacks).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--gates-env) GATES_ENV_FILE="${2:?--gates-env requires a value}"; shift 2 ;;
		--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
		--attestation) ATTESTATION_FILE="${2:?--attestation requires a value}"; shift 2 ;;
		--output-dir) OUTPUT_DIR="${2:?--output-dir requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		--strict-summary) STRICT_SUMMARY=1; shift ;;
		--accepted-risks) ACCEPTED_RISKS_FILE="${2:?--accepted-risks requires a value}"; shift 2 ;;
		--control-waivers) CONTROL_WAIVERS_FILE="${2:?--control-waivers requires a value}"; shift 2 ;;
		--raw-dir) RAW_DIR="${2:?--raw-dir requires a value}"; shift 2 ;;
		--tool-plan) TOOL_PLAN="${2:?--tool-plan requires a value}"; shift 2 ;;
		--hadolint-raw) RAW_HADOLINT="${2:?--hadolint-raw requires a value}"; shift 2 ;;
		--docker-base-digest-raw) RAW_DOCKER_BASE="${2:?--docker-base-digest-raw requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

case "$FORMAT" in
	markdown | json | all) ;;
	*) die_cfg "invalid --format '$FORMAT' (expected: markdown | json | all)" ;;
esac

command_exists jq || die_cfg "jq is required for security-summary.json enforcement but was not found. Install jq. (Sentinel Shield does not parse JSON with fragile shell hacks.)"

[ -f "$GATES_ENV_FILE" ] || die_cfg "gates env not found: '$GATES_ENV_FILE' (run scripts/resolve-gates.sh first)"
[ -f "$SUMMARY" ] || die_cfg "security summary not found: '$SUMMARY' (a scanner workflow must produce it; see docs/security-summary-schema.md)"

# Default the raw Hadolint report next to the summary (reports/raw/hadolint.json) unless
# the caller pointed elsewhere. Used for unsafe_docker finding-scope matching (v0.1.8).
[ -n "$RAW_HADOLINT" ] || RAW_HADOLINT="$(dirname "$SUMMARY")/raw/hadolint.json"
[ -n "$RAW_DOCKER_BASE" ] || RAW_DOCKER_BASE="$(dirname "$SUMMARY")/raw/docker-base-digest.json"
# Raw scanner reports used to derive FINDING IDENTITY for finding-scoped accepted risks on
# vulnerability gates (medium_vulnerabilities). Same convention as the two paths above.
[ -n "$RAW_DIR" ] || RAW_DIR="$(dirname "$SUMMARY")/raw"

# --- load the gates env SAFELY (validate; never blind-source) ----------------
# The parser is ss_gates_env_read in the shared library, so the enforcer, the summary selector
# and the report generator cannot interpret the same policy file differently. It validates the
# line shape, rejects duplicate keys (ambiguous policy) and rejects unknown keys (resolver /
# enforcer drift) before any value is read.
GATES_ENV=$(ss_gates_env_read "$GATES_ENV_FILE") || die_cfg "gates env is not usable: $GATES_ENV_FILE (see errors above)"

# env_get <FULL_KEY> — value from the validated env content, or empty. Uniqueness is proven
# by the reader, so "first match" can no longer differ from "the value".
env_get() { ss_gates_env_value "$GATES_ENV" "$1"; }

# gate_flag <gate_key> — resolved fail_on flag (true/false). Absent -> false+warn.
# gate_flag <key> — resolved boolean for a gate, parsed CANONICALLY.
#
# FAIL CLOSED (v2.0.2 security hotfix). Two prior fail-open paths are closed here:
#   * an ABSENT flag used to warn and disable the gate. A truncated, hand-edited or
#     tampered gates.env therefore silently switched gates off — a gates.env with no
#     FAIL_ON_ lines at all passed a summary carrying secrets and criticals.
#   * a NON-CANONICAL value ("TRUE", "yes", "1") was compared literally against the
#     string "true", so it disabled the gate with NO warning at all.
# Both are now configuration errors. bool_value() is the engine-wide parser and accepts
# the documented spellings; anything else is rejected rather than guessed at.
gate_flag() {
	_suffix=$(upper "$1")
	_v=$(env_get "SENTINEL_SHIELD_FAIL_ON_$_suffix")
	if [ -z "$_v" ]; then
		die_cfg "gates env is missing SENTINEL_SHIELD_FAIL_ON_$_suffix. A gate flag that cannot be read is a configuration error, never a disabled gate — regenerate it with scripts/resolve-gates.sh."
	fi
	_n=$(bool_value "$_v" 2>/dev/null) \
		|| die_cfg "SENTINEL_SHIELD_FAIL_ON_$_suffix must be a boolean, got '$_v' (use true/false)"
	printf '%s' "$_n"
}

# MODE is a POLICY ENUM, not display metadata: strict/regulated trigger evidence-integrity
# preconditions, so an unvalidated value ("unknown", a typo, a case variant) silently selected
# a weaker state than the product defines and enforcement could still report success under it.
MODE=$(env_get "SENTINEL_SHIELD_MODE")
case "$MODE" in
	report-only | baseline | strict | regulated) ;;
	'') die_cfg "gates env declares no SENTINEL_SHIELD_MODE. The adoption mode selects the evidence preconditions; it is never inferred ($GATES_ENV_FILE)" ;;
	*) die_cfg "gates env declares SENTINEL_SHIELD_MODE='$MODE', which is not one of the canonical modes report-only|baseline|strict|regulated. An unknown mode is a configuration error, never a weaker custom state ($GATES_ENV_FILE)" ;;
esac

# The GATE/EVIDENCE contract the summary declares (issue #219). Compatibility between policy
# and evidence is NEGOTIATED, never assumed:
#   * a summary that DECLARES a contract must carry every field its enabled gates need — a
#     missing counter is a build defect, not a clean zero;
#   * a summary that declares NOTHING is legacy: the assurance modes refuse it rather than
#     reading absent fields as evidence, and the visibility modes keep the documented
#     tolerance, loudly.
SUMMARY_CONTRACT=""
if [ -f "$SUMMARY" ] && jq -e . "$SUMMARY" >/dev/null 2>&1; then
	SUMMARY_CONTRACT=$(jq -r '(.gate_contract_version // "") | tostring' "$SUMMARY" 2>/dev/null || printf '')
	[ "$SUMMARY_CONTRACT" = "null" ] && SUMMARY_CONTRACT=""
fi

# The env file and the resolver's JSON artifact must agree. A hand-edited env claiming
# report-only next to a strict resolution (or vice versa) is contradictory policy.
_gates_json="$(dirname "$GATES_ENV_FILE")/sentinel-shield-gates.json"
# The reconciliation below is what makes the key check AUTHORITATIVE — the lexical scan
# accepts any SENTINEL_SHIELD_FAIL_ON_* / _PROJECT_* name, so without the resolver artifact a
# typo like SENTINEL_SHIELD_FAIL_ON_SECRETS_TYPO is simply an unknown key nothing rejects.
# Treating the artifact as optional therefore meant that CORRUPTING it removed the check
# entirely, which is why a malformed artifact is refused below.
#
# ABSENT is a different case and is deliberately NOT refused, in any mode. `--format env` is a
# supported resolution flow (asserted by tests/prod/288 and documented in
# docs/regulated-dry-run.md), so an absent artifact means "the env-only flow", not "the
# artifact was removed". Its key set is still validated — not by the reconciliation below,
# which has nothing to compare against, but against the gate registry read out of
# resolve-gates.sh itself, immediately below.
#
# What env-only does NOT get is the mode/value agreement check: nothing can detect an env file
# whose recorded mode or gate values differ from the resolution it claims to come from,
# because the other side of that comparison is the file that is missing. Callers who need that
# assurance resolve with `--format all` — which is what every shipped template does.
#
# A MALFORMED artifact is never a reason to fall back to the env file alone: corrupting the
# file would otherwise remove the reconciliation below.
if [ -f "$_gates_json" ] && ! jq -e . "$_gates_json" >/dev/null 2>&1; then
	die_cfg "'$_gates_json' is not valid JSON. A malformed resolver artifact is a configuration error, never a reason to fall back to the env file alone — regenerate it with scripts/resolve-gates.sh."
fi
# When the JSON is ABSENT (the documented `--format env` flow), the key set still has to be
# authoritative: the lexical scan accepts ANY SENTINEL_SHIELD_FAIL_ON_* name, so a typo like
# SENTINEL_SHIELD_FAIL_ON_SECRETS_TYPO would simply be an unknown key nothing rejects. The
# canonical list is read from the RESOLVER ITSELF (its FAIL_ON_KEYS declaration), so this
# check cannot drift from the producer and no second copy is maintained here.
if [ ! -f "$_gates_json" ]; then
	_reg_tmp=$(mktemp); _envk_tmp=$(mktemp)
	sed -n 's/^FAIL_ON_KEYS="\(.*\)"$/\1/p' "$SCRIPT_DIR/resolve-gates.sh" 2>/dev/null |
		tr ' ' '\n' | sed '/^$/d' | tr 'a-z' 'A-Z' | sed 's/^/SENTINEL_SHIELD_FAIL_ON_/' | sort > "$_reg_tmp"
	printf '%s\n' "$GATES_ENV" | sed -n 's/^\(SENTINEL_SHIELD_FAIL_ON_[A-Z0-9_]*\)=.*/\1/p' | sort > "$_envk_tmp"
	if [ -s "$_reg_tmp" ]; then
		_unknown=$(grep -Fxv -f "$_reg_tmp" "$_envk_tmp" 2>/dev/null || true)
		rm -f "$_reg_tmp" "$_envk_tmp"
		[ -z "$_unknown" ] || die_cfg "gates env declares gate flag(s) that are not in the engine's gate registry: $(printf '%s' "$_unknown" | tr '\n' ' ')- a mistyped or stale flag is a configuration error ($GATES_ENV_FILE)"
	else
		rm -f "$_reg_tmp" "$_envk_tmp"
		die_cfg "could not read the canonical gate registry from '$SCRIPT_DIR/resolve-gates.sh'; refusing to accept an unvalidated gate-flag set"
	fi
fi
if [ -f "$_gates_json" ] && jq -e . "$_gates_json" >/dev/null 2>&1; then
	_jmode=$(jq -r '(.mode // .adoption_mode // "")' "$_gates_json")
	if [ -n "$_jmode" ] && [ "$_jmode" != "$MODE" ]; then
		die_cfg "gate resolution disagrees with itself: '$GATES_ENV_FILE' says mode='$MODE' but '$_gates_json' says '$_jmode'. Regenerate both with scripts/resolve-gates.sh."
	fi
	# The resolver's JSON is the authoritative gate set, so a typo'd or stale FAIL_ON_ key is
	# detectable without maintaining a second copy of the list here. POSIX sh: temp files, no
	# process substitution.
	_gk_tmp=$(mktemp); _ge_tmp=$(mktemp)
	jq -r '(.gates // .fail_on // {}) | keys[] | "SENTINEL_SHIELD_FAIL_ON_" + (. | ascii_upcase)' "$_gates_json" 2>/dev/null | sort > "$_gk_tmp"
	printf '%s\n' "$GATES_ENV" | sed -n 's/^\(SENTINEL_SHIELD_FAIL_ON_[A-Z0-9_]*\)=.*/\1/p' | sort > "$_ge_tmp"
	if [ -s "$_gk_tmp" ]; then
		_extra=$(grep -Fxv -f "$_gk_tmp" "$_ge_tmp" 2>/dev/null || true)
		_absent=$(grep -Fxv -f "$_ge_tmp" "$_gk_tmp" 2>/dev/null || true)
		rm -f "$_gk_tmp" "$_ge_tmp"
		if [ -n "$_extra" ]; then
			die_cfg "gates env declares gate flag(s) the resolver does not know: $(printf '%s' "$_extra" | tr '\n' ' ')- a typo or a stale flag is a configuration error ($GATES_ENV_FILE)"
		fi
		if [ -n "$_absent" ]; then
			die_cfg "gates env is missing resolver gate flag(s): $(printf '%s' "$_absent" | tr '\n' ' ')- regenerate it with scripts/resolve-gates.sh ($GATES_ENV_FILE)"
		fi
	else
		rm -f "$_gk_tmp" "$_ge_tmp"
	fi
	_jbad=$(jq -r --arg env "$GATES_ENV" '
		[ (.gates // .fail_on // {}) | to_entries[]
		  | .key as $k | (.value | tostring) as $v
		  | ("SENTINEL_SHIELD_FAIL_ON_" + ($k | ascii_upcase)) as $ek
		  | select(($env | test("(^|\n)" + $ek + "=" + $v + "($|\n)")) | not)
		  | $k ] | join(" ")' "$_gates_json" 2>/dev/null || printf '')
	[ -z "$_jbad" ] || die_cfg "gate flags disagree between '$GATES_ENV_FILE' and '$_gates_json' for: $_jbad. Regenerate both with scripts/resolve-gates.sh."
	# PROJECT_* metadata gets the same treatment: the lexical allowlist accepts any
	# SENTINEL_SHIELD_PROJECT_* name, so an unknown one used to pass silently.
	_pk_tmp=$(mktemp)
	printf '%s\n' "$GATES_ENV" | sed -n 's/^\(SENTINEL_SHIELD_PROJECT_[A-Z0-9_]*\)=.*/\1/p' | sort > "$_pk_tmp"
	# The canonical set is what resolve-gates.sh actually emits — read from the resolver
	# script itself so this list cannot drift from the producer.
	_pk_known=$(mktemp)
	sed -n "s/^[[:space:]]*printf '\(SENTINEL_SHIELD_PROJECT_[A-Z0-9_]*\)=.*/\1/p" \
		"$SCRIPT_DIR/resolve-gates.sh" 2>/dev/null | sort -u > "$_pk_known"
	if [ ! -s "$_pk_known" ]; then
		printf '%s\n' SENTINEL_SHIELD_PROJECT_NAME SENTINEL_SHIELD_PROJECT_TYPE \
			SENTINEL_SHIELD_PROJECT_CRITICALITY SENTINEL_SHIELD_PROJECT_OWNER | sort > "$_pk_known"
	fi
	_punknown=$(grep -Fxv -f "$_pk_known" "$_pk_tmp" 2>/dev/null || true)
	rm -f "$_pk_tmp" "$_pk_known"
	[ -z "$_punknown" ] || die_cfg "gates env declares unknown project metadata key(s): $(printf '%s' "$_punknown" | tr '\n' ' ')- a mistyped or stale metadata key is a configuration error ($GATES_ENV_FILE)"
fi
PROJ_NAME=$(env_get "SENTINEL_SHIELD_PROJECT_NAME"); [ -n "$PROJ_NAME" ] || PROJ_NAME="unknown"
PROJ_TYPE=$(env_get "SENTINEL_SHIELD_PROJECT_TYPE"); [ -n "$PROJ_TYPE" ] || PROJ_TYPE="unknown"
PROJ_CRIT=$(env_get "SENTINEL_SHIELD_PROJECT_CRITICALITY"); [ -n "$PROJ_CRIT" ] || PROJ_CRIT="unknown"

# --- validate the summary ----------------------------------------------------
jq -e . "$SUMMARY" >/dev/null 2>&1 || die_cfg "security summary is not valid JSON: $SUMMARY"

# jqr <filter> — raw jq read against the summary (no `//` operator: it would treat
# boolean false as empty).
jqr() { jq -r "$1" "$SUMMARY" 2>/dev/null || printf 'null'; }

# Required top-level fields.
[ "$(jqr '.version')" != "null" ] || die_cfg "missing required field: version"
[ "$(jqr '.generated_at')" != "null" ] || die_cfg "missing required field: generated_at"
[ "$(jqr '.summary | type')" = "object" ] || die_cfg "missing or invalid required field: summary (must be an object)"

# Required integer summary keys.
for _k in $INT_SUMMARY_KEYS; do
	_v=$(jqr ".summary.$_k")
	if [ "$_v" = "null" ]; then
		die_cfg "missing required summary key: summary.$_k"
	fi
	# The digit test alone let a value of ANY magnitude reach shell `[ -gt ]` below, where
	# at 2^63 it is a HARD ERROR with a different message in each supported shell — a gate
	# that crashes instead of deciding. ss_count_valid bounds it WITHOUT arithmetic, so the
	# check survives the very inputs it exists to reject (#146).
	case "$_v" in
		'' | *[!0-9]*) die_cfg "summary.$_k must be a non-negative integer, got '$_v'" ;;
	esac
	ss_count_valid "$_v" \
		|| die_cfg "summary.$_k is $_v, above the bounded-count maximum $SS_MAX_COUNT. A count shell arithmetic cannot represent is untrusted evidence; it is never clamped or read as a clean 0."
done

# Required boolean summary keys.
for _k in missing_sbom missing_release_evidence; do
	_v=$(jqr ".summary.$_k")
	if [ "$_v" = "null" ]; then
		die_cfg "missing required summary key: summary.$_k"
	fi
	case "$_v" in
		true | false) ;;
		*) die_cfg "summary.$_k must be a boolean, got '$_v'" ;;
	esac
done

# --- evidence-integrity precondition for strict/regulated (v2.0.2 hotfix) ----
# THE INVARIANT: "no scanner ran" must never read as "we are clean".
#
# It previously did. build-security-summary.sh invokes every collector even when its raw
# report is absent; each returns status=unavailable with a fully ZEROED summary, and the
# merge sums those zeros into a pristine-looking document. Nothing downstream consulted
# .tools[].status unless the builder had been run with --profile. So an EMPTY reports/raw
# — zero scanners executed — produced a summary that passed `regulated`, which is the
# highest-assurance mode this engine offers.
#
# The builder cannot decide this alone: without a profile it has no way to know which
# tools were APPLICABLE (a PHP project legitimately has no npm-audit report), so counting
# every unavailable collector would fail every project. Applicability lives in the
# effective profile. Therefore strict/regulated now REQUIRE a policy-bearing summary —
# option A of the remediation plan, PROFILE_REQUIRED_FOR_REGULATED.
#
# report-only/baseline are unchanged: they are visibility/migration modes and are not
# claimed to prove evidence completeness.
# The trigger is deliberately NARROW: .tools is populated but NOT ONE entry carries an
# evidence-bearing status. That is exactly the reproduced vulnerability — the builder ran
# every collector, each returned `unavailable` over an absent report, and the merged
# document looked pristine. It is not merely "no profile was passed":
#   * a summary whose .tools is EMPTY (hand-built, or produced by an external pipeline)
#     is left alone — its author is asserting their own evidence, and silently refusing to
#     enforce it would break a documented capability rather than close a hole;
#   * a run where even one scanner produced pass/findings/fail/warn proceeds to the normal
#     gates, which is where real findings are judged.
# CLOSED (was: "a caller who hand-writes `\"tools\": {}` still bypasses this"). Omission is
# not an external-evidence contract: a summary with NO tools proves nothing ran, which is
# exactly the state strict/regulated must refuse. An external pipeline that produces its own
# evidence declares it positively — the tools object lists what ran — rather than by leaving
# the object empty.
# The report-only fallback is explicitly NON-PRODUCTION evidence. select-security-summary.sh
# marks it, and every enforcing mode refuses it here as well — so a marked fallback left in
# reports/ from an earlier report-only run cannot be enforced against later.
case "$MODE" in
	baseline | strict | regulated)
		if jq -e '(.fallback.non_production // false) == true' "$SUMMARY" >/dev/null 2>&1; then
			log_error "'$SUMMARY' carries the NON-PRODUCTION fallback marker (.fallback.non_production=true)."
			log_error "  It is the all-zero example staged by select-security-summary.sh in report-only mode,"
			log_error "  not evidence. Produce a real summary with scripts/build-security-summary.sh."
			die_cfg "refusing to enforce '$MODE' against a non-production fallback summary"
		fi
		;;
esac

# #310: an UNOBSERVED execution is weaker evidence than an observed one. The collector infers
# completion from a parseable report when no execution record exists; that is recorded
# honestly as `execution.observed: false` rather than as a confident success, and an operator
# who needs the stronger form can require it here.
#
# OPT-IN, not default-on, and deliberately so: CodeQL's SARIF is produced by GitHub's CodeQL
# action, so there is no local process to observe and no execution record to write. Turning
# this on by default would fail every repository that runs CodeQL, which is a correctness
# claim the engine cannot yet honour. Making it the default is tracked as follow-up work.
if [ "${SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION:-0}" = "1" ]; then
	case "$MODE" in
		strict | regulated)
			# NOT `(.evidence.execution.observed // true) == false`. jq's `//` substitutes for
			# `false` as well as for `null`, so `false // true` is `true` and `== false` was
			# UNSATISFIABLE: this gate rejected nothing from the day it shipped (#326 A). The
			# comparison is made directly against the value instead — `null == false` is already
			# false in jq, so an ABSENT record still does not trip the gate, which is the
			# documented behaviour (only an explicitly recorded `observed: false` does).
			#
			# The path is deliberately NOT written with `?`. A tool whose `.evidence` is a string
			# or whose `.execution` is a number makes jq error, which surfaces here as
			# `unreadable` and fails closed; `.evidence?.execution?.observed?` would yield EMPTY
			# and silently skip that tool, turning malformed evidence into a pass.
			_unobs=$(jq -r '[(.tools // {}) | to_entries[]
				| select(.value | (type == "object")
					and ((.evidence.execution.observed) == false))
				| .key] | join(", ")' "$SUMMARY" 2>/dev/null || printf 'unreadable')
			if [ "$_unobs" = "unreadable" ]; then
				die_cfg "'$SUMMARY' could not be read for the observed-execution check; an unparseable summary is untrusted evidence in '$MODE'"
			fi
			if [ -n "$_unobs" ]; then
				log_error "'$SUMMARY' carries tool evidence with UNOBSERVED execution: $_unobs"
				log_error "  SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 demands a recorded"
				log_error "  scanner exit status bound to the report digest. A parseable report"
				log_error "  is not a completed scan."
				die_cfg "refusing to enforce '$MODE' against evidence with unobserved execution"
			fi
			;;
	esac
fi

# #182: the same principle one level DOWN. A collector may emit fixture evidence — explicitly
# invoked, explicitly labelled `trust.type=fixture`, and only outside a release context — and
# it stamps `non_production: true` on that tool's report. Every enforcing mode refuses it here.
#
# The counts in fixture evidence are typically all zero, which is exactly why this keys on the
# LABEL and never on the numbers: a clean fixture is indistinguishable from a clean real scan
# by its counts alone. That indistinguishability is the whole reason the label is load-bearing.
case "$MODE" in
	baseline | strict | regulated)
		_np=$(jq -r '[(.tools // {}) | to_entries[]
			| select(.value | (type == "object") and ((.non_production // false) == true))
			| .key] | join(", ")' "$SUMMARY" 2>/dev/null || printf 'unreadable')
		if [ "$_np" = "unreadable" ]; then
			die_cfg "'$SUMMARY' could not be read for the non-production evidence check; an unparseable summary is untrusted evidence in '$MODE'"
		fi
		if [ -n "$_np" ]; then
			log_error "'$SUMMARY' carries NON-PRODUCTION tool evidence: $_np"
			log_error "  Those entries were produced with --fixture-evidence and are labelled"
			log_error "  trust.type=fixture. Fixture evidence is never gate evidence, and its"
			log_error "  all-zero counts are not a clean result."
			die_cfg "refusing to enforce '$MODE' against non-production tool evidence"
		fi
		;;
esac

case "$MODE" in
	strict | regulated)
		_evi=$(jq -r '
			((.tools // {}) | to_entries) as $t
			| if ($t | length) == 0 then "no-tools"
			  elif ($t | any(.value | (type=="object")
					and ((.status // "") | IN("pass","findings","fail","warn")))) then "ok"
			  else "none" end' "$SUMMARY" 2>/dev/null || printf 'unreadable')
		# A summary this precondition cannot even PARSE is untrusted evidence, not proof of
		# cleanliness. The fallback here used to be `printf 'ok'`, so a malformed, truncated
		# or unreadable $SUMMARY skipped the check entirely and certified strict/regulated
		# exactly as if evidence were present — re-opening the hole this whole change closes.
		if [ "$_evi" = "unreadable" ]; then
			log_error "the summary at '$SUMMARY' could not be inspected for scanner evidence."
			log_error "  An unparseable summary is untrusted evidence, never a clean result."
			die_cfg "refusing to certify '$MODE' from a summary that cannot be read"
		fi
		if [ "$_evi" = "no-tools" ]; then
			log_error "NO_EVIDENCE_FOR_$(upper "$MODE"): '$SUMMARY' declares an EMPTY tools object."
			log_error "  An empty tools object is an ABSENCE of evidence, not an external-evidence contract:"
			log_error "  nothing in it states that any scanner, test, architecture or quality producer ran."
			log_error "  Build the summary with scripts/build-security-summary.sh --profile <name> (internal"
			log_error "  producers), or have your external pipeline declare each producer and its status in"
			log_error "  .tools — see docs/security-summary-schema.md."
			die_cfg "refusing to certify '$MODE' from a summary that declares no producers"
		fi
		if [ "$_evi" = "none" ]; then
			log_error "NO_EVIDENCE_FOR_$(upper "$MODE"): every tool in this summary reports a non-evidence status."
			log_error "  '$SUMMARY' lists $(jq -r '(.tools // {}) | length' "$SUMMARY" 2>/dev/null) tool(s) and NOT ONE of them ran:"
			log_error "  $(jq -r '[(.tools // {}) | to_entries[] | .value.status // "?"] | group_by(.) | map("\(length)x \(.[0])") | join(", ")' "$SUMMARY" 2>/dev/null)"
			log_error "  'no scanner ran' is not 'we are clean'. Produce real scanner reports in reports/raw/,"
			log_error "  or build the summary with --profile so applicability is recorded honestly."
			die_cfg "refusing to certify '$MODE' from a summary containing no scanner evidence"
		fi
		;;
esac

# Complete structural validation is MANDATORY for every enforcing mode. It used to run only
# when the caller passed --strict-summary, so a workflow that forgot the flag enforced
# strict/regulated with WEAKER validation than an optional CLI option provided — and the flag
# name suggested it belonged to the product's `strict` mode, which it never did.
# report-only keeps the flag as an opt-in: it is a visibility mode whose summary may be the
# explicitly non-production fallback.
case "$MODE" in
	baseline | strict | regulated) STRICT_SUMMARY=1 ;;
esac
if [ "$STRICT_SUMMARY" -eq 1 ]; then
	log_info "strict-summary: validating optional structure (source, evidence, tool statuses)"
	_ver=$(jqr '.version')
	if [ "$_ver" != "1.0" ]; then
		die_cfg "strict-summary: version must be \"1.0\", got '$_ver'"
	fi
	for _f in source evidence; do
		if [ "$(jqr ".$_f | type")" != "object" ]; then
			die_cfg "strict-summary: missing or invalid '$_f' object"
		fi
	done
	# Any present tool status must be one of the allowed enum values.
	_bad=$(jq -r '
		(.tools // {}) | to_entries[]
		| select(.value | type == "object")
		| select((.value.status // "pass") as $s
			# The allowlist MUST match schemas/security-summary.schema.json. It listed only
			# the 5 legacy values while the schema (and every v1.10+ collector) also emits
			# findings / not-configured / not-applicable / execution-error / disabled — so
			# --strict-summary, the STRICTEST validation flag, could not be run against a
			# HEALTHY summary: any coverage/mutation/complexity report with findings made it
			# exit 2. The enforcer was the stale side.
			| ($s | IN("pass","fail","warn","skipped","unavailable",
			           "findings","not-configured","not-applicable","execution-error","disabled")) | not)
		| .key' "$SUMMARY" 2>/dev/null || true)
	if [ -n "$_bad" ]; then
		die_cfg "strict-summary: invalid tool status for: $(printf '%s' "$_bad" | tr '\n' ' ')"
	fi
fi

# --- source attestation (#241) -----------------------------------------------
# `source` used to be three free-form labels defaulting to unknown/master/local, and the
# enforcer only checked that the object existed. An assurance mode has to know WHICH commit
# in WHICH repository the evidence describes, otherwise a summary from anywhere can be
# judged as this run's.
case "$MODE" in
	strict | regulated)
		_scommit=$(jqr '.source.commit')
		case "$_scommit" in
			[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
			*) die_cfg "'$MODE' requires a summary bound to a specific commit: source.commit is '$_scommit', not a full 40-hex SHA. The default 'unknown' is an explicit non-claim, not evidence — rebuild with scripts/build-security-summary.sh in a checkout (docs/security-summary-schema.md)." ;;
		esac
		_srepo=$(jqr '.source.repository // ""')
		if [ -z "$_srepo" ] || [ "$_srepo" = "null" ]; then
			die_cfg "'$MODE' requires a summary bound to a repository: source.repository is absent. A commit with no repository does not identify evidence — rebuild with --repository <owner/name> (it is derived automatically in CI)."
		fi ;;
esac
# Trust vocabulary. The BUILDER always emits `unverified`; only a verified platform
# attestation raises it to `github-actions-attested`. `local` is the pre-attestation spelling
# and is accepted as a synonym of `unverified` for summaries built before this contract.
_strust=$(jqr '.source.trust // ""')
case "$_strust" in
	unverified | local | github-actions-attested | "" | null) : ;;
	*) die_cfg "unrecognised source.trust='$_strust'. The engine knows 'unverified' (a claim) and 'github-actions-attested' (a verified platform attestation); an unknown level is never treated as the trusted one." ;;
esac
case "$MODE" in
	strict)
		# Strict accepts evidence that is exactly bound to a repository and a full commit SHA
		# (checked above), but it must stay LABELLED for what it is: a claim, not a platform
		# attestation. It is never relabelled as attested.
		if [ "$_strust" != "github-actions-attested" ]; then
			log_warn "strict: source provenance is ATTESTATION-LIMITED (source.trust='${_strust:-unverified}') — the summary is bound to $(jqr '.source.repository // "?"')@$(jqr '.source.commit // "?"') by its own claim, and no platform attestation was verified. 'regulated' requires one."
		fi ;;
	regulated)
		# Regulated certifies audited evidence, so it requires a VERIFIED platform attestation.
		# Environment variables are claims, and the builder emits `unverified` precisely so
		# that no amount of environment control can reach this branch.
		# The attestation must come from OUTSIDE the document it attests.
		#
		# This used to read `.attestation` from the summary itself. Whoever can write the
		# summary can write `{"verified": true}` beside their own `.source` claims, so the
		# gate was checking the SHAPE of a self-authored assertion, not its authenticity —
		# the document authorised itself. A summary also cannot bind its own sha256, because
		# writing the digest in changes it, which is why the binding has to live elsewhere.
		#
		# `--attestation` is that elsewhere: a record produced by
		# scripts/verify-source-attestation.sh, whose anchor is `gh attestation verify`
		# against the workflow identity that actually produced the file. The summary's own
		# `.attestation` object, if present, is advisory and is never consulted here.
		[ -n "$ATTESTATION_FILE" ] \
			|| die_cfg "'regulated' requires an independently verified source attestation, supplied with --attestation <record>. A summary cannot attest to itself: whoever writes it can write 'verified: true' into it, and it cannot bind its own digest. Produce the record with scripts/verify-source-attestation.sh, or use 'strict' for an attestation-limited assurance run (docs/security-summary-schema.md)."
		[ -f "$ATTESTATION_FILE" ] \
			|| die_cfg "'regulated': the attestation record was not found: $ATTESTATION_FILE"
		jq -e . "$ATTESTATION_FILE" >/dev/null 2>&1 \
			|| die_cfg "'regulated': the attestation record is not valid JSON: $ATTESTATION_FILE"
		_ajq() { jq -r "$1 // \"\"" "$ATTESTATION_FILE" 2>/dev/null || printf ''; }
		[ "$(_ajq '.attestation')" = "sentinel-shield/source-attestation@1" ] \
			|| die_cfg "'regulated': unrecognised attestation record format '$(_ajq '.attestation')'; an unknown format is never treated as the verified one."
		[ "$(_ajq '.verified')" = "true" ] \
			|| die_cfg "'regulated': the attestation record does not report verified=true."
		# It must bind the SUMMARY BEING ENFORCED, by digest computed here and now.
		if command_exists sha256sum; then _sdig=$(sha256sum "$SUMMARY" | awk '{print $1}')
		elif command_exists shasum; then _sdig=$(shasum -a 256 "$SUMMARY" | awk '{print $1}')
		else log_error "'regulated': no sha256 tool (sha256sum/shasum) is available, so the attestation cannot be bound to this summary; an unverifiable binding is not a verified one"; exit 3; fi
		[ "$(_ajq '.artifact_digest')" = "sha256:$_sdig" ] \
			|| die_cfg "'regulated': the attestation is for artifact digest '$(_ajq '.artifact_digest')' but the summary being enforced is sha256:$_sdig. An attestation for a different artifact is not evidence about this one."
		_averified=true
		_strust=github-actions-attested
		# The attestation must name what it attests. A verified flag with no bound identity is
		# not provenance.
		for _af in repository commit workflow run_id artifact_digest; do
			_av=$(_ajq ".$_af")
			[ -n "$_av" ] && [ "$_av" != "null" ] \
				|| die_cfg "'regulated': the attestation does not bind $_af. A verified flag with no bound identity is not provenance."
		done
		# …and it must attest THIS summary's source.
		_ar=$(_ajq '.repository'); _sr=$(jqr '(.source.repository // "")')
		_ac=$(_ajq '.commit');     _sc=$(jqr '(.source.commit // "")')
		# The PRODUCER must be the one this repository trusts, not merely some workflow that
		# produced a valid attestation. `SENTINEL_SHIELD_TRUSTED_WORKFLOW` names it; when the
		# caller declares one, a record from any other workflow is refused. Without this a
		# genuine attestation from an unrelated workflow in the same repository would satisfy
		# regulated — a signature check wearing an identity check's clothes.
		if [ -n "${SENTINEL_SHIELD_TRUSTED_WORKFLOW:-}" ]; then
			_aw=$(_ajq '.workflow')
			_twf=${SENTINEL_SHIELD_TRUSTED_WORKFLOW##*/}; _twf=${_twf%%@*}
			case "$_aw" in
				"$_twf" | "$SENTINEL_SHIELD_TRUSTED_WORKFLOW") : ;;
				*) die_cfg "'regulated': the attestation was produced by workflow '$_aw', but this repository trusts '$SENTINEL_SHIELD_TRUSTED_WORKFLOW'. A valid attestation from a workflow that was never meant to certify release evidence is not evidence about this release." ;;
			esac
		fi
		[ "$_ar" = "$_sr" ] || die_cfg "'regulated': the attestation is for repository '$_ar' but the summary claims '$_sr'"
		[ "$_ac" = "$_sc" ] || die_cfg "'regulated': the attestation is for commit '$_ac' but the summary claims '$_sc'" ;;
esac

# --- accepted-risk suppression (v0.1.8: finding-scoped by default) -----------
# Records are FINDING-SCOPED unless they explicitly declare "scope":"gate".
#   - scope=="gate"    : BROAD — suppresses the whole gate (reported as broad).
#   - scope=="finding" : suppresses only matching findings (rule_id + files).
#                        Implemented for unsafe_docker (matches reports/raw/hadolint.json).
#                        For other suppressible gates it is NOT YET implemented → warns,
#                        does not suppress.
#   - no scope AND no rule_id/files/rule_ids : legacy/ambiguous → WARN, never suppresses
#                        (declare "scope":"gate" to opt into broad suppression).
# Raw counts are NEVER reduced. secrets/expired_exceptions/missing_release_evidence are
# never suppressible. pending/expired/invalid records never suppress.
TODAY=$(date -u +%Y-%m-%d)
AR_LOADED=0
AR_PENDING=0
AR_EXPIRED=0
AR_INVALID=0
AR_LEGACY_WARN=0       # valid records that are ambiguous (no scope/rule_id/files): ignored
GATE_SCOPE_SUPPRESSED=" "  # gate keys with a valid scope:gate (broad) record
AR_BROAD_DETAIL=""     # "gate|id" per broad (scope:gate) suppression
AR_FINDING_DETAIL=""   # "gate|id|rule_id|files-csv" per finding-scope record

if [ -f "$ACCEPTED_RISKS_FILE" ] && [ -s "$ACCEPTED_RISKS_FILE" ]; then
	jq -e . "$ACCEPTED_RISKS_FILE" >/dev/null 2>&1 || die_cfg "accepted-risks file is not valid JSON: $ACCEPTED_RISKS_FILE"

	# --- schema version + closed-object enforcement (v2) ---------------------------------
	# An IGNORED unknown field is dangerous in executable policy: a field meant to NARROW an
	# exception — a misspelled `components`, a `paths` that should have been `files` — is
	# silently dropped, and the record then matches MORE than its author intended. v2 closes
	# every object; deliberate additions live in `extensions` and are informational only.
	AR_SCHEMA_VERSION=$(jq -r '(.version // "") | tostring' "$ACCEPTED_RISKS_FILE")
	case "$AR_SCHEMA_VERSION" in
		2) AR_IS_V2=1 ;;
		1 | 1.1)
			AR_IS_V2=0
			case "$MODE" in
				strict | regulated)
					die_cfg "accepted-risks '$ACCEPTED_RISKS_FILE' declares legacy schema version \"$AR_SCHEMA_VERSION\". '$MODE' requires schema v2, which closes every object so an unknown field cannot silently broaden a suppression, and which carries the authorisation dates the validity policy needs. Migrate it: sh scripts/migrate-accepted-risks.sh --input '$ACCEPTED_RISKS_FILE' --output <new-file>" ;;
				*)
					log_warn "accepted-risks: DEPRECATED schema version \"$AR_SCHEMA_VERSION\" in '$ACCEPTED_RISKS_FILE'. Legacy records are read in '$MODE' only, and support ends in Sentinel Shield v3. Required target: version \"2\". Migrate with: sh scripts/migrate-accepted-risks.sh --input '$ACCEPTED_RISKS_FILE' --output <new-file>. strict and regulated refuse legacy files today." ;;
			esac ;;
		"") die_cfg "accepted-risks '$ACCEPTED_RISKS_FILE' declares no schema version. The version selects how the file is interpreted; it is never inferred." ;;
		*) die_cfg "accepted-risks '$ACCEPTED_RISKS_FILE' declares unsupported schema version \"$AR_SCHEMA_VERSION\" (known: \"2\", and legacy \"1\"/\"1.1\" under the migration policy). An unknown version is never read as the newest one." ;;
	esac

	if [ "$AR_IS_V2" -eq 1 ]; then
		# Closed objects, strict types, and the extension grammar. Reported all at once so a
		# fix is one edit rather than a game of whack-a-mole.
		_arv2=$(jq -r '
			def extkey: test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$");
			def known_top: ["version","generated_at","migrated_from","risks","extensions"];
			def known_risk: ["id","gate","scope","status","owner","reason","mitigation",
				"created_at","approved_at","expires_at","review_at","approval","severity",
				"category","scanner","rule_id","rule_ids","files","components","fingerprints",
				"source","sources",
				"finding_id","issue","incident","emergency","supersedes","extensions"];
			def known_approval: ["approved_by","authority","reference"];
			[
			  ( keys[] | select(. as $k | known_top | index($k) | not)
			    | "unknown top-level property \"\(.)\" (deliberate additions belong under `extensions`)" ),
			  ( (.extensions // {}) | keys[] | select(extkey | not)
			    | "malformed extension key \"\(.)\" (expected `vendor.example/key`)" ),
			  ( (.risks // []) | to_entries[]
			    | .key as $i | .value as $r
			    | if ($r | type) != "object" then "record \($i): not an object"
			      else empty end ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( keys[] | select(. as $k | known_risk | index($k) | not)
			        | "record \($rid): unknown property \"\(.)\" — an ignored field that was meant to NARROW this record would BROADEN the suppression; put consumer metadata under `extensions`" ) ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( ($r.extensions // {}) | keys[] | select(extkey | not)
			        | "record \($rid): malformed extension key \"\(.)\"" ) ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    # approved_at is required only for an APPROVED record: a pending record has
			    # not been approved, so demanding its approval date is incoherent.
			    | ( ( [ "id","gate","scope","status","owner","reason","created_at","expires_at" ]
			          + (if ($r.status // "") == "approved" then [ "approved_at" ] else [] end) )
			        | map(select(($r[.] // null) == null or ($r[.] == ""))) ) as $missing
			    | select(($missing | length) > 0)
			    | ($missing | join(" ")) as $ms
			    | "record \($rid): missing required field(s): \($ms)" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( [ "id","gate","scope","status","owner","reason","mitigation","created_at",
			          "approved_at","expires_at","review_at","severity","category","scanner",
			          "rule_id","finding_id","issue","incident","supersedes" ]
			        | map(select(($r[.] // null) != null and (($r[.] | type) != "string"))) ) as $wrong
			    | select(($wrong | length) > 0)
			    | ($wrong | join(" ")) as $ws
			    | "record \($rid): field(s) [\($ws)] must be strings — a bare yes/no/number is not a string, and coercing one would change what the record means" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( [ "rule_ids","files","components","fingerprints" ]
			        | map(select(($r[.] // null) != null and (($r[.] | type) != "array"))) ) as $wrong
			    | select(($wrong | length) > 0)
			    | ($wrong | join(" ")) as $ws
			    | "record \($rid): field(s) [\($ws)] must be arrays" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( [ "rule_ids","files","components","fingerprints" ][]
			        | . as $f | ($r[$f] // [])[]
			        | select((type != "string") or (length == 0))
			        | "record \($rid): every member of `\($f)` must be a non-empty string" ) ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.emergency // null) != null and (($r.emergency | type) != "boolean"))
			    | "record \($rid): `emergency` must be a boolean" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.id | type) == "string" and (($r.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$")) | not))
			    | "record \($rid): id does not match ^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.status | type) == "string" and (([ "pending","approved","rejected","expired","superseded" ] | index($r.status)) | not))
			    | "record \($rid): unknown status \"\($r.status)\"" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.scope | type) == "string" and (([ "finding","gate" ] | index($r.scope)) | not))
			    | "record \($rid): unknown scope \"\($r.scope)\"" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.severity // null) != null and (([ "low","medium","high","critical" ] | index($r.severity)) | not))
			    | "record \($rid): unknown severity \"\($r.severity)\"" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.approval // null) != null and (($r.approval | type) != "object"))
			    | "record \($rid): `approval` must be an object" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid | ($r.approval // {}) as $a
			    | select(($r.approval // null) != null)
			    | ( $a | keys[] | select(. as $k | known_approval | index($k) | not)
			        | "record \($rid): unknown approval property \"\(.)\"" ) ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | select(($r.approval.approved_by // null) != null and ($r.approval.approved_by == $r.owner))
			    | "record \($rid): approved_by == owner (self-approval)" ),
			  ( [ (.risks // [])[] | select(type == "object") | .id ] as $ids
			    | $ids | group_by(.) | map(select(length > 1)) | .[]
			    | "duplicate record id \"\(.[0])\" — an approval must have exactly one identity" ),
			  ( (.risks // [])[] | select(type == "object")
			    | . as $r | (.id // "?") as $rid
			    | ( ($r.files // [])[]
			        | select((type == "string") and ((test("^([.]/)?[A-Za-z0-9][A-Za-z0-9._/+-]*$") | not) or test("[.][.]")))
			        | "record \($rid): unsafe path \"\(.)\" (absolute, traversing, globbed or control characters)" ) )
			] | join("\n")' "$ACCEPTED_RISKS_FILE" 2>/dev/null || printf 'accepted-risks v2 document could not be validated')
		if [ -n "$_arv2" ]; then
			printf '%s\n' "$_arv2" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "accepted-risks: $_l"; done
			die_cfg "accepted-risk input changes release decisions; refusing to enforce against a document that does not satisfy schema v2 ($ACCEPTED_RISKS_FILE)"
		fi
	fi
	# Accepted-risk input CHANGES RELEASE DECISIONS, so it is validated as executable policy
	# before any record is counted or matched. Previously only "is it JSON?" was checked and the
	# rest was ad-hoc jq with `|| true`, so a jq error over a malformed record produced an EMPTY
	# suppression set rather than a clear configuration failure — safe by accident, but it hid
	# governance corruption and made the loaded/invalid counts disagree with the file.
	_ar_bad=$(jq -r --arg today "$TODAY" '
		def isdate: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
		def realdate:
			# Reject lexicographically-orderable impossibilities such as 9999-99-99, which sort
			# far into the future and therefore never expire.
			(.[5:7] | tonumber) as $m | (.[8:10] | tonumber) as $d
			| ($m >= 1 and $m <= 12 and $d >= 1 and $d <= 31);
		# A repository-relative path built from an explicit safe character set: this rejects
		# absolute paths, traversal, control characters, whitespace, quotes and glob
		# metacharacters in one rule rather than trying to enumerate what is dangerous.
		def safepath:
			type == "string" and (length > 0)
			# A leading `./` is a legitimate spelling of the same repository-relative path and
			# is normalised away before matching, so accept it here rather than rejecting a
			# record for punctuation.
			and test("^([.]/)?[A-Za-z0-9][A-Za-z0-9._/+-]*$")
			and (test("[.][.]") | not);
		[ (.risks // []) | to_entries[]
		  | .key as $i | .value as $r
		  | [
			(if ($r | type) != "object" then "record \($i): not an object" else empty end),
			(if ($r.id // "") == "" then "record \($i): missing id" else empty end),
			(if ($r.gate // "") == "" then "record \($i) (\($r.id // "?")): missing gate" else empty end),
			(if ($r.status // "") | IN("approved","pending","rejected","expired") | not
				then "record \($r.id // $i): unknown status \"\($r.status // "")\"" else empty end),
			(if ($r.scope // "finding") | IN("finding","gate") | not
				then "record \($r.id // $i): unknown scope \"\($r.scope)\"" else empty end),
			(if ($r.expires_at // "") | isdate | not
				then "record \($r.id // $i): expires_at is not YYYY-MM-DD" else empty end),
			(if (($r.expires_at // "") | isdate) and (($r.expires_at) | realdate | not)
				then "record \($r.id // $i): expires_at \"\($r.expires_at)\" is not a real date" else empty end),
			(if ($r.review_at // null) != null and (($r.review_at | isdate | not) or ($r.review_at | realdate | not))
				then "record \($r.id // $i): review_at is not a real YYYY-MM-DD date" else empty end),
			(if ($r.files // null) != null and (($r.files | type) != "array")
				then "record \($r.id // $i): files must be an array" else empty end),
			(if ($r.rule_ids // null) != null and (($r.rule_ids | type) != "array")
				then "record \($r.id // $i): rule_ids must be an array" else empty end),
			(if ($r.components // null) != null and (($r.components | type) != "array")
				then "record \($r.id // $i): components must be an array" else empty end),
			(if ($r.fingerprints // null) != null and (($r.fingerprints | type) != "array")
				then "record \($r.id // $i): fingerprints must be an array" else empty end),
			(($r.files // [])[] | select(safepath | not) | "record \($r.id // $i): unsafe file pattern \"\(.)\" (absolute, traversal, or control characters)"),
			(($r.rule_ids // [])[] | select(type != "string") | "record \($r.id // $i): rule_ids must contain strings"),
			(($r.components // [])[] | select(type != "string") | "record \($r.id // $i): components must contain strings"),
			(($r.fingerprints // [])[] | select(type != "string") | "record \($r.id // $i): fingerprints must contain strings")
		  ] | .[] ]
		+ ( [ (.risks // [])[] | .id // "" ] | group_by(.) | map(select(length > 1)) | map("duplicate record id \"\(.[0])\"") )
		+ ( [ (.risks // [])[] | select((.status // "") == "approved" and ((.expires_at // "") >= $today)) ]
			| group_by(.gate)
			| map(select((map(select((.scope // "finding") == "gate")) | length) > 0
					and (map(select((.scope // "finding") == "finding")) | length) > 0)
				| "gate \(.[0].gate): both a BROAD (scope:gate) and a finding-scoped record are active — conflicting suppression identity") )
		| .[]' "$ACCEPTED_RISKS_FILE" 2>&1) || _ar_bad="accepted-risks file could not be evaluated (malformed structure)"
	if [ -n "$_ar_bad" ]; then
		log_error "accepted-risks file is INVALID: $ACCEPTED_RISKS_FILE"
		printf '%s\n' "$_ar_bad" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "  - $_l"; done
		die_cfg "accepted-risk input changes release decisions; refusing to enforce against an invalid governance file"
	fi
	# REAL calendar dates. The jq pass above proves the shape and rejects an out-of-range
	# month/day, but 2026-02-31, 2026-04-31 and non-leap 2025-02-29 all have the shape of a
	# date without being one — and each sorts as unexpired. The canonical calendar check is
	# cw__valid_date (the control-waiver validator, already sourced); it is reused here rather
	# than approximated a second time in jq.
	_ard=$(jq -r '(.risks // [])[] | "\(.id // "?")\t\(.expires_at // "")\t\(.review_at // "")"' "$ACCEPTED_RISKS_FILE" 2>/dev/null || true)
	_arrc=0
	_artab="$(printf '\t')"
	while IFS="$_artab" read -r _arid _arexp _arrev; do
		[ -n "$_arid" ] || continue
		if ! cw__valid_date "$_arexp"; then
			log_error "accepted-risks: record $_arid: expires_at '$_arexp' is not a real calendar date"; _arrc=1
		fi
		if [ -n "$_arrev" ] && ! cw__valid_date "$_arrev"; then
			log_error "accepted-risks: record $_arid: review_at '$_arrev' is not a real calendar date"; _arrc=1
		fi
	done <<EOF
$_ard
EOF
	[ "$_arrc" -eq 0 ] || die_cfg "accepted-risk input changes release decisions; refusing to enforce against impossible dates in $ACCEPTED_RISKS_FILE"

	# --- bounded lifetime (#223, same governance timing policy as control waivers) --------
	# An accepted risk is a time-boxed exception. Without a ceiling, `expires_at: 9999-12-31`
	# is a permanent suppression wearing a date. The policy mirrors CW_MAX_WAIVER_DAYS:
	#   default 90 · strict 90 · regulated 30 · absolute ceiling 365
	# Configuration may only TIGHTEN it, and an unusable setting is a configuration ERROR —
	# never clamped, normalised or defaulted, because substituting a number enforces a policy
	# nobody chose. Only an UNSET variable uses the documented default.
	AR_MAX_DAYS_DEFAULT=90
	AR_MAX_DAYS_CEILING=365
	AR_MAX_DAYS_REGULATED=30
	if [ "${SS_MAX_ACCEPTED_RISK_DAYS+set}" != "set" ]; then
		_armax="$AR_MAX_DAYS_DEFAULT"
	elif [ -z "$SS_MAX_ACCEPTED_RISK_DAYS" ]; then
		die_cfg "SS_MAX_ACCEPTED_RISK_DAYS is set but empty. Unset it to use the ${AR_MAX_DAYS_DEFAULT}-day default, or give it a value — an empty policy is not a policy."
	elif [ "${#SS_MAX_ACCEPTED_RISK_DAYS}" -gt 9 ]; then
		die_cfg "SS_MAX_ACCEPTED_RISK_DAYS='$SS_MAX_ACCEPTED_RISK_DAYS' is out of range (the absolute ceiling is ${AR_MAX_DAYS_CEILING} days)."
	else
		case "$SS_MAX_ACCEPTED_RISK_DAYS" in
			*[!0-9]*) die_cfg "SS_MAX_ACCEPTED_RISK_DAYS='$SS_MAX_ACCEPTED_RISK_DAYS' is not a whole number of days. A governance duration that cannot be read is a configuration error — it is never clamped or defaulted." ;;
		esac
		_armax=$(cw_decimal "$SS_MAX_ACCEPTED_RISK_DAYS")
		[ "$_armax" -ge 1 ] || die_cfg "SS_MAX_ACCEPTED_RISK_DAYS=$SS_MAX_ACCEPTED_RISK_DAYS is not a usable duration (must be >= 1)."
		[ "$_armax" -le "$AR_MAX_DAYS_CEILING" ] || die_cfg "SS_MAX_ACCEPTED_RISK_DAYS=$_armax exceeds the absolute ${AR_MAX_DAYS_CEILING}-day ceiling. Configuration may TIGHTEN this policy, never loosen it."
		[ "$_armax" -le "$AR_MAX_DAYS_DEFAULT" ] || die_cfg "SS_MAX_ACCEPTED_RISK_DAYS=$_armax exceeds the ${AR_MAX_DAYS_DEFAULT}-day policy maximum. Configuration may TIGHTEN this policy, never loosen it."
	fi
	# regulated tightens to 30 days; strict keeps the 90-day default. A caller-supplied value
	# is honoured only when it is STRICTER than the mode's own maximum.
	case "$MODE" in
		regulated) [ "$_armax" -le "$AR_MAX_DAYS_REGULATED" ] || _armax="$AR_MAX_DAYS_REGULATED" ;;
	esac
	AR_MAX_DAYS="$_armax"
	log_info "accepted-risks: maximum validity window ${AR_MAX_DAYS} days (mode=$MODE, source=$( [ "${SS_MAX_ACCEPTED_RISK_DAYS+set}" = "set" ] && printf 'SS_MAX_ACCEPTED_RISK_DAYS' || printf 'policy default' ))"

	# The window is measured from approved_at for an APPROVED record (that is when the
	# exception was authorised), and from created_at otherwise. A record with neither cannot
	# be bounded at all.
	# Empty fields are emitted as "-": TAB is an IFS *whitespace* character, so `read` with
	# IFS=tab COLLAPSES consecutive tabs and silently shifts every later field into the wrong
	# variable. A placeholder keeps the columns aligned.
	_arw=$(jq -r '(.risks // [])[]
		| [ (.id // "?"), (.status // "-"), (.created_at // "-"), (.approved_at // "-"), (.expires_at // "-") ]
		| map(if . == "" then "-" else . end) | join("\t")' "$ACCEPTED_RISKS_FILE" 2>/dev/null || true)
	_arwrc=0
	_artab2="$(printf '\t')"
	_artoday=$(cw_today_utc) || die_cfg "no trusted UTC date is available to judge accepted-risk validity windows"
	_artodayn=$(cw__days "$_artoday")
	while IFS="$_artab2" read -r _wid _wst _wcre _wapp _wexp; do
		[ -n "$_wid" ] || continue
		# Only APPROVED records suppress anything, so only they are bounded here.
		[ "$_wst" = "approved" ] || continue
		[ "$_wapp" = "-" ] && _wapp=""
		[ "$_wcre" = "-" ] && _wcre=""
		[ "$_wexp" = "-" ] && _wexp=""
		_wfrom="$_wapp"
		[ -n "$_wfrom" ] || _wfrom="$_wcre"
		if [ -z "$_wfrom" ] || [ -z "$_wexp" ]; then
			# A LEGACY record (v1.1: no approved_at, no created_at) carries no authorisation
			# date, so its window cannot be measured at all. The assurance modes refuse it —
			# an unbounded exception is exactly what this policy exists to prevent — while the
			# visibility modes report it as the migration debt it is (see the accepted-risk
			# schema v2 migration policy in docs/).
			case "$MODE" in
				strict | regulated)
					log_error "accepted-risks: record $_wid is approved but carries no approved_at or created_at, so its validity window cannot be bounded. '$MODE' requires a bounded exception — migrate the record to accepted-risk schema v2."
					_arwrc=1 ;;
				*)
					log_warn "accepted-risks: DEPRECATED — record $_wid has no approved_at/created_at, so its ${AR_MAX_DAYS}-day validity window cannot be enforced. This is tolerated in '$MODE' only; strict and regulated refuse it. Migrate to accepted-risk schema v2." ;;
			esac
			continue
		fi
		if ! cw__valid_date "$_wfrom"; then
			log_error "accepted-risks: record $_wid: '$_wfrom' is not a real calendar date"; _arwrc=1; continue
		fi
		_wfromn=$(cw__days "$_wfrom"); _wexpn=$(cw__days "$_wexp")
		# A future authorisation date is a pre-positioned approval, not clock skew.
		if [ "$_wfromn" -gt $((_artodayn + 1)) ]; then
			_wlbl=created_at; [ -n "$_wapp" ] && _wlbl=approved_at
			log_error "accepted-risks: record $_wid: $_wlbl '$_wfrom' is in the future (today is $_artoday UTC, clock-skew tolerance 1d)"
			_arwrc=1; continue
		fi
		# An expiry BEFORE the authorisation date is not a short window, it is a contradiction:
		# the record claims to have been approved after it stopped applying.
		if [ "$_wexpn" -lt "$_wfromn" ]; then
			_wlbl2=created_at; [ -n "$_wapp" ] && _wlbl2=approved_at
			log_error "accepted-risks: record $_wid: expires_at '$_wexp' is BEFORE $_wlbl2 '$_wfrom'"
			_arwrc=1; continue
		fi
		if [ $((_wexpn - _wfromn)) -gt "$AR_MAX_DAYS" ]; then
			log_error "accepted-risks: record $_wid: validity window $_wfrom..$_wexp is $((_wexpn - _wfromn)) days, over the ${AR_MAX_DAYS}-day maximum for mode '$MODE'. Renew with a NEW record that supersedes this one — do not extend the original approval."
			_arwrc=1
		fi
	done <<EOF
$_arw
EOF
	[ "$_arwrc" -eq 0 ] || die_cfg "accepted-risk records exceed the governed validity window in $ACCEPTED_RISKS_FILE"

	AR_LOADED=$(jq '(.risks // []) | length' "$ACCEPTED_RISKS_FILE")
	AR_PENDING=$(jq '[(.risks // [])[] | select(.status != "approved")] | length' "$ACCEPTED_RISKS_FILE")
	AR_EXPIRED=$(jq --arg today "$TODAY" '[(.risks // [])[] | select(.status == "approved" and ((.expires_at // "") < $today))] | length' "$ACCEPTED_RISKS_FILE")
	# Records approved + unexpired but missing owner/reason or targeting a
	# non-suppressible gate are "invalid" and ignored.
	AR_INVALID=$(jq -r --arg today "$TODAY" --arg ok "$SUPPRESSIBLE_GATES" '
		($ok | split(" ")) as $S
		| [ (.risks // [])[]
			| select(.status == "approved" and ((.expires_at // "") >= $today))
			| select(((.owner // "") == "") or ((.reason // "") == "") or (((.gate // "") | IN($S[])) | not)) ] | length' "$ACCEPTED_RISKS_FILE")
	# Classify each VALID record (approved, unexpired, owner+reason, suppressible gate) by
	# effective scope. Default scope is "finding".
	_valid=$(jq -r --arg today "$TODAY" --arg ok "$SUPPRESSIBLE_GATES" '
	# `ss_constrains` — TRUE only when a finding-scope record actually narrows something.
	# `has(…)` was the test, and it accepts a record whose every dimension is PRESENT BUT
	# EMPTY — while the matcher below treats an empty array/string as a wildcard on that
	# dimension. A record with rule_ids/files/components/fingerprints all set to []
	# therefore passed the ambiguity check and then matched EVERY finding, while still being
	# reported as the quiet `scope: finding` rather than the loud `scope: gate`. That is the
	# "one accepted risk silently covers everything" failure this suppression model exists to
	# prevent, reached through an empty array.
	def ss_constrains:
		(((.rule_id // "") | tostring | length) > 0)
		or (((.rule_ids // []) | length) > 0)
		or (((.files // []) | length) > 0)
		or (((.components // []) | length) > 0)
		or (((.sources // []) | length) > 0)
		or (((.source // "") | tostring | length) > 0)
		or (((.fingerprints // []) | length) > 0);
		($ok | split(" ")) as $S
		| (.risks // [])[]
		| select(.status == "approved" and ((.expires_at // "") >= $today) and ((.owner // "") != "") and ((.reason // "") != "") and (((.gate // "") | IN($S[]))))
		| (.scope // "finding") as $scope
		| (ss_constrains) as $hasmatch
		| if $scope == "gate" then "gate|\(.gate)|\(.id // "?")"
		  elif $hasmatch then "finding|\(.gate)|\(.id // "?")|\(.rule_id // "")|\((.files // []) | join(","))"
		  else "legacy|\(.gate)|\(.id // "?")" end' "$ACCEPTED_RISKS_FILE" 2>/dev/null || true)
	if [ -n "$_valid" ]; then
		while IFS='|' read -r _kind _g _id _rule _files; do
			[ -n "$_kind" ] || continue
			case "$_kind" in
				gate)
					case "$GATE_SCOPE_SUPPRESSED" in *" $_g "*) : ;; *) GATE_SCOPE_SUPPRESSED="${GATE_SCOPE_SUPPRESSED}${_g} " ;; esac
					AR_BROAD_DETAIL="${AR_BROAD_DETAIL}${_g}|${_id}
" ;;
				finding)
					AR_FINDING_DETAIL="${AR_FINDING_DETAIL}${_g}|${_id}|${_rule}|${_files}
"
					case "$_g" in
						unsafe_docker | medium_vulnerabilities) : ;;
						*) log_warn "accepted-risks: finding-scope record '$_id' targets '$_g'; finding identity is defined for unsafe_docker and medium_vulnerabilities — NOT suppressing (use \"scope\":\"gate\" for broad)." ;;
					esac ;;
				legacy)
					AR_LEGACY_WARN=$((AR_LEGACY_WARN + 1))
					log_warn "accepted-risks: record '$_id' (gate $_g) has no scope and no rule_id/files — ambiguous; NOT suppressing. Add \"scope\":\"finding\" + rule_id/files, or \"scope\":\"gate\" for broad." ;;
			esac
		done <<EOF
$_valid
EOF
	fi
	log_info "accepted-risks: loaded $AR_LOADED (pending $AR_PENDING, expired $AR_EXPIRED, invalid $AR_INVALID, legacy-unscoped $AR_LEGACY_WARN ignored)"
fi

# Broad (scope:gate) suppression check.
is_gate_suppressed() {
	case "$GATE_SCOPE_SUPPRESSED" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# --- evaluate gates ----------------------------------------------------------
TS=$(timestamp_utc)
ensure_dir "$OUTPUT_DIR"

FAILED=""        # space-separated failed gate keys
ACCEPTED=""      # space-separated gate keys suppressed by an approved accepted-risk
EVAL_LINES=""    # "key|enabled|value|result" per line

# add_eval — record one gate evaluation row (key|enabled|value|result).
add_eval() {
	# add_eval <key> <enabled-bool> <value-json> <result>
	EVAL_LINES="${EVAL_LINES}$1|$2|$3|$4
"
	if [ "$4" = "fail" ]; then
		FAILED="$FAILED $1"
	fi
}

# Count-based gate: fails when the count is > 0 and the flag is enabled — UNLESS a
# valid approved accepted-risk suppresses this gate, in which case it is reported as
# "accepted-risk" (the raw count is preserved, not zeroed) and does not fail.
eval_count_gate() {
	_key=$1
	_flag=$(gate_flag "$_key")
	_val=$(jqr ".summary.$_key")
	# ABSENT is legitimately 0: an older summary predating a gate simply omits the key,
	# and that back-compat promise is documented. Everything else is NOT.
	#
	# FAIL CLOSED (v2.0.2 security hotfix). This previously read
	#   case "$_val" in '' | *[!0-9]*) _val=0 ;; esac
	# which coerced EVERY malformed value to a clean 0: floats (3.5), negatives (-5),
	# strings ("not-a-number") and jq errors all evaluated as `pass`. A count we cannot
	# read is untrusted evidence, not an absence of findings, so it is now a hard
	# configuration error. Negative counts additionally have to die here because the
	# builder SUMS across collectors — one negative can cancel another scanner's real
	# findings to zero.
	if [ "$_val" = "null" ]; then
		# An ENABLED gate whose summary key is ABSENT is an evidence-contract mismatch, not a
		# clean zero: it is how a v1/v2.0 summary could be replayed under a newer, stricter
		# gate set. Backward compatibility for an older summary is safe only while the gate is
		# DISABLED.
		if [ "$_flag" = "true" ]; then
			if [ -n "$SUMMARY_CONTRACT" ]; then
				die_cfg "gate '$_key' is ENABLED and the summary declares gate contract '$SUMMARY_CONTRACT', but carries no '$_key' field. A declared contract must be complete — rebuild with scripts/build-security-summary.sh."
			fi
			case "$MODE" in
				strict | regulated)
					die_cfg "gate '$_key' is ENABLED but the summary carries no '$_key' field and declares no gate_contract_version. Refusing to certify '$MODE' from a legacy summary under a newer gate set — rebuild it with scripts/build-security-summary.sh from this engine version (docs/security-summary-schema.md)." ;;
				*)
					log_warn "gate '$_key' is enabled but the summary carries no '$_key' field (legacy summary: no gate_contract_version). Reading it as 0 is DOCUMENTED LEGACY TOLERANCE for $MODE only — strict/regulated refuse it. Rebuild the summary to close this." ;;
			esac
		fi
		_val=0
	else
		case "$_val" in
			'' | *[!0-9]*)
				die_cfg "summary.$_key must be a non-negative integer, got '$_val'. Untrusted evidence never reads as a clean 0." ;;
		esac
		ss_count_valid "$_val" \
			|| die_cfg "summary.$_key is $_val, above the bounded-count maximum $SS_MAX_COUNT. A count shell arithmetic cannot represent is untrusted evidence; it is never clamped or read as a clean 0." # (#146)
	fi
	if [ "$_flag" = "true" ]; then
		if [ "$_val" -gt 0 ]; then
			if is_gate_suppressed "$_key"; then
				add_eval "$_key" true "$_val" "accepted-risk"
				ACCEPTED="$ACCEPTED $_key"
			else
				add_eval "$_key" true "$_val" fail
			fi
		else
			add_eval "$_key" true "$_val" pass
		fi
	else
		add_eval "$_key" false "$_val" skipped
	fi
}

# unsafe_docker (v0.1.8): finding-scoped acceptance. A broad scope:gate record marks the
# whole gate accepted-risk. Otherwise per-finding matching against the raw Hadolint report
# (rule_id + file): the gate is accepted-risk ONLY when every finding is matched; any
# unaccepted finding fails the gate. The summary count (total) is always preserved.
UD_TOTAL=0; UD_ACCEPTED=0; UD_UNACCEPTED=0; UD_SCOPE="none"; UD_DETAIL="[]"
# eval_unsafe_docker — evaluate the unsafe docker gate and record its result.
eval_unsafe_docker() {
	_key="unsafe_docker"
	_flag=$(gate_flag "$_key")
	# Use the SAME strict parser as every other count gate. This function kept the old
	# coercion, so a negative, fractional, string, boolean or unreadable unsafe_docker count
	# became a clean 0 and the gate recorded `pass` — the exact fail-open the generic
	# evaluator had already closed.
	_val=$(jqr ".summary.$_key")
	if [ "$_val" = "null" ]; then
		if [ "$_flag" = "true" ]; then
			if [ -n "$SUMMARY_CONTRACT" ]; then
				die_cfg "gate 'unsafe_docker' is ENABLED and the summary declares gate contract '$SUMMARY_CONTRACT' but carries no 'unsafe_docker' field. A declared contract must be complete."
			fi
			case "$MODE" in
				strict | regulated)
					die_cfg "gate 'unsafe_docker' is ENABLED but the summary carries no 'unsafe_docker' field and declares no gate_contract_version. Refusing to certify '$MODE' from a legacy summary." ;;
				*) log_warn "gate 'unsafe_docker' is enabled but the summary carries no 'unsafe_docker' field (legacy summary). Documented legacy tolerance for $MODE only." ;;
			esac
		fi
		_val=0
	else
		case "$_val" in
			'' | *[!0-9]*)
				die_cfg "summary.unsafe_docker must be a non-negative integer, got '$_val'. Untrusted evidence never reads as a clean 0." ;;
		esac
		ss_count_valid "$_val" \
			|| die_cfg "summary.unsafe_docker is $_val, above the bounded-count maximum $SS_MAX_COUNT. A count shell arithmetic cannot represent is untrusted evidence; it is never clamped or read as a clean 0." # (#146)
	fi
	UD_TOTAL=$_val
	if [ "$_flag" != "true" ]; then add_eval "$_key" false "$_val" skipped; return; fi
	if [ "$_val" -eq 0 ]; then add_eval "$_key" true 0 pass; return; fi
	# Broad scope:gate record → entire gate accepted-risk (reported as broad).
	if is_gate_suppressed "$_key"; then
		UD_SCOPE="gate"; UD_ACCEPTED=$_val; UD_UNACCEPTED=0
		add_eval "$_key" true "$_val" "accepted-risk"; ACCEPTED="$ACCEPTED $_key"
		log_info "unsafe_docker: BROAD (scope:gate) accepted-risk — total $_val, all accepted."
		return
	fi
	UD_SCOPE="finding"
	# Finding-scope matching normalizes ALL unsafe_docker raw sources into one shape
	# {source, rule_id, file, severity} and matches each against finding-scope records
	# (rule_id + files). Sources (v0.1.10):
	#   hadolint.json          -> rule_id = .code (DL3018/DL3008/...), error/warning only
	#   docker-base-digest.json-> rule_id = .code (SS_DOCKER_BASE_DIGEST), all findings
	# A source whose raw report is missing/invalid is "unaccounted": its share of the
	# summary total (total - findings we could read) is treated as UNACCEPTED so the gate
	# fails closed (never silently passes a source we cannot inspect).
	[ -f "$RAW_HADOLINT" ] && jq -e 'type=="array"' "$RAW_HADOLINT" >/dev/null 2>&1 && _HJ="$RAW_HADOLINT" || _HJ="/dev/null"
	[ -f "$RAW_DOCKER_BASE" ] && jq -e 'type=="array"' "$RAW_DOCKER_BASE" >/dev/null 2>&1 && _DJ="$RAW_DOCKER_BASE" || _DJ="/dev/null"
	_acct=$(jq -n \
		--slurpfile risks "$ACCEPTED_RISKS_FILE" \
		--slurpfile hado "$_HJ" \
		--slurpfile base "$_DJ" \
		--arg today "$TODAY" --argjson total "$_val" '
		def ss_constrains:
			(((.rule_id // "") | tostring | length) > 0)
			or (((.rule_ids // []) | length) > 0)
			or (((.files // []) | length) > 0)
			or (((.components // []) | length) > 0)
			or (((.fingerprints // []) | length) > 0);
		def norm: sub("^\\./"; "");
		([ ($risks[0].risks // [])[]
			| select(.gate == "unsafe_docker" and .status == "approved" and ((.expires_at // "") >= $today)
				and ((.owner // "") != "") and ((.reason // "") != "")
				and ((.scope // "finding") == "finding")
				# A record whose every dimension is present but EMPTY constrains nothing and
				# would match every finding while reporting as the quiet finding scope.
				and (ss_constrains)) ]) as $fs
		# Normalize each source into {source, rule_id, file, severity}.
		| ( [ (($hado[0] // []))[]
				| select((.level // "" | ascii_downcase) == "error" or (.level // "" | ascii_downcase) == "warning")
				| { source: "hadolint", rule_id: (.code // ""), file: ((.file // "") | norm),
				    line: (.line // null), severity: (.level // "warning") } ]
			+ [ (($base[0] // []))[]
				| { source: "docker-base-digest", rule_id: (.code // "SS_DOCKER_BASE_DIGEST"),
				    file: ((.file // "") | norm), line: (.line // null), severity: "warning" } ]
		) as $finds
		| [ $finds[]
			| . as $f
			| ( ( first( $fs[]
					| select(
						( ((.rule_id // "") == "") or (.rule_id == $f.rule_id) or (((.rule_ids // []) | index($f.rule_id)) != null) )
						# EXACT, repository-rooted path match. Suffix and basename matching meant a
						# waiver for `Dockerfile` covered EVERY Dockerfile in the repository, and
						# `service/Dockerfile` covered any deeper path ending that way — an
						# exception silently wider than the one its author reviewed.
						and ( (((.files // []) | length) == 0)
							or any((.files // [])[]; (. | norm) == $f.file) )
					)
					| .id ) ) // null ) as $rid
			| { source: $f.source, rule_id: $f.rule_id, file: $f.file, line: $f.line,
				accepted: ($rid != null), risk_id: ($rid // "") } ]
		# Deduplicate identical findings before counting: a source reporting the same
		# {source, rule_id, file} twice inflated `accepted` and could push it past the total.
		| ( . as $all | reduce $all[] as $f ({seen: {}, out: []};
				("\($f.source)|\($f.rule_id)|\($f.file)|\($f.line)") as $k
				| if .seen[$k] then . else .seen[$k] = true | .out += [$f] end) | .out ) as $uniq
		| ( $uniq | length ) as $accounted
		| ( [ $uniq[] | select(.accepted) ] | length ) as $acc
		| ( [ $uniq[] | select(.accepted | not) ] | length ) as $unacc_visible
		| ( (if $total > $accounted then ($total - $accounted) else 0 end) ) as $unaccounted_sources
		# The aggregate and the raw evidence must AGREE. Only the undercount direction was
		# handled; when the raw sources hold MORE distinct findings than the summary counts, the
		# aggregate is wrong — and if every extra finding matched a record, `accepted` could
		# exceed `total` while `unaccepted` stayed 0: acceptance resting on a contradiction.
		| { total: $total, accounted: $accounted, accepted: $acc,
			unaccepted: ($unacc_visible + $unaccounted_sources),
			unaccounted_sources: $unaccounted_sources,
			overcount: ($accounted > $total), detail: $uniq }' 2>/dev/null || printf '')
	if [ -z "$_acct" ]; then
		UD_ACCEPTED=0; UD_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_warn "unsafe_docker: could not compute finding-scope accounting; gate FAILS (count $_val preserved)."
		return
	fi
	UD_ACCEPTED=$(printf '%s' "$_acct" | jq '.accepted')
	UD_UNACCEPTED=$(printf '%s' "$_acct" | jq '.unaccepted')
	_unacc_src=$(printf '%s' "$_acct" | jq '.unaccounted_sources')
	_overcount=$(printf '%s' "$_acct" | jq -r '.overcount')
	UD_DETAIL=$(printf '%s' "$_acct" | jq -c '.detail')
	if [ "$_overcount" = "true" ]; then
		_acct_n=$(printf '%s' "$_acct" | jq '.accounted')
		UD_ACCEPTED=0; UD_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_error "unsafe_docker: the raw reports hold $_acct_n distinct finding(s) but summary.unsafe_docker=$_val."
		log_error "  The aggregate contradicts its own evidence, so no accepted-risk verdict can be derived from it."
		die_cfg "refusing to evaluate unsafe_docker accepted-risk against a contradictory count"
	fi
	if [ "$UD_UNACCEPTED" -eq 0 ] && [ "$UD_ACCEPTED" -gt 0 ]; then
		add_eval "$_key" true "$_val" "accepted-risk"; ACCEPTED="$ACCEPTED $_key"
		log_info "unsafe_docker: finding-scoped accepted-risk — total $_val, accepted $UD_ACCEPTED, unaccepted 0 (hadolint + docker-base-digest)."
	else
		add_eval "$_key" true "$_val" fail
		[ "$_unacc_src" -gt 0 ] 2>/dev/null && log_warn "unsafe_docker: $_unacc_src finding(s) from a raw source that could not be read (missing/invalid) — treated as UNACCEPTED."
		log_info "unsafe_docker: total $_val, accepted $UD_ACCEPTED, unaccepted $UD_UNACCEPTED → gate FAILS (unaccepted findings present)."
	fi
}

# medium_vulnerabilities (v2.3): finding-scoped acceptance, the same shape as unsafe_docker.
#
# Accepting ONE medium vulnerability used to require suppressing the WHOLE gate, so every
# unrelated medium finding that appeared later was covered by that older, broader exception.
# Finding identity comes from scripts/normalize-findings.sh, which derives
# {source, rule_id, component, version, file, fingerprint} from the raw scanner reports.
#
# A record matches a finding when EVERY dimension it declares matches (conjunctive, so adding
# a dimension can only narrow an exception, never widen it):
#   fingerprints[] -> exact canonical fingerprint     components[] -> package/component name
#   rule_id / rule_ids -> advisory or rule identifier files[]      -> path (exact/suffix/basename)
#
# The gate is accepted-risk ONLY when every counted finding is matched. Findings the raw
# sources could not account for (missing/invalid/unenumerable report) are UNACCEPTED, so an
# unreadable source can never turn into a clean pass. The raw count is always preserved.
MV_TOTAL=0; MV_ACCEPTED=0; MV_UNACCEPTED=0; MV_SCOPE="none"; MV_DETAIL="[]"
# eval_medium_vulnerabilities — evaluate the medium-vulnerability gate and record its result.
eval_medium_vulnerabilities() {
	_key="medium_vulnerabilities"
	_flag=$(gate_flag "$_key")
	_val=$(jqr ".summary.$_key")
	if [ "$_val" = "null" ]; then
		_val=0
	else
		case "$_val" in
			'' | *[!0-9]*)
				die_cfg "summary.$_key must be a non-negative integer, got '$_val'. Untrusted evidence never reads as a clean 0." ;;
		esac
		ss_count_valid "$_val" \
			|| die_cfg "summary.$_key is $_val, above the bounded-count maximum $SS_MAX_COUNT. A count shell arithmetic cannot represent is untrusted evidence; it is never clamped or read as a clean 0." # (#146)
	fi
	MV_TOTAL=$_val
	if [ "$_flag" != "true" ]; then add_eval "$_key" false "$_val" skipped; return; fi
	if [ "$_val" -eq 0 ]; then add_eval "$_key" true 0 pass; return; fi
	if is_gate_suppressed "$_key"; then
		MV_SCOPE="gate"; MV_ACCEPTED=$_val; MV_UNACCEPTED=0
		add_eval "$_key" true "$_val" "accepted-risk"; ACCEPTED="$ACCEPTED $_key"
		log_warn "medium_vulnerabilities: BROAD (scope:gate) accepted-risk — total $_val, all accepted. Broad suppression also covers findings that appear LATER; prefer finding-scoped records (components/fingerprints)."
		return
	fi
	# No finding-scope record for this gate at all -> ordinary count gate, unchanged.
	case "$AR_FINDING_DETAIL" in
		*"$_key|"*) ;;
		# Every other failing path records the count as UNACCEPTED. Leaving it at 0 here
		# published `accepted: 0, unaccepted: 0` for a non-zero total, which a consumer of
		# accepted_risks.medium_vulnerabilities reads as "nothing unaccepted" on a FAILED gate.
		*) MV_ACCEPTED=0; MV_UNACCEPTED=$_val; add_eval "$_key" true "$_val" fail; return ;;
	esac
	MV_SCOPE="finding"
	_norm="$SCRIPT_DIR/normalize-findings.sh"
	_finds=""
	if [ -f "$_norm" ]; then
		_finds=$(sh "$_norm" --gate medium_vulnerabilities --raw-dir "$RAW_DIR" 2>/dev/null) || _finds=""
	fi
	if [ -z "$_finds" ] || ! printf '%s' "$_finds" | jq -e 'type == "array"' >/dev/null 2>&1; then
		MV_ACCEPTED=0; MV_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_warn "medium_vulnerabilities: finding identity could not be derived from '$RAW_DIR' — every finding is UNACCEPTED and the gate FAILS (count $_val preserved)."
		return
	fi
	_acct=$(printf '%s' "$_finds" | jq \
		--slurpfile risks "$ACCEPTED_RISKS_FILE" \
		--arg today "$TODAY" --argjson total "$_val" '
		def ss_constrains:
			(((.rule_id // "") | tostring | length) > 0)
			or (((.rule_ids // []) | length) > 0)
			or (((.files // []) | length) > 0)
			or (((.components // []) | length) > 0)
			or (((.sources // []) | length) > 0)
			or (((.source // "") | tostring | length) > 0)
			or (((.fingerprints // []) | length) > 0);
		def norm: (. // "") | tostring | sub("^\\./"; "");
		. as $finds
		| ([ ($risks[0].risks // [])[]
			| select(.gate == "medium_vulnerabilities" and .status == "approved"
				and ((.expires_at // "") >= $today)
				and ((.owner // "") != "") and ((.reason // "") != "")
				and ((.scope // "finding") == "finding")
				and (ss_constrains)) ]) as $fs
		| [ $finds[]
			| . as $f
			| ( ( first( $fs[]
					| select(
						( (((.fingerprints // []) | length) == 0)
							or (((.fingerprints // []) | index($f.fingerprint)) != null) )
						and ( (((.components // []) | length) == 0)
							or (((.components // []) | index($f.component)) != null) )
						and ( ((.rule_id // "") == "" and ((.rule_ids // []) | length) == 0)
							or (.rule_id == $f.rule_id)
							or (((.rule_ids // []) | index($f.rule_id)) != null) )
						# SOURCE is a first-class dimension. Without it, `components +
						# rule_id` accepted the same advisory reported by EVERY scanner and
						# ecosystem, even when the reviewer had examined the finding from
						# exactly one producer. Declaring it can only narrow the record.
						and ( ((.source // "") == "" and ((.sources // []) | length) == 0)
							or (.source == $f.source)
							or (((.sources // []) | index($f.source)) != null) )
						# Paths on the RECORD were normalized; the path on the FINDING
						# was not. A finding with no `file` — package-level advisories
						# carry none — made `null | endswith(...)` abort the WHOLE jq
						# program, so the accounting was thrown away and reported as
						# "could not compute" even for findings that had already
						# resolved. A finding with no path cannot satisfy a path-scoped
						# record.
						# EXACT, repository-rooted path match — the same rule the
						# unsafe_docker gate uses. Suffix and basename matching meant an
						# exception for `service-a/package-lock.json` also covered
						# `service-b/package-lock.json`, and any file added later with that
						# basename: an exception silently wider than the one its author
						# reviewed. A finding with no path cannot satisfy a path-scoped
						# record at all.
						and ( (((.files // []) | length) == 0)
							or ( ($f.file | norm) as $ff
								| ($ff != "")
								and any((.files // [])[]; (. | norm) == $ff) ) )
					)
					| .id ) ) // null ) as $rid
			| { source: $f.source, rule_id: $f.rule_id, component: $f.component,
				version: $f.version, file: $f.file, fingerprint: $f.fingerprint,
				accepted: ($rid != null), risk_id: ($rid // "") } ]
		# DEDUPLICATE on the canonical identity first. A source reporting the same finding
		# twice would otherwise inflate `accounted` and `accepted`, and could push `accepted`
		# past `total` on its own.
		| ( . as $all | reduce $all[] as $d ({seen:{}, out:[]};
				($d.fingerprint) as $k
				| if .seen[$k] then . else .seen[$k] = true | .out += [$d] end) | .out ) as $uniq
		| ( $uniq | length ) as $accounted
		| ( [ $uniq[] | select(.accepted) ] | length ) as $acc
		| ( [ $uniq[] | select(.accepted | not) ] | length ) as $unacc_visible
		| ( (if $total > $accounted then ($total - $accounted) else 0 end) ) as $unaccounted_sources
		# The aggregate and the raw evidence must AGREE IN BOTH DIRECTIONS. Only the
		# undercount was handled: when the raw sources hold MORE distinct findings than the
		# summary counts, the aggregate is wrong — and if every extra finding matched a
		# record, `accepted` could exceed `total` while `unaccepted` stayed 0, an acceptance
		# resting on a contradiction. `overcount` is reported and the caller fails closed.
		| { total: $total, accounted: $accounted, accepted: $acc,
			unaccepted: ($unacc_visible + $unaccounted_sources),
			unaccounted_sources: $unaccounted_sources,
			overcount: ($accounted > $total), detail: $uniq }' 2>/dev/null || printf '')
	if [ -z "$_acct" ]; then
		MV_ACCEPTED=0; MV_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_warn "medium_vulnerabilities: could not compute finding-scope accounting; gate FAILS (count $_val preserved)."
		return
	fi
	MV_ACCEPTED=$(printf '%s' "$_acct" | jq '.accepted')
	MV_UNACCEPTED=$(printf '%s' "$_acct" | jq '.unaccepted')
	_unacc_src=$(printf '%s' "$_acct" | jq '.unaccounted_sources')
	MV_DETAIL=$(printf '%s' "$_acct" | jq -c '.detail')
	_overcount=$(printf '%s' "$_acct" | jq -r '.overcount')
	# The aggregate contradicts its own raw evidence: the reports hold MORE distinct findings
	# than summary.medium_vulnerabilities claims. Accepting on that basis would rest the
	# decision on counts that cannot both be true, so it fails closed regardless of matching.
	if [ "$_overcount" = "true" ]; then
		_accounted=$(printf '%s' "$_acct" | jq -r '.accounted')
		MV_ACCEPTED=0; MV_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_error "medium_vulnerabilities: the raw reports contain $_accounted distinct findings but the summary counts $_val. An aggregate that disagrees with its own evidence cannot authorise an acceptance — gate FAILS."
		return
	fi
	# Arithmetic invariants. These cannot hold if the accounting is sound, so a violation is a
	# defect rather than a policy outcome, and it is never resolved in favour of acceptance.
	if [ "$MV_ACCEPTED" -gt "$_val" ] 2>/dev/null; then
		MV_ACCEPTED=0; MV_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_error "medium_vulnerabilities: accounting reports more accepted findings than the total ($MV_ACCEPTED > $_val) — refusing to treat an impossible count as an acceptance."
		return
	fi
	if [ "$((MV_ACCEPTED + MV_UNACCEPTED))" -ne "$_val" ] 2>/dev/null; then
		MV_ACCEPTED=0; MV_UNACCEPTED=$_val
		add_eval "$_key" true "$_val" fail
		log_error "medium_vulnerabilities: accepted + unaccepted does not equal the total ($MV_ACCEPTED + $MV_UNACCEPTED != $_val) — the accounting does not describe this evidence; gate FAILS."
		return
	fi
	if [ "$MV_UNACCEPTED" -eq 0 ] && [ "$MV_ACCEPTED" -gt 0 ]; then
		add_eval "$_key" true "$_val" "accepted-risk"; ACCEPTED="$ACCEPTED $_key"
		log_info "medium_vulnerabilities: finding-scoped accepted-risk — total $_val, accepted $MV_ACCEPTED, unaccepted 0."
	else
		add_eval "$_key" true "$_val" fail
		[ "$_unacc_src" -gt 0 ] 2>/dev/null && log_warn "medium_vulnerabilities: $_unacc_src finding(s) could not be identified from the raw reports (missing/invalid/unenumerable) — treated as UNACCEPTED."
		log_info "medium_vulnerabilities: total $_val, accepted $MV_ACCEPTED, unaccepted $MV_UNACCEPTED → gate FAILS (unaccepted findings present)."
	fi
}

# Boolean gate: fails when summary.<key> == true and the flag is enabled. Absent key reads
# as false (no trigger). Used by missing_coverage_evidence (no evidence.present sidecar).
eval_bool_gate() {
	_key=$1
	_flag=$(gate_flag "$_key")
	_v=$(jqr ".summary.$_key")   # true|false|null (RENDERED)
	# `jq -r` renders the STRING "true" and the BOOLEAN true identically, so the rendered value
	# alone cannot tell an evidence flag from a string that looks like one. Read the type too.
	_vt=$(jqr ".summary.$_key | type")
	# ONLY the two canonical booleans are readable. Everything else — a number, a string, an
	# array, an object, a jq/read error — used to normalise to `false` and PASS, so a corrupt or
	# hand-built summary cleared an ENABLED missing-evidence control (missing_coverage_evidence,
	# empty_test_suite, missing_architecture_evidence, missing_acceptance_evidence …). An
	# unreadable evidence flag is untrusted evidence, not an absence of findings.
	case "$_v" in
		true | false)
			[ "$_vt" = "boolean" ] || die_cfg "summary.$_key must be a boolean, got a $_vt that renders as '$_v'. A string that looks like a boolean is not one." ;;
		null)
			# Absent. These evidence booleans are POLICY-OVERLAY output: the builder emits them
			# only when run with --profile, because deciding "was this evidence expected?" needs
			# the profile's applicability. So their absence means one of two different things:
			#
			#   * the overlay RAN and did not set this key -> the summary is incomplete for the
			#     contract it declares (a build defect);
			#   * the overlay never ran (no --profile) -> nothing could judge applicability, so
			#     an enabled evidence gate cannot be certified at all.
			#
			# Either way it is not a clean `false`; only the message differs, and only the
			# visibility modes tolerate the second case.
			if [ "$_flag" = "true" ]; then
				_overlay=$(jqr '.summary.required_tool_failures')
				if [ "$_overlay" != "null" ] && [ -n "$SUMMARY_CONTRACT" ]; then
					die_cfg "gate '$_key' is ENABLED, the summary declares gate contract '$SUMMARY_CONTRACT' and carries a tool-policy overlay, but has no '$_key' field. A declared contract must be complete — rebuild with scripts/build-security-summary.sh."
				fi
				case "$MODE" in
					strict | regulated)
						die_cfg "gate '$_key' is ENABLED but the summary carries no '$_key' field. Evidence gates need the tool-policy overlay to judge applicability — rebuild with scripts/build-security-summary.sh --profile <name>. Refusing to certify '$MODE' without it." ;;
					*)
						log_warn "gate '$_key' is enabled but the summary carries no '$_key' field (no tool-policy overlay, or a legacy summary). Documented tolerance for $MODE only — build with --profile to close this." ;;
				esac
			fi ;;
		*)
			die_cfg "summary.$_key must be a boolean (true/false), got '$_v'. An unreadable evidence flag never reads as a clean 'false'." ;;
	esac
	_trig=false; [ "$_v" = "true" ] && _trig=true
	if [ "$_flag" = "true" ]; then
		if [ "$_trig" = "true" ]; then add_eval "$_key" true "$_trig" fail; else add_eval "$_key" true "$_trig" pass; fi
	else
		add_eval "$_key" false "$_trig" skipped
	fi
}

# Evidence/boolean gate: fails when summary flag is true OR evidence present==false.
eval_missing_gate() {
	_key=$1            # missing_sbom | missing_release_evidence
	_evpath=$2         # evidence.sbom.present | evidence.release_evidence.present
	_flag=$(gate_flag "$_key")
	_missing=$(jqr ".summary.$_key")        # true|false (validated)
	_present=$(jqr ".$_evpath")             # true|false|null
	_trig=false
	if [ "$_missing" = "true" ]; then _trig=true; fi
	if [ "$_present" = "false" ]; then _trig=true; fi
	# UNATTRIBUTED CONTENT IS NOT EVIDENCE in an enforcing mode. The builder can only decide
	# that bytes parse; whether anything BINDS them to this run is a policy question, and it
	# used to depend on the caller remembering `--require-evidence-provenance`. A summary that
	# forgot the flag presented unbound content as present, so assurance rested on an optional
	# producer-side argument. baseline/strict/regulated decide it here instead.
	_prov=$(jqr ".$(printf '%s' "$_evpath" | sed 's/\.present$/.verification.provenance/')")
	case "$MODE" in
		baseline | strict | regulated)
			# `present: true` MEANS `provenance: "verified"` here. The earlier form exempted a
			# missing/null value, which reintroduced the bypass through OMISSION: a summary
			# that simply left out the verification object — `{"sbom":{"present":true}}` —
			# read as attributed evidence, because jq returned null and null was excluded.
			# Absent, empty and unknown are all "not verified"; only the literal `verified`
			# satisfies an evidence gate in an enforcing mode.
			if [ "$_present" = "true" ] && [ "$_prov" != "verified" ]; then
				_trig=true
				case "$_prov" in
					null | '')
						log_warn "$_key: the summary claims the artifact is present but records NO verification provenance. Absence is not attribution — in '$MODE' unattributed content does not count as evidence." ;;
					*)
						log_warn "$_key: the artifact content is valid but its provenance is '$_prov' — nothing binds it to this run, so in '$MODE' it does not count as evidence. Produce it through the evidence handoff, or run an assurance mode that permits unattributed content." ;;
				esac
			fi ;;
	esac
	if [ "$_flag" = "true" ]; then
		if [ "$_trig" = "true" ]; then add_eval "$_key" true "$_trig" fail; else add_eval "$_key" true "$_trig" pass; fi
	else
		add_eval "$_key" false "$_trig" skipped
	fi
}

# Expired-exceptions gate: summary.expired_exceptions > 0 OR exceptions.expired > 0.
eval_expired_gate() {
	_flag=$(gate_flag "expired_exceptions")
	_ee=$(jqr '.summary.expired_exceptions')
	_ex=$(jqr '.exceptions.expired')
	_trig=0
	if [ "$_ee" -gt 0 ]; then _trig=1; fi
	# The detailed exceptions object is EVIDENCE for the summary counter, so a malformed value
	# is untrusted evidence (it used to be skipped silently), and the two must AGREE. A summary
	# claiming zero expired exceptions beside a detail object reporting some — or the reverse —
	# is contradictory governance state, and the report recorded only the summary value.
	case "$_ex" in
		null) : ;;   # no detailed object at all: the summary counter stands alone
		'' | *[!0-9]*)
			die_cfg "exceptions.expired must be a non-negative integer, got '$_ex'. Malformed exception evidence is never ignored." ;;
		*)
			if [ "$_ex" -gt 0 ]; then _trig=1; fi
			if [ "$_ex" -ne "$_ee" ]; then
				die_cfg "expired-exception evidence contradicts itself: summary.expired_exceptions=$_ee but exceptions.expired=$_ex. Rebuild the summary; the enforcer will not pick one of two disagreeing counts."
			fi ;;
	esac
	if [ "$_flag" = "true" ]; then
		if [ "$_trig" -eq 1 ]; then add_eval "expired_exceptions" true "$_ee" fail; else add_eval "expired_exceptions" true "$_ee" pass; fi
	else
		add_eval "expired_exceptions" false "$_ee" skipped
	fi
}

eval_count_gate "secrets"
eval_count_gate "critical_vulnerabilities"
eval_count_gate "high_vulnerabilities"
eval_medium_vulnerabilities
eval_count_gate "architecture_violations"
eval_count_gate "type_errors"
eval_count_gate "test_failures"
eval_unsafe_docker
eval_count_gate "unsafe_github_actions"
eval_missing_gate "missing_sbom" "evidence.sbom.present"
eval_missing_gate "missing_release_evidence" "evidence.release_evidence.present"
eval_expired_gate

# Third-party supply-chain gates (separate channel; non-blocking by default in
# report-only/baseline). Evaluated like count gates; absent keys read as 0.
for _tpk in $THIRD_PARTY_KEYS; do
	eval_count_gate "$_tpk"
done

# Enterprise scanner count gates (v0.1.12). Evaluated like count gates; optional.
for _eck in $ENTERPRISE_COUNT_KEYS; do
	eval_count_gate "$_eck"
done

# Engineering-quality count gates (v2.1). Evaluated like count gates; optional. NOT
# suppressible (they are absent from SUPPRESSIBLE_GATES, so is_gate_suppressed is always
# false for them) — a quality regression is loud by design.
for _qck in $QUALITY_COUNT_KEYS; do
	eval_count_gate "$_qck"
done

# Boolean quality gates (v2.1) — missing_coverage_evidence / missing_test_evidence /
# empty_test_suite. The builder (run with --profile) sets these when an APPLICABLE coverage/test
# stack produced no valid report (or an empty suite), so strict/regulated fail on ABSENT evidence
# (not only on bad numbers). Absent key (older/non-profile summary) reads as false (back-compat).
for _qbk in $QUALITY_BOOL_KEYS; do
	eval_bool_gate "$_qbk"
done

# Architecture evidence gate (v2.1.0) — missing_architecture_evidence. The builder (run with
# --profile) sets it when an APPLICABLE architecture producer produced no valid evidence, so
# strict/regulated fail on ABSENT architecture evidence, not only on reported violations.
# Absent key (older/non-profile summary) reads as false (back-compat).
for _abk in $ARCHITECTURE_BOOL_KEYS; do
	eval_bool_gate "$_abk"
done

# Testing-discipline gates (v2.2.0). Counts first (TDD proxy violations, orphan behavior specs,
# acceptance-test failures), then the boolean evidence gates. acceptance_test_failures fails
# whenever evidence EXISTS and reports failures — a suite that never ran contributes 0 here and
# is caught by missing_acceptance_evidence instead, so "we skipped it" and "it failed" stay two
# distinct, separately-gated facts. NOT suppressible by accepted-risk.
for _tdck in $TESTING_DISCIPLINE_COUNT_KEYS; do
	eval_count_gate "$_tdck"
done
for _tdbk in $TESTING_DISCIPLINE_BOOL_KEYS; do
	eval_bool_gate "$_tdbk"
done

# --- required-tool POLICY enforcement (v1.10) --------------------------------
# When the summary carries per-tool policy data (build-security-summary.sh --profile),
# enforce required-tool availability/configuration MECHANICALLY, in a channel SEPARATE
# from the vulnerability counters (a missing tool is NEVER merged into a finding count):
#   required + unavailable / execution-error / not-configured / disabled  -> failure
#   one-of group unsatisfied                                              -> failure
#   recommended + unavailable/not-configured/execution-error             -> warning
#   optional + unavailable                                               -> info
#   not-applicable                                                       -> never fails
# A valid (unexpired) control-waiver for a required tool downgrades its failure to a
# prominently-reported waiver. installation.json disabled_tools surface as status
# "disabled" in the summary: a disabled REQUIRED tool without a valid waiver is a
# configuration failure (never silently skipped).
POLICY_FAIL=0
POLICY_INCONSISTENT=0
HAS_POLICY=$(jq -r '
	if ((.tools // {}) | to_entries | any(.value | (type=="object") and has("policy")))
	   or ((.summary // {}) | has("required_tool_failures"))
	then "1" else "0" end' "$SUMMARY" 2>/dev/null || printf '0')

REQF_REC=""; CFGF_REC=""; EXEF_REC=""; WAIVED_REC=""; WARN_REC=""; INFO_REC=""; ONEOF_REC=""

if [ "$HAS_POLICY" = "1" ]; then
	# Load valid (unexpired) control-waiver tool keys via the SHARED validator
	# (B1/B10/A4): full schema validation, real calendar-date check, self-approval
	# rejection. A malformed waivers file is a configuration failure (fail closed).
	# regulated assurance tightens the maximum waiver duration (#226) BEFORE anything is
	# validated, so an over-long window is a configuration failure in that mode rather
	# than a waiver that quietly outlives the assurance it was granted under.
	if [ "$MODE" = "regulated" ]; then CW_MAX_WAIVER_DAYS="$CW_MAX_WAIVER_DAYS_REGULATED"; fi
	cw_validate_file "$CONTROL_WAIVERS_FILE" "" "$TODAY" || die_cfg "control-waivers file invalid: $CONTROL_WAIVERS_FILE (see errors above)"
	# The APPLIED records, not just the tool keys: every output has to name the approval
	# that waived the control (#225), so the identity is carried from here, never
	# re-derived by a consumer.
	WAIVER_RECS=$(cw_applied_records "$CONTROL_WAIVERS_FILE" "$TODAY") \
		|| die_cfg "control-waivers file invalid: $CONTROL_WAIVERS_FILE (see errors above)"
	WAIVED_TOOLS=" "
	for _wt in $(printf '%s\n' "$WAIVER_RECS" | cut -f2); do
		WAIVED_TOOLS="${WAIVED_TOOLS}${_wt} "
	done
	is_waived() { case "$WAIVED_TOOLS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
	# waiver_fields <tool> — "id|owner|approved_by|created_at|expires_at|tracking_issue"
	# for the applied waiver, so a waived record carries its authorisation into the report.
	waiver_fields() { cw_record_for "$WAIVER_RECS" "$1" | cut -f1,3,4,5,6,7 | tr '\t' '|'; }

	# --- THE TRUSTED EXECUTION PLAN ------------------------------------------------------
	# Every exemption below used to be read from the SAME summary being judged: the summary
	# said a required tool was `not-applicable`, or carried `stage_selected: false`, and the
	# enforcer believed it. A hand-built or modified summary could therefore declare an
	# applicable required control out of scope. The plan written by run-tool-plan.sh is a
	# SEPARATE artifact produced by a different process, and it is what decides scope now.
	# Summary policy fields are informational echoes: disagreement with the plan is a failure.
	PLAN_OK=0
	if [ -n "${TOOL_PLAN:-}" ]; then
		[ -f "$TOOL_PLAN" ] || die_cfg "--tool-plan '$TOOL_PLAN' does not exist. An exemption cannot be reconciled against a plan that is not there."
		jq -e '(type == "object") and ((.stage // "") | type == "string") and ((.stage // "") != "")
			and ((.profile // "") | type == "string") and ((.profile // "") != "")
			and ((.tools // null) | type == "object")' "$TOOL_PLAN" >/dev/null 2>&1 \
			|| die_cfg "--tool-plan '$TOOL_PLAN' is not a usable execution plan (needs a non-empty stage, profile and a tools object)"
		PLAN_STAGE=$(jq -r '.stage' "$TOOL_PLAN")
		PLAN_PROFILE=$(jq -r '.profile' "$TOOL_PLAN")
		# The plan must describe THIS run. A plan for another stage or profile proves nothing
		# about the summary in front of us, and reconciling against it would be theatre.
		_sum_stage=$(jq -r '(.stage // "")' "$SUMMARY" 2>/dev/null || printf '')
		[ "$_sum_stage" = "null" ] && _sum_stage=""
		if [ -n "$_sum_stage" ] && [ "$_sum_stage" != "$PLAN_STAGE" ]; then
			die_cfg "the execution plan is for stage '$PLAN_STAGE' but the summary declares stage '$_sum_stage' — a plan for another stage cannot authorise this summary."
		fi
		_sum_profile=$(jq -r '(.project.type // "")' "$SUMMARY" 2>/dev/null || printf '')
		[ "$_sum_profile" = "null" ] && _sum_profile=""
		if [ -n "$_sum_profile" ] && [ "$_sum_profile" != "unknown" ] && [ "$_sum_profile" != "$PLAN_PROFILE" ]; then
			die_cfg "the execution plan is for profile '$PLAN_PROFILE' but the summary declares '$_sum_profile' — a plan for another profile cannot authorise this summary."
		fi
		PLAN_OK=1
		log_info "reconciling required-tool scope against the execution plan ($TOOL_PLAN: profile=$PLAN_PROFILE stage=$PLAN_STAGE)"
	fi
	# plan_says <emit> <field> — the plan value, or "" when the plan does not cover the tool.
	plan_says() {
		[ "$PLAN_OK" -eq 1 ] || { printf ''; return 0; }
		jq -r --arg k "$1" --arg f "$2" '((.tools[$k] // {})[$f] // "") | tostring' "$TOOL_PLAN" 2>/dev/null || printf ''
	}
	# plan_covers <emit> — true when the plan lists the tool for this stage at all.
	plan_covers() {
		[ "$PLAN_OK" -eq 1 ] || return 1
		jq -e --arg k "$1" '(.tools // {}) | has($k)' "$TOOL_PLAN" >/dev/null 2>&1
	}
	# An enforcing mode must not accept a summary-authored exemption with NO plan to check it
	# against. Without the plan the only safe reading of `gate_enforced:false` on a required
	# tool is a required-tool failure, which is what happens below.
	case "$MODE" in
		strict | regulated)
			if [ "$PLAN_OK" -ne 1 ]; then
				log_warn "no --tool-plan supplied: in '$MODE' a required-tool exemption claimed by the summary cannot be substantiated, so scope claims will NOT be honoured."
			fi ;;
	esac

	# A stage-scoped summary (build-security-summary.sh --stage) legitimately marks required
	# tools that do not run at that stage as not gate-enforced. Without that marker, an
	# unexplained gate_enforced:false is a configuration error rather than a scope statement.
	STAGE_SCOPED=$(jq -r '(.stage // "")' "$SUMMARY" 2>/dev/null || printf '')
	[ "$STAGE_SCOPED" = "null" ] && STAGE_SCOPED=""

	# Per-tool policy records: emit|tool|policy|status|gate_enforced
	_pl=$(jq -r '
		(.tools // {}) | to_entries[]
		| select(.value | (type=="object") and has("policy"))
		| [ .key, (.value.tool // .key), .value.policy, (.value.status // ""), ((.value.gate_enforced // false) | tostring) ]
		| join("|")' "$SUMMARY" 2>/dev/null || true)

	while IFS='|' read -r _emit _tkey _pol _st _ge; do
		[ -n "$_emit" ] || continue
		# POLICY IS THE PLAN'"'"'S TO STATE. A summary declaring `recommended` for a tool the plan
		# requires would otherwise downgrade its own required control by editing one field.
		if [ "$PLAN_OK" -eq 1 ] && plan_covers "$_emit"; then
			_ppol=$(plan_says "$_emit" policy)
			if [ -n "$_ppol" ] && [ "$_ppol" != "$_pol" ]; then
				if [ "$_ppol" = "required" ]; then
					log_warn "$_emit: the summary declares policy '"'"'$_pol'"'"' but the execution plan requires it — enforcing the plan."
					_pol="required"
				else
					log_warn "$_emit: the summary declares policy '"'"'$_pol'"'"' but the execution plan says '"'"'$_ppol'"'"'; the plan is authoritative."
					_pol="$_ppol"
				fi
			fi
		fi
		case "$_pol" in
			required)
				# `gate_enforced:false` on a REQUIRED tool used to skip the tool entirely, so the
				# summary PRODUCER could switch off required-tool enforcement by emitting one
				# field. It is only legitimate when the tool is genuinely out of scope for this
				# run — not applicable, or not selected for this stage — and the summary has to
				# say WHICH: an unexplained opt-out is a configuration error, not a pass.
				if [ "$_ge" != "true" ]; then
					case "$_st" in
						# `not-applicable` is an APPLICABILITY CLAIM, and the summary is not
						# an authority on it: the same document being judged asserted the
						# control was out of scope. It is honoured only when the trusted
						# execution plan agrees.
						not-applicable)
							if [ "$PLAN_OK" -eq 1 ]; then
								_pst=$(plan_says "$_emit" status)
								if ! plan_covers "$_emit"; then
									log_warn "$_emit: the summary claims not-applicable but the execution plan for stage '$PLAN_STAGE' does not list the tool at all — treating the claim as unsubstantiated."
									REQF_REC="${REQF_REC}${_emit}|${_tkey}|not-applicable(not in plan)
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|not-applicable(not in plan)
"; continue
								fi
								if [ "$_pst" = "not-applicable" ]; then continue; fi
								log_warn "$_emit: the summary claims not-applicable but the execution plan records status '$_pst' — the plan decides applicability."
								REQF_REC="${REQF_REC}${_emit}|${_tkey}|not-applicable(plan says ${_pst:-unknown})
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|not-applicable(plan says ${_pst:-unknown})
"; continue
							fi
							case "$MODE" in
								strict | regulated)
									log_warn "$_emit: a not-applicable claim cannot be substantiated without --tool-plan; in '$MODE' it is a required-tool failure."
									REQF_REC="${REQF_REC}${_emit}|${_tkey}|not-applicable(unsubstantiated)
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|not-applicable(unsubstantiated)
"; continue ;;
							esac
							continue ;;
						# `disabled` is a required-control FAILURE state, not an exemption. It
						# used to skip the tool outright, so a summary producer could switch
						# off its own required control by emitting status=disabled with
						# gate_enforced:false. It now needs a validated control waiver, exactly
						# like an unavailable required tool.
						disabled)
							if is_waived "$_tkey"; then
								WAIVED_REC="${WAIVED_REC}${_emit}|${_tkey}|${_st}|$(waiver_fields "$_tkey")
"
							else
								REQF_REC="${REQF_REC}${_emit}|${_tkey}|disabled(no waiver)
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|disabled(no waiver)
"
							fi
							continue ;;
						*)
							# Stage scope must be proven PER TOOL. Accepting any non-empty
							# top-level `.stage` let a hand-built summary mark arbitrary
							# required tools non-enforced simply by declaring a stage; the
							# enforcer never checked whether THIS tool is excluded at THAT
							# stage. The builder now derives `stage_selected` from the
							# effective-profile execution matrix, and only an explicit
							# `stage_selected: false` — together with a declared stage — is a
							# scope statement.
							# `//` is NOT usable here: jq treats `false` as empty, so
							# `.stage_selected // "absent"` turns the very value being looked
							# for into the default. has() is the only correct probe.
							_ssel=$(jqr "(.tools[\"$_emit\"] | if (type == \"object\") and has(\"stage_selected\") then (.stage_selected | tostring) else \"absent\" end)")
							if [ -n "$STAGE_SCOPED" ] && [ "$_ssel" = "false" ]; then
								# The summary saying "not selected at this stage" is a CLAIM
								# about policy, made by the document under judgement. The
								# trusted plan lists exactly the tools selected for the stage
								# it was resolved for, so absence from the plan is the proof
								# and presence contradicts the claim.
								if [ "$PLAN_OK" -eq 1 ]; then
									if plan_covers "$_emit"; then
										log_warn "$_emit: the summary claims it is not selected at stage '$STAGE_SCOPED', but the execution plan for '$PLAN_STAGE' does select it — the plan decides stage scope."
										REQF_REC="${REQF_REC}${_emit}|${_tkey}|stage-scope-contradicted
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|stage-scope-contradicted
"; continue
									fi
									continue
								fi
								case "$MODE" in
									strict | regulated)
										log_warn "$_emit: a stage-scope exemption cannot be substantiated without --tool-plan; in '$MODE' it is a required-tool failure."
										REQF_REC="${REQF_REC}${_emit}|${_tkey}|stage-scope(unsubstantiated)
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|stage-scope(unsubstantiated)
"; continue ;;
								esac
								continue
							fi
							REQF_REC="${REQF_REC}${_emit}|${_tkey}|not-gate-enforced(${_st:-unknown})
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|not-gate-enforced(${_st:-unknown})
"; continue ;;
					esac
				fi
				case "$_st" in
					unavailable)
						if is_waived "$_tkey"; then WAIVED_REC="${WAIVED_REC}${_emit}|${_tkey}|${_st}|$(waiver_fields "$_tkey")
"; else REQF_REC="${REQF_REC}${_emit}|${_tkey}|${_st}
"; fi ;;
					execution-error)
						if is_waived "$_tkey"; then WAIVED_REC="${WAIVED_REC}${_emit}|${_tkey}|${_st}|$(waiver_fields "$_tkey")
"; else REQF_REC="${REQF_REC}${_emit}|${_tkey}|${_st}
"; EXEF_REC="${EXEF_REC}${_emit}|${_tkey}|${_st}
"; fi ;;
					not-configured | disabled)
						if is_waived "$_tkey"; then WAIVED_REC="${WAIVED_REC}${_emit}|${_tkey}|${_st}|$(waiver_fields "$_tkey")
"; else REQF_REC="${REQF_REC}${_emit}|${_tkey}|${_st}
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|${_st}
"; fi ;;
					pass | findings)
						: ;;   # real execution; findings are judged by the count gates, not here
					not-applicable)
						# Trusted, but only as a CLAIM the summary must substantiate: the
						# builder records applicability from the resolved profile, so an
						# entry claiming not-applicable without the tool-policy overlay
						# having run is unsubstantiated.
						if [ "$(jqr '.summary.required_tool_failures')" = "null" ]; then
							REQF_REC="${REQF_REC}${_emit}|${_tkey}|not-applicable-unsubstantiated
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|not-applicable-unsubstantiated
"
						fi ;;
					*)
						# Empty, unknown, `skipped`, `warn`, `fail`, malformed or a status from a
						# future schema version. Falling through used to mean NO required-tool
						# failure, so a producer could avoid enforcement with any string the
						# enforcer did not recognise. An unrecognised status is untrusted
						# evidence about a REQUIRED control.
						if is_waived "$_tkey"; then WAIVED_REC="${WAIVED_REC}${_emit}|${_tkey}|${_st:-unknown}|$(waiver_fields "$_tkey")
"; else REQF_REC="${REQF_REC}${_emit}|${_tkey}|${_st:-unknown}
"; CFGF_REC="${CFGF_REC}${_emit}|${_tkey}|${_st:-unknown}
"; fi ;;
				esac ;;
			recommended)
				case "$_st" in
					unavailable | not-configured | execution-error) WARN_REC="${WARN_REC}${_emit}|${_tkey}|${_st}
" ;;
				esac ;;
			optional)
				case "$_st" in
					unavailable) INFO_REC="${INFO_REC}${_emit}|${_tkey}|${_st}
" ;;
				esac ;;
			*) : ;;  # one-of members are visibility-only; the GROUP decides (below)
		esac
	done <<EOF
$_pl
EOF

	# Unsatisfied one-of groups fail the gate.
	_grp=$(jq -r '(.one_of_groups // {}) | to_entries[] | select((.value.status // "unknown") == "unsatisfied") | "\(.key)|\(.value.status)"' "$SUMMARY" 2>/dev/null || true)
	while IFS='|' read -r _gk _gs; do
		[ -n "$_gk" ] || continue
		ONEOF_REC="${ONEOF_REC}${_gk}|${_gs}
"
	done <<EOF
$_grp
EOF

	[ -n "$REQF_REC" ] && POLICY_FAIL=1
	[ -n "$ONEOF_REC" ] && POLICY_FAIL=1

	# (B9) Fail closed on the SUMMARY-level counter even when detailed .tools records
	# are absent/legacy/incomplete. Reconcile against the detailed count: if both
	# exist and disagree, that is a configuration inconsistency (fail closed, never
	# trust the lower value).
	SUMMARY_REQF=$(jqr '.summary.required_tool_failures')
	case "$SUMMARY_REQF" in ''|*[!0-9]*) SUMMARY_REQF="" ;; esac
	# grep -c prints 0 AND exits non-zero on no match, so `|| printf 0` would append a
	# SECOND 0 ("0\n0") and break the arithmetic below. Capture, default, and validate.
	DETAIL_REQF=$(printf '%s' "$REQF_REC" | grep -c '|' 2>/dev/null || true)
	DETAIL_REQF=${DETAIL_REQF:-0}
	case "$DETAIL_REQF" in ''|*[!0-9]*) DETAIL_REQF=0 ;; esac
	if [ -n "$SUMMARY_REQF" ]; then
		if [ "$SUMMARY_REQF" -gt 0 ]; then POLICY_FAIL=1; fi
		# Only reconcile when detailed records were actually derivable (the .tools
		# block carried gate_enforced policy entries). An empty REQF_REC with a
		# summary count >0 still fails (above), but is not flagged "inconsistent"
		# unless detailed required records exist AND undercount the summary.
		if [ "$DETAIL_REQF" -gt 0 ] && [ "$DETAIL_REQF" -ne "$SUMMARY_REQF" ]; then
			log_warn "policy: summary.required_tool_failures=$SUMMARY_REQF disagrees with detailed records=$DETAIL_REQF — failing closed on the inconsistency."
			POLICY_FAIL=1
			POLICY_INCONSISTENT=1
		fi
	fi
fi

# (B11) Surface policy failure as a first-class failed gate so JSON, Markdown, the
# log summary and the exit code ALL agree — never "Failed gates: None" while exiting 1.
if [ "$POLICY_FAIL" -eq 1 ]; then
	case " $FAILED " in *" required_tool_policy "*) : ;; *) FAILED="$FAILED required_tool_policy" ;; esac
fi

RESULT="pass"
EXIT=0
if [ -n "$FAILED" ] || [ "$POLICY_FAIL" -eq 1 ]; then
	RESULT="fail"
	EXIT=1
fi

# --- emit human summary to stderr (never hidden) -----------------------------
log_info "Mode: $MODE  Result: $(printf '%s' "$RESULT" | tr '[:lower:]' '[:upper:]')"
if [ -n "$FAILED" ]; then
	for g in $FAILED; do log_info "FAILED gate: $g"; done
fi
if [ -n "$ACCEPTED" ]; then
	for g in $ACCEPTED; do log_info "ACCEPTED-RISK gate (count preserved, not failing): $g"; done
fi
if [ "$HAS_POLICY" = "1" ]; then
	if [ -n "$REQF_REC" ]; then
		printf '%s' "$REQF_REC" | while IFS='|' read -r _e _t _s; do [ -n "$_e" ] && log_info "REQUIRED-TOOL FAILURE: $_t ($_e) status=$_s"; done
	fi
	if [ -n "$ONEOF_REC" ]; then
		printf '%s' "$ONEOF_REC" | while IFS='|' read -r _g _s; do [ -n "$_g" ] && log_info "ONE-OF GROUP UNSATISFIED: $_g status=$_s"; done
	fi
	if [ -n "$WAIVED_REC" ]; then
		printf '%s' "$WAIVED_REC" | while IFS='|' read -r _e _t _s _wid _wo _wa _wc _wx _wtr; do
			[ -n "$_e" ] && log_warn "CONTROL-WAIVER applied (required tool NOT failing): $_t ($_e) status=$_s waiver=$_wid owner=$_wo approved_by=$_wa created=$_wc expires=$_wx tracking=$_wtr"
		done
	fi
fi

# recs_to_json — convert newline records "a|b|c" into a JSON array. The field names
# are supplied as the trailing args (3 for tool records, 2 for one-of records).
recs_to_json() {
	# usage: printf '%s' "$REC" | recs_to_json <name1> <name2> [name3 ...]
	# Variadic: a waived record carries its authorising waiver id/owner/approver/dates/
	# tracking reference alongside the tool, and every field named here is emitted.
	jq -R -s --args '
		[ $ARGS.positional[] ] as $names
		| split("\n") | map(select(length > 0) | split("|"))
		| map( . as $f
		       | reduce range(0; $names | length) as $i ({}; .[$names[$i]] = ($f[$i] // null)) )' "$@"
}

# --- writers -----------------------------------------------------------------
json_eval() {
	_first=1
	printf '%s' "$EVAL_LINES" | while IFS='|' read -r k en val res; do
		[ -n "$k" ] || continue
		if [ "$_first" -eq 1 ]; then _first=0; else printf ',\n'; fi
		printf '    { "key": "%s", "enabled": %s, "value": %s, "result": "%s" }' "$k" "$en" "$val" "$res"
	done
}

# json_failed — emit the failed JSON fragment to stdout.
json_failed() {
	_first=1
	for g in $FAILED; do
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '"%s"' "$g"
	done
}

# json_list — emit the list JSON fragment to stdout.
json_list() {
	# json_list <space-separated items>
	_first=1
	for g in $1; do
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '"%s"' "$g"
	done
}

# json_broad_ids — emit the broad ids JSON fragment to stdout.
json_broad_ids() {
	# objects from AR_BROAD_DETAIL ("gate|id" lines)
	_first=1
	printf '%s' "$AR_BROAD_DETAIL" | while IFS='|' read -r _g _id; do
		[ -n "$_g" ] || continue
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '{ "gate": "%s", "id": "%s" }' "$(json_escape "$_g")" "$(json_escape "$_id")"
	done
}

# json_finding_ids — emit the finding ids JSON fragment to stdout.
json_finding_ids() {
	# objects from AR_FINDING_DETAIL ("gate|id|rule|files-csv" lines)
	_first=1
	printf '%s' "$AR_FINDING_DETAIL" | while IFS='|' read -r _g _id _rule _files; do
		[ -n "$_g" ] || continue
		if [ "$_first" -eq 1 ]; then _first=0; else printf ', '; fi
		printf '{ "gate": "%s", "id": "%s", "rule_id": "%s", "files": "%s" }' \
			"$(json_escape "$_g")" "$(json_escape "$_id")" "$(json_escape "$_rule")" "$(json_escape "$_files")"
	done
}

# --- report publication (atomic, validated, paired) ---------------------------------------
# The report set IS the release-decision evidence. Both writers used to redirect straight to
# their final path: the JSON destination was truncated before generation finished and validated
# only after it had already replaced the previous report, the Markdown was never validated at
# all, a symlinked destination redirected the write out of the reports directory, and a failure
# between the two left callers reading a JSON and a Markdown that described different runs.
#
# Everything is staged next to the destination, validated, and published together at the end.
REPORT_TMPDIR=""
# A failed or interrupted publisher removes only its own STAGING generation and its own lock.
# A published generation is immutable and is never touched by cleanup, so the last valid
# generation always survives.
_report_cleanup() { _gen_cleanup; }
trap '_report_cleanup' EXIT INT TERM HUP

# report_dest_ok <path> — refuse a destination that is not a plain file we may replace.
report_dest_ok() {
	_rd=$(dirname -- "$1")
	[ -d "$_rd" ] || die_cfg "report directory does not exist: $_rd"
	[ -L "$_rd" ] && die_cfg "report directory is a symlink: $_rd"
	if [ -e "$1" ] || [ -L "$1" ]; then
		[ -L "$1" ] && die_cfg "refusing to write the enforcement report through a symlink: $1"
		[ -d "$1" ] && die_cfg "enforcement report destination is a directory: $1"
		[ -f "$1" ] || die_cfg "enforcement report destination is not a regular file (FIFO/device?): $1"
	fi
	return 0
}

# report_stage — create the staging directory inside OUTPUT_DIR so the final renames are atomic.
report_stage() {
	[ -n "$REPORT_TMPDIR" ] && return 0
	ensure_dir "$OUTPUT_DIR"
	# Artifacts are rendered directly into the STAGING GENERATION, so the generation is the
	# thing that gets validated and published; the flat files beside it are a mirror written
	# from the published generation afterwards.
	gen_prepare
	REPORT_TMPDIR="$GEN_STAGE"
	return 0
}

# report_publish <staged> <final> — replace atomically after the destination is proven safe.
# This publishes the COMPATIBILITY MIRROR only; the authoritative artifact set is the
# generation published by report_publish_generation() below.
report_publish() {
	report_dest_ok "$2"
	chmod 0644 "$1" 2>/dev/null || true
	# `$2.tmp.$$` is PREDICTABLE: anyone able to write in that directory can pre-create it as
	# a symlink, and `cp` follows the link — writing the report outside the report root before
	# the rename ever happens. mktemp creates the file itself, exclusively, and the result is
	# re-checked as a regular non-symlink file before anything is written into it.
	_rp_tmp=$(mktemp "$2.tmp.XXXXXX") || die_cfg "could not stage the mirrored report at $2"
	if [ -L "$_rp_tmp" ] || [ ! -f "$_rp_tmp" ]; then
		rm -f -- "$_rp_tmp"
		die_cfg "the staging path for $2 is not a regular file; refusing to publish through it"
	fi
	# The exact path is tracked so a signal between create and rename cannot leave it behind.
	REPORT_TMP="$_rp_tmp"
	cat -- "$1" > "$_rp_tmp" 2>/dev/null || { rm -f -- "$_rp_tmp"; REPORT_TMP=""; die_cfg "could not stage the mirrored report at $2"; }
	chmod 0644 "$_rp_tmp" 2>/dev/null || true
	mv -- "$_rp_tmp" "$2" || { rm -f -- "$_rp_tmp"; REPORT_TMP=""; die_cfg "could not publish the enforcement report at $2"; }
	REPORT_TMP=""
	log_info "wrote $2"
	return 0
}

# --- generation-based publication ---------------------------------------------------------
# Two sequential renames are NOT a transactional pair: a failure, a signal or a crash between
# them leaves a new JSON beside an old Markdown, which is exactly the mismatch this code
# claims to prevent. So the artifacts are published as ONE IMMUTABLE GENERATION and made
# visible by a single atomic pointer switch:
#
#   <output-dir>/enforcement/
#     <generation-id>/                 immutable once published; never mutated
#       sentinel-shield-enforcement.json
#       sentinel-shield-enforcement.md
#       manifest.json                  what the generation contains, with digests
#     current.json                     THE pointer: names the one complete generation
#
# A reader resolves current.json once and consumes that generation. Nothing else is evidence:
# file existence alone never means "complete", because a generation directory can exist while
# its manifest is still being written.
ENFORCEMENT_ROOT=""
GENERATION_ID=""
GEN_STAGE=""
# Exact staging paths for the mirror and the pointer (see _gen_cleanup).
REPORT_TMP=""
POINTER_TMP=""
GEN_KEEP="${SENTINEL_SHIELD_REPORT_GENERATIONS:-5}"
case "$GEN_KEEP" in '' | *[!0-9]*) GEN_KEEP=5 ;; esac
[ "$GEN_KEEP" -ge 1 ] || GEN_KEEP=1

_gen_cleanup() {
	if [ -n "$GEN_STAGE" ] && [ -d "$GEN_STAGE" ]; then rm -rf -- "$GEN_STAGE" 2>/dev/null || true; fi
	# The EXACT staging paths, tracked so a signal between create and rename cannot leave a
	# mktemp file behind. A glob would be wrong here: it could delete another publisher's
	# in-flight staging file.
	if [ -n "${REPORT_TMP:-}" ] && [ -f "$REPORT_TMP" ]; then rm -f -- "$REPORT_TMP" 2>/dev/null || true; fi
	if [ -n "${POINTER_TMP:-}" ] && [ -f "$POINTER_TMP" ]; then rm -f -- "$POINTER_TMP" 2>/dev/null || true; fi
	if [ -n "$ENFORCEMENT_ROOT" ] && [ -d "$ENFORCEMENT_ROOT/.publish.lock" ]; then
		# Only ever remove OUR lock: another publisher's lock is theirs to clear.
		if [ -f "$ENFORCEMENT_ROOT/.publish.lock/owner" ] &&
		   grep -q "pid=$$\b" "$ENFORCEMENT_ROOT/.publish.lock/owner" 2>/dev/null; then
			rm -rf -- "$ENFORCEMENT_ROOT/.publish.lock" 2>/dev/null || true
		fi
	fi
	return 0
}

# gen_lock — single publisher per report root. mkdir is atomic on POSIX, so it IS the lock;
# the owner file makes a stale lock diagnosable rather than mysterious.
gen_lock() {
	_gl="$ENFORCEMENT_ROOT/.publish.lock"
	if mkdir "$_gl" 2>/dev/null; then
		printf 'pid=%s host=%s user=%s started=%s run=%s\n' \
			"$$" "$(uname -n 2>/dev/null || printf unknown)" "$(id -un 2>/dev/null || printf unknown)" \
			"$TS" "${GITHUB_RUN_ID:-local}" > "$_gl/owner" 2>/dev/null || true
		return 0
	fi
	_owner=$(cat "$_gl/owner" 2>/dev/null || printf 'unknown holder')
	die_cfg "another enforcement run is publishing into '$ENFORCEMENT_ROOT' ($_owner). Two publishers must not interleave. If that run is gone, remove the stale lock directory: rm -rf '$_gl'"
}

# gen_prepare — create the private staging generation.
gen_prepare() {
	ENFORCEMENT_ROOT="$OUTPUT_DIR/enforcement"
	# The generation root must live INSIDE the verified report root and must not be reached
	# through a symlink.
	[ -L "$OUTPUT_DIR" ] && die_cfg "output directory is a symlink: $OUTPUT_DIR"
	if [ -e "$ENFORCEMENT_ROOT" ] && [ ! -d "$ENFORCEMENT_ROOT" ]; then
		die_cfg "'$ENFORCEMENT_ROOT' exists and is not a directory"
	fi
	[ -L "$ENFORCEMENT_ROOT" ] && die_cfg "enforcement generation root is a symlink: $ENFORCEMENT_ROOT"
	ensure_dir "$ENFORCEMENT_ROOT"
	gen_lock
	# Unpredictable, exclusive, private: mktemp creates it, 0700 keeps it unreadable while it
	# is incomplete, and the name cannot be guessed and pre-created.
	GEN_STAGE=$(mktemp -d "$ENFORCEMENT_ROOT/.staging.XXXXXX") \
		|| die_cfg "could not create a staging generation in $ENFORCEMENT_ROOT"
	chmod 0700 "$GEN_STAGE" 2>/dev/null || true
	GENERATION_ID="$(printf '%s' "$TS" | tr -c 'A-Za-z0-9' '-')-$(basename "$GEN_STAGE" | sed 's/^\.staging\.//')"
	return 0
}

# gen_manifest — describe the generation, with a digest for every artifact.
gen_manifest() {
	_gm="$GEN_STAGE/manifest.json"
	_files=""
	for _a in sentinel-shield-enforcement.json sentinel-shield-enforcement.md; do
		[ -f "$GEN_STAGE/$_a" ] || continue
		_sz=$(wc -c < "$GEN_STAGE/$_a" | tr -d ' ')
		_dg=$(ss_sha256_file "$GEN_STAGE/$_a" 2>/dev/null || printf '')
		[ -n "$_dg" ] || die_cfg "could not hash generation artifact '$_a'"
		_files="${_files}${_files:+,}$(printf '{"path":"%s","bytes":%s,"sha256":"%s"}' "$_a" "$_sz" "$_dg")"
	done
	[ -n "$_files" ] || die_cfg "the generation contains no artifacts"
	printf '{\n' > "$_gm"
	printf '  "schema_version": "1",\n' >> "$_gm"
	printf '  "generation_id": "%s",\n' "$(json_escape "$GENERATION_ID")" >> "$_gm"
	printf '  "created_at": "%s",\n' "$(json_escape "$TS")" >> "$_gm"
	printf '  "producer": "enforce-gates.sh",\n' >> "$_gm"
	printf '  "target_repository": %s,\n' "$(jqr '(.source.repository // "") | if . == "" then "null" else "\"" + . + "\"" end' 2>/dev/null || printf 'null')" >> "$_gm"
	printf '  "target_commit": "%s",\n' "$(json_escape "$(jqr '.source.commit // "unknown"')")" >> "$_gm"
	printf '  "profile": "%s",\n' "$(json_escape "$PROJ_TYPE")" >> "$_gm"
	printf '  "mode": "%s",\n' "$(json_escape "$MODE")" >> "$_gm"
	printf '  "result": "%s",\n' "$(json_escape "$RESULT")" >> "$_gm"
	printf '  "expected_artifacts": [%s],\n' "$(printf '%s' "$_files" | sed 's/{"path":"\([^"]*\)"[^}]*}/"\1"/g')" >> "$_gm"
	printf '  "artifacts": [%s],\n' "$_files" >> "$_gm"
	printf '  "summary_schema_version": "%s",\n' "$(json_escape "$(jqr '.version // "unknown"')")" >> "$_gm"
	printf '  "validation": "passed"\n' >> "$_gm"
	printf '}\n' >> "$_gm"
	jq -e . "$_gm" >/dev/null 2>&1 || die_cfg "the generation manifest is not valid JSON"
	return 0
}

# gen_validate — every artifact readable, non-empty, and matching its recorded digest.
gen_validate() {
	_n=$(jq -r '.artifacts | length' "$GEN_STAGE/manifest.json")
	[ "$_n" -ge 1 ] || die_cfg "the generation manifest lists no artifacts"
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_p=$(jq -r --argjson i "$_i" '.artifacts[$i].path' "$GEN_STAGE/manifest.json")
		_d=$(jq -r --argjson i "$_i" '.artifacts[$i].sha256' "$GEN_STAGE/manifest.json")
		_i=$((_i + 1))
		[ -f "$GEN_STAGE/$_p" ] || die_cfg "generation artifact missing before publication: $_p"
		[ -s "$GEN_STAGE/$_p" ] || die_cfg "generation artifact is empty: $_p"
		_a=$(ss_sha256_file "$GEN_STAGE/$_p" 2>/dev/null || printf '')
		[ "$_a" = "$_d" ] || die_cfg "generation artifact '$_p' does not match its manifest digest (expected $_d, got ${_a:-unreadable})"
		# A digest proves the bytes are the recorded ones; it does not prove they are USABLE.
		# Every artifact is validated for its own content type, so a corrupt report can never
		# become the current generation.
		case "$_p" in
			*.json)
				jq -e . "$GEN_STAGE/$_p" >/dev/null 2>&1 \
					|| die_cfg "generation artifact '$_p' is not valid JSON" ;;
			*.md)
				grep -q '[^[:space:]]' "$GEN_STAGE/$_p" \
					|| die_cfg "generation artifact '$_p' has no content" ;;
		esac
	done
	# Cross-artifact invariant: the JSON verdict and the Markdown must describe the SAME run.
	if [ -f "$GEN_STAGE/sentinel-shield-enforcement.json" ] && [ -f "$GEN_STAGE/sentinel-shield-enforcement.md" ]; then
		_jr=$(jq -r '(.result // "")' "$GEN_STAGE/sentinel-shield-enforcement.json" 2>/dev/null || printf '')
		[ -n "$_jr" ] || die_cfg "the generation JSON declares no result"
		grep -qi "$_jr" "$GEN_STAGE/sentinel-shield-enforcement.md" \
			|| die_cfg "the generation Markdown does not carry the JSON verdict '$_jr' — the pair would describe different runs"
	fi
	return 0
}

# gen_commit — finalize durably, then make the generation visible with ONE atomic rename.
gen_commit() {
	_final="$ENFORCEMENT_ROOT/$GENERATION_ID"
	[ -e "$_final" ] && die_cfg "generation '$GENERATION_ID' already exists — refusing to mutate a published generation"
	chmod 0755 "$GEN_STAGE" 2>/dev/null || true
	# Best-effort durability before the generation becomes reachable. POSIX sh has no fsync;
	# `sync` is the portable approximation and its absence is not fatal.
	command_exists sync && sync 2>/dev/null || true
	mv -- "$GEN_STAGE" "$_final" || die_cfg "could not finalize the generation at $_final"
	GEN_STAGE=""
	# THE pointer switch: written to a temp file in the same directory and renamed, so a
	# reader sees either the old pointer or the new one, never a half-written name.
	# The pointer destination must be a regular file or absent — not a symlink, and not a
	# directory or FIFO either. `mv` onto a directory does not replace it, and onto a FIFO it
	# does not do what "switch the pointer" promises.
	if [ -e "$ENFORCEMENT_ROOT/current.json" ] || [ -L "$ENFORCEMENT_ROOT/current.json" ]; then
		if [ -L "$ENFORCEMENT_ROOT/current.json" ]; then
			die_cfg "'$ENFORCEMENT_ROOT/current.json' is a symlink; refusing to publish through it"
		fi
		[ -f "$ENFORCEMENT_ROOT/current.json" ] \
			|| die_cfg "'$ENFORCEMENT_ROOT/current.json' exists and is not a regular file; refusing to replace it"
	fi
	# Same reasoning as report_publish: a PID-derived name is predictable and can be
	# pre-created as a symlink that the redirection below would write through.
	_ptmp=$(mktemp "$ENFORCEMENT_ROOT/.current.XXXXXX") || die_cfg "could not stage the current-generation pointer"
	if [ -L "$_ptmp" ] || [ ! -f "$_ptmp" ]; then
		rm -f -- "$_ptmp"
		die_cfg "the pointer staging path is not a regular file; refusing to publish through it"
	fi
	POINTER_TMP="$_ptmp"
	printf '{ "schema_version": "1", "generation_id": "%s", "updated_at": "%s", "path": "enforcement/%s", "manifest": "enforcement/%s/manifest.json" }\n' \
		"$(json_escape "$GENERATION_ID")" "$(json_escape "$TS")" \
		"$(json_escape "$GENERATION_ID")" "$(json_escape "$GENERATION_ID")" > "$_ptmp" \
		|| die_cfg "could not stage the current-generation pointer"
	jq -e . "$_ptmp" >/dev/null 2>&1 || { rm -f -- "$_ptmp"; die_cfg "the staged pointer is not valid JSON"; }
	command_exists sync && sync 2>/dev/null || true
	# Re-check immediately before the switch: the destination may have been replaced since the
	# check above.
	if [ -L "$ENFORCEMENT_ROOT/current.json" ]; then
		rm -f -- "$_ptmp"; POINTER_TMP=""
		die_cfg "'$ENFORCEMENT_ROOT/current.json' is a symlink; refusing to publish through it"
	fi
	if [ -e "$ENFORCEMENT_ROOT/current.json" ] && [ ! -f "$ENFORCEMENT_ROOT/current.json" ]; then
		rm -f -- "$_ptmp"; POINTER_TMP=""
		die_cfg "'$ENFORCEMENT_ROOT/current.json' is not a regular file; refusing to replace it"
	fi
	mv -- "$_ptmp" "$ENFORCEMENT_ROOT/current.json" \
		|| { rm -f -- "$_ptmp"; POINTER_TMP=""; die_cfg "could not switch the current-generation pointer"; }
	POINTER_TMP=""
	log_info "published enforcement generation $GENERATION_ID (pointer: $ENFORCEMENT_ROOT/current.json)"
	return 0
}

# gen_gc — keep GEN_KEEP generations. The ACTIVE one is never a candidate.
gen_gc() {
	_active=$(jq -r '.generation_id // ""' "$ENFORCEMENT_ROOT/current.json" 2>/dev/null || printf '')
	[ -n "$_active" ] || return 0
	_all=$(ls -1 "$ENFORCEMENT_ROOT" 2>/dev/null | grep -v '^current\.json$' | grep -v '^\.' | sort || true)
	_count=$(printf '%s\n' "$_all" | grep -c '[^[:space:]]' || true)
	[ "$_count" -gt "$GEN_KEEP" ] || return 0
	_drop=$((_count - GEN_KEEP))
	printf '%s\n' "$_all" | while IFS= read -r _g; do
		[ -n "$_g" ] || continue
		[ "$_drop" -gt 0 ] || break
		if [ "$_g" = "$_active" ]; then continue; fi
		[ -d "$ENFORCEMENT_ROOT/$_g" ] || continue
		rm -rf -- "$ENFORCEMENT_ROOT/$_g" 2>/dev/null && _drop=$((_drop - 1))
	done
	return 0
}

# write_json — write the json output report.
write_json() {
	report_stage
	_f="$REPORT_TMPDIR/sentinel-shield-enforcement.json"
	{
		printf '{\n'
		printf '  "version": "1.0",\n'
		printf '  "mode": "%s",\n' "$MODE"
		printf '  "result": "%s",\n' "$RESULT"
		printf '  "generated_at": "%s",\n' "$TS"
		printf '  "project": { "name": "%s", "type": "%s", "criticality": "%s" },\n' \
			"$(json_escape "$PROJ_NAME")" "$(json_escape "$PROJ_TYPE")" "$(json_escape "$PROJ_CRIT")"
		printf '  "failed_gates": [%s],\n' "$(json_failed)"
		printf '  "accepted_risks": {\n'
		printf '    "file": "%s",\n' "$(json_escape "$ACCEPTED_RISKS_FILE")"
		printf '    "loaded": %s,\n' "$AR_LOADED"
		printf '    "applied_gates": [%s],\n' "$(json_list "$ACCEPTED")"
		printf '    "applied_broad_gates": [%s],\n' "$(json_broad_ids)"
		printf '    "applied_finding_scoped": [%s],\n' "$(json_finding_ids)"
		printf '    "pending_ignored": %s,\n' "$AR_PENDING"
		printf '    "expired_ignored": %s,\n' "$AR_EXPIRED"
		printf '    "invalid_ignored": %s,\n' "$AR_INVALID"
		printf '    "legacy_unscoped_ignored": %s,\n' "$AR_LEGACY_WARN"
		printf '    "unsafe_docker": { "scope": "%s", "total": %s, "accepted": %s, "unaccepted": %s, "findings": %s },\n' \
			"$UD_SCOPE" "$UD_TOTAL" "$UD_ACCEPTED" "$UD_UNACCEPTED" "$UD_DETAIL"
		printf '    "medium_vulnerabilities": { "scope": "%s", "total": %s, "accepted": %s, "unaccepted": %s, "fingerprint_algorithm": "ss-fp/2", "findings": %s }\n' \
			"$MV_SCOPE" "$MV_TOTAL" "$MV_ACCEPTED" "$MV_UNACCEPTED" "$MV_DETAIL"
		printf '  },\n'
		printf '  "tool_policy": {\n'
		printf '    "enforced": %s,\n' "$([ "$HAS_POLICY" = "1" ] && printf true || printf false)"
		printf '    "control_waivers_file": "%s",\n' "$(json_escape "$CONTROL_WAIVERS_FILE")"
		printf '    "required_tool_failures": %s,\n' "$(printf '%s' "$REQF_REC" | recs_to_json emit tool status)"
		printf '    "tool_configuration_failures": %s,\n' "$(printf '%s' "$CFGF_REC" | recs_to_json emit tool status)"
		printf '    "tool_execution_failures": %s,\n' "$(printf '%s' "$EXEF_REC" | recs_to_json emit tool status)"
		printf '    "one_of_unsatisfied": %s,\n' "$(printf '%s' "$ONEOF_REC" | recs_to_json group status)"
		printf '    "waived": %s,\n' "$(printf '%s' "$WAIVED_REC" | recs_to_json emit tool status waiver_id owner approved_by created_at expires_at tracking_issue)"
		printf '    "recommended_warnings": %s,\n' "$(printf '%s' "$WARN_REC" | recs_to_json emit tool status)"
		printf '    "optional_info": %s\n' "$(printf '%s' "$INFO_REC" | recs_to_json emit tool status)"
		printf '  },\n'
		printf '  "evaluated_gates": [\n'
		json_eval
		printf '\n  ]\n'
		printf '}\n'
	} > "$_f"
	# Validate the STAGED file: an invalid report must never have replaced a valid one.
	jq -e . "$_f" >/dev/null 2>&1 || die_cfg "internal error: produced invalid enforcement JSON (staged at $_f)"
	jq -e '(.result != null) and (.mode != null) and ((.failed_gates | type) == "array")' "$_f" >/dev/null 2>&1 \
		|| die_cfg "internal error: staged enforcement JSON is missing its result/mode/failed_gates contract"
}

# write_markdown — write the markdown output report.
write_markdown() {
	report_stage
	_f="$REPORT_TMPDIR/sentinel-shield-enforcement.md"
	_result_up=$(printf '%s' "$RESULT" | tr '[:lower:]' '[:upper:]')
	{
		printf '# Sentinel Shield — Gate Enforcement\n\n'
		printf -- '- Project: %s (%s, criticality: %s)\n' "$PROJ_NAME" "$PROJ_TYPE" "$PROJ_CRIT"
		printf -- '- Mode: **%s**\n' "$MODE"
		printf -- '- Generated: %s\n' "$TS"
		printf -- '- Gates env: `%s`\n' "$GATES_ENV_FILE"
		printf -- '- Summary: `%s`\n\n' "$SUMMARY"
		printf -- '## Overall result: %s\n\n' "$_result_up"

		printf '## Active gates\n\n'
		printf -- '| Gate | Enabled | Value | Result |\n| --- | --- | --- | --- |\n'
		printf '%s' "$EVAL_LINES" | while IFS='|' read -r k en val res; do
			[ -n "$k" ] || continue
			printf -- '| %s | %s | %s | %s |\n' "$k" "$en" "$val" "$res"
		done
		printf '\n'

		printf '## Findings summary\n\n'
		printf -- '| Key | Count/Flag |\n| --- | --- |\n'
		for k in $INT_SUMMARY_KEYS; do
			printf -- '| %s | %s |\n' "$k" "$(jqr ".summary.$k")"
		done
		printf -- '| missing_sbom | %s |\n' "$(jqr '.summary.missing_sbom')"
		printf -- '| missing_release_evidence | %s |\n\n' "$(jqr '.summary.missing_release_evidence')"

		printf '## Third-party (supply-chain) findings\n\n'
		printf -- '> Separate channel from application SAST. Non-blocking by default in\n'
		printf -- '> report-only/baseline; see docs/third-party-supply-chain-scan.md.\n\n'
		printf -- '| Key | Count |\n| --- | --- |\n'
		for k in $THIRD_PARTY_KEYS; do
			_tv=$(jqr ".summary.$k"); case "$_tv" in ''|null) _tv=0 ;; esac
			printf -- '| %s | %s |\n' "$k" "$_tv"
		done
		printf -- '| tool status | %s |\n\n' "$(jqr '.tools.third_party_semgrep.status')"

		printf '## Engineering quality gates\n\n'
		printf -- '> Separate channel from security and architecture. Quality findings are\n'
		printf -- '> never folded into vulnerability counts. Mode defaults: strict blocks\n'
		printf -- '> coverage threshold/regression + complexity + duplication; regulated adds\n'
		printf -- '> mutation + dead-code. See docs/engineering-quality-gates.md.\n\n'
		printf -- '| Gate | Count |\n| --- | --- |\n'
		for k in $QUALITY_COUNT_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv=0 ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'
		printf -- '| Metric | Value |\n| --- | --- |\n'
		for k in $QUALITY_INFO_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv="(absent)" ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'

		printf '## Architecture governance\n\n'
		printf -- '> Normalized architecture evidence from any producer (Deptrac for PHP structural\n'
		printf -- '> boundaries, dependency-cruiser / ESLint boundaries for JS/TS, PHPArkitect and\n'
		printf -- '> custom architecture tests). Architecture tools detect dependency-boundary\n'
		printf -- '> violations — they do not prove domain-modelling quality or replace architectural\n'
		printf -- '> review. Mode defaults: architecture_violations blocks from baseline;\n'
		printf -- '> missing_architecture_evidence blocks in strict/regulated.\n'
		printf -- '> See docs/architecture-governance.md.\n\n'
		printf -- '| Gate | Value |\n| --- | --- |\n'
		_av=$(jqr '.summary.architecture_violations'); case "$_av" in ''|null) _av=0 ;; esac
		printf -- '| architecture_violations | %s |\n' "$_av"
		for k in $ARCHITECTURE_BOOL_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv="(absent)" ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'
		printf -- '| Metric | Value |\n| --- | --- |\n'
		for k in $ARCHITECTURE_INFO_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv="(absent)" ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'

		printf '## Testing discipline (TDD proxies, BDD, ATDD)\n\n'
		printf -- '> Sentinel Shield enforces test-first discipline through EVIDENCE:\n'
		printf -- '> production-change-without-test-change detection, changed-line coverage,\n'
		printf -- '> missing/empty test evidence, mutation testing, focused-test guards, BDD\n'
		printf -- '> specification evidence, and ATDD acceptance-test evidence.\n'
		printf -- '>\n'
		printf -- '> It does NOT prove true TDD (a final snapshot cannot show what was written\n'
		printf -- '> first), does not guarantee BDD quality, and never replaces product-owner\n'
		printf -- '> acceptance. Mode defaults: the TDD proxy blocks from strict;\n'
		printf -- '> acceptance_test_failures blocks from baseline when evidence exists;\n'
		printf -- '> BDD/ATDD evidence is demanded only from application profiles that opted in.\n'
		printf -- '> See docs/testing-discipline-governance.md.\n\n'
		printf -- '| Gate | Value |\n| --- | --- |\n'
		for k in $TESTING_DISCIPLINE_COUNT_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv=0 ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		for k in $TESTING_DISCIPLINE_BOOL_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv="(absent)" ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'
		printf -- '| Metric | Value |\n| --- | --- |\n'
		for k in $TESTING_DISCIPLINE_INFO_KEYS; do
			_qv=$(jqr ".summary.$k"); case "$_qv" in ''|null) _qv="(absent)" ;; esac
			printf -- '| %s | %s |\n' "$k" "$_qv"
		done
		printf '\n'

		if [ "$HAS_POLICY" = "1" ]; then
			printf '## Required-tool policy (controls)\n\n'
			printf -- '> Tool availability is a SEPARATE channel from finding counts — a missing\n'
			printf -- '> required tool is never folded into a vulnerability count. An unavailable /\n'
			printf -- '> not-configured / execution-error / disabled required tool fails the gate\n'
			printf -- '> (unless covered by an unexpired control-waiver). Control waivers file: `%s`.\n\n' "$CONTROL_WAIVERS_FILE"
			printf -- '| Category | Tool | Status |\n| --- | --- | --- |\n'
			_mdrows() { printf '%s' "$1" | while IFS='|' read -r _e _t _s; do [ -n "$_e" ] || continue; printf -- '| %s | %s | %s |\n' "$2" "$_t" "$_s"; done; }
			_mdrows "$REQF_REC" "required-tool-failure"
			_mdrows "$CFGF_REC" "configuration-failure"
			_mdrows "$EXEF_REC" "execution-failure"
			printf '%s' "$ONEOF_REC" | while IFS='|' read -r _g _s; do [ -n "$_g" ] || continue; printf -- '| one-of-group-unsatisfied | %s | %s |\n' "$_g" "$_s"; done
			# waived rows carry the authorising approval, not just the tool and status.
			printf '%s' "$WAIVED_REC" | while IFS='|' read -r _e _t _s _wid _wo _wa _wc _wx _wtr; do
				[ -n "$_e" ] || continue
				printf -- '| waived (NOT failing) | %s | %s (waiver %s, owner %s, approved_by %s, %s..%s, tracking %s) |\n' \
					"$_t" "$_s" "$_wid" "$_wo" "$_wa" "$_wc" "$_wx" "$_wtr"
			done
			_mdrows "$WARN_REC" "recommended-warning"
			_mdrows "$INFO_REC" "optional-info"
			if [ -z "$REQF_REC$CFGF_REC$EXEF_REC$ONEOF_REC$WAIVED_REC$WARN_REC$INFO_REC" ]; then
				printf -- '| _(all required controls satisfied)_ | | |\n'
			fi
			printf '\n'
		fi

		printf '## Failed gates\n\n'
		if [ -n "$FAILED" ]; then
			for g in $FAILED; do printf -- '- %s\n' "$g"; done
			printf '\n'
		else
			printf 'None.\n\n'
		fi

		printf '## Evidence checks\n\n'
		printf -- '| Evidence | Present |\n| --- | --- |\n'
		printf -- '| sbom | %s |\n' "$(jqr '.evidence.sbom.present')"
		printf -- '| release_evidence | %s |\n\n' "$(jqr '.evidence.release_evidence.present')"

		printf '## Exceptions\n\n'
		printf -- '| Field | Value |\n| --- | --- |\n'
		printf -- '| active | %s |\n' "$(jqr '.exceptions.active')"
		printf -- '| expired | %s |\n\n' "$(jqr '.exceptions.expired')"

		printf '## Accepted risks\n\n'
		printf -- '- File: `%s`\n' "$ACCEPTED_RISKS_FILE"
		printf -- '- Loaded: %s | pending ignored: %s | expired ignored: %s | invalid ignored: %s | legacy-unscoped ignored: %s\n' \
			"$AR_LOADED" "$AR_PENDING" "$AR_EXPIRED" "$AR_INVALID" "$AR_LEGACY_WARN"
		printf -- '- Broad (`scope: gate`) applied — **suppresses the WHOLE gate (discouraged)**:\n'
		if [ -n "$AR_BROAD_DETAIL" ]; then
			printf '%s' "$AR_BROAD_DETAIL" | while IFS='|' read -r _g _id; do
				[ -n "$_g" ] || continue
				printf -- '  - `%s` ← risk id `%s`\n' "$_g" "$_id"
			done
		else
			printf -- '  - none.\n'
		fi
		printf -- '- Finding-scoped (`scope: finding`) records (match rule_id + files):\n'
		if [ -n "$AR_FINDING_DETAIL" ]; then
			printf '%s' "$AR_FINDING_DETAIL" | while IFS='|' read -r _g _id _rule _files; do
				[ -n "$_g" ] || continue
				printf -- '  - `%s` ← risk id `%s` (rule_id: `%s`, files: `%s`)\n' "$_g" "$_id" "${_rule:-any}" "${_files:-any}"
			done
		else
			printf -- '  - none.\n'
		fi
		printf '\n'

		printf '### Unsafe Docker findings (finding-scoped accounting)\n\n'
		printf -- '- Scope: **%s** | total: %s | accepted: %s | unaccepted: %s\n\n' \
			"$UD_SCOPE" "$UD_TOTAL" "$UD_ACCEPTED" "$UD_UNACCEPTED"
		printf -- '| Source | Rule | File | Accepted | Risk id |\n| --- | --- | --- | --- | --- |\n'
		printf '%s' "$UD_DETAIL" | jq -r '.[]? | "| \(.source // "?") | \(.rule_id // "?") | \(.file) | \(if .accepted then "yes" else "**NO**" end) | \(.risk_id // "") |"' 2>/dev/null || printf -- '| _(no raw findings)_ | | | | |\n'
		printf -- '\n> Unaccepted findings are **not hidden** — they fail the gate. Convert each into\n'
		printf -- '> a fix or a finding-scoped accepted-risk (rule_id + files).\n\n'

		printf '### Medium vulnerabilities (finding-scoped accounting)\n\n'
		printf -- '- Scope: **%s** | total: %s | accepted: %s | unaccepted: %s | fingerprint algorithm: `ss-fp/2`\n\n' \
			"$MV_SCOPE" "$MV_TOTAL" "$MV_ACCEPTED" "$MV_UNACCEPTED"
		if [ "$MV_SCOPE" = "gate" ]; then
			printf -- '> **BROAD suppression in effect.** A `scope: gate` record accepts every medium\n'
			printf -- '> vulnerability, including ones that appear LATER. Replace it with finding-scoped\n'
			printf -- '> records (`components` / `fingerprints`).\n\n'
		fi
		printf -- '| Source | Advisory | Component | Version | Accepted | Risk id |\n| --- | --- | --- | --- | --- | --- |\n'
		printf '%s' "$MV_DETAIL" | jq -r '.[]? | "| \(.source // "?") | \(.rule_id // "?") | \(.component // "?") | \(.version // "") | \(if .accepted then "yes" else "**NO**" end) | \(.risk_id // "") |"' 2>/dev/null || printf -- '| _(no raw findings)_ | | | | | |\n'
		printf -- '\n> Accepting one medium vulnerability does not accept the others: a record matches only\n'
		printf -- '> when EVERY dimension it declares (fingerprints / components / rule ids / files)\n'
		printf -- '> matches the finding. Findings the raw reports could not identify are UNACCEPTED.\n\n'
		printf -- '> Only APPROVED, unexpired, owner-bound records suppress, and only for\n'
		printf -- '> suppressible gates (unsafe_docker, medium_vulnerabilities). Records are\n'
		printf -- '> **finding-scoped by default** (v0.1.8); broad gate suppression requires\n'
		printf -- '> explicit `scope: gate` and is discouraged. secrets, expired_exceptions, and\n'
		printf -- '> missing_release_evidence are never suppressed.\n\n'

		printf '## Next steps\n\n'
		if [ -n "$FAILED" ]; then
			printf -- '1. Resolve the failed gates above, or record an approved exception\n'
			printf -- '   (policies/exceptions/accepted-risk-template.md).\n'
			printf -- '2. Re-run the producing scanner workflow to refresh `%s`.\n' "$SUMMARY"
			printf -- '3. Re-run enforcement.\n'
		else
			printf -- '1. All active gates pass for mode `%s`.\n' "$MODE"
			printf -- '2. Tighten the mode in .sentinel-shield/profile.yaml as the project matures.\n'
		fi
	} > "$_f"
	# The Markdown was previously published unvalidated; at minimum it must be non-empty and
	# carry the verdict, so a truncated render cannot masquerade as the decision record.
	[ -s "$_f" ] || die_cfg "internal error: staged enforcement Markdown is empty ($_f)"
	grep -q "^## Overall result: " "$_f" || die_cfg "internal error: staged enforcement Markdown carries no verdict ($_f)"
}

# Generate everything FIRST, then publish as one set: a failure while rendering the second
# format can no longer leave a JSON and a Markdown describing different runs.
case "$FORMAT" in
	json) write_json ;;
	markdown) write_markdown ;;
	all) write_json; write_markdown ;;
esac
# Prove EVERY mirror destination is safe BEFORE anything is published, so a refusal cannot
# leave the pair describing different runs.
case "$FORMAT" in
	json | all) report_dest_ok "$OUTPUT_DIR/sentinel-shield-enforcement.json" ;;
esac
case "$FORMAT" in
	markdown | all) report_dest_ok "$OUTPUT_DIR/sentinel-shield-enforcement.md" ;;
esac

# ONE atomic commit: describe the generation, validate every artifact against its digest,
# finalize it durably, then switch the pointer. Any failure before the pointer switch leaves
# the previous current generation exactly as it was.
gen_manifest
gen_validate
gen_commit

# Compatibility mirror. The pointer is authoritative; these flat paths exist so consumers that
# predate generations keep working, and they are copied FROM the published generation, so they
# can never describe a run that was not published.
_gen_dir="$ENFORCEMENT_ROOT/$GENERATION_ID"
case "$FORMAT" in
	json | all) report_publish "$_gen_dir/sentinel-shield-enforcement.json" "$OUTPUT_DIR/sentinel-shield-enforcement.json" ;;
esac
case "$FORMAT" in
	markdown | all) report_publish "$_gen_dir/sentinel-shield-enforcement.md" "$OUTPUT_DIR/sentinel-shield-enforcement.md" ;;
esac
gen_gc
_report_cleanup

log_info "Enforcement complete (mode=$MODE, result=$RESULT, exit=$EXIT)."
exit "$EXIT"
