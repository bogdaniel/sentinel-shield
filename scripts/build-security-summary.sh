#!/bin/sh
# Sentinel Shield — security-summary builder.
#
# Runs the per-tool collectors over raw scanner artifacts in reports/raw/ and merges
# their results into reports/security-summary.json (conforming to
# schemas/security-summary.schema.json), which scripts/enforce-gates.sh then judges.
#
# Responsibilities (kept separate): this script does NOT run scanners. Scanner
# workflows produce reports/raw/*.json; collectors parse one file each; this builder
# merges. See docs/scanner-normalization.md.
#
# Design goals: deterministic, explicit, safe. jq is required.
#
# Exit codes:
#   0  summary generated
#   1  required tool artifact missing, or a collector failed
#   2  configuration / input / tooling error
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

die_cfg() { log_error "$*"; exit 2; }

# --- tool-policy overlay helpers (only used with --profile) -------------------
# emit_name_for <tool-key> — map an effective-profile tool key to the summary.tools
# emit-name. Uses TOOL_TABLE (col1 -> col4) when known (e.g. composer-audit ->
# composer_audit); otherwise falls back to the key with hyphens -> underscores.
emit_name_for() {
	_e=$(printf '%s\n' "$TOOL_TABLE" | awk -F'|' -v k="$1" '$1==k{print $4; exit}')
	if [ -n "$_e" ]; then printf '%s' "$_e"; else printf '%s' "$1" | tr '-' '_'; fi
}

# tool_exe_present <space-separated-executables> <target-dir> — best-effort install
# probe. Target scoping (B5): when <target-dir> is set, a RELATIVE path-bearing
# executable is resolved ONLY under the target — the Sentinel Shield repo (cwd) must
# never satisfy a consumer's missing dependency. When <target-dir> is empty the
# cwd-relative path may be used. Absolute paths are checked as-is in both cases.
# Bare global names (no slash) prefer a project-local copy under the target first,
# then fall back to global PATH (bare names denote globally-installed tools); we
# never probe a cwd-relative "./name", so a repo-local file cannot masquerade as the
# target's. Empty list -> not present.
tool_exe_present() {
	_exes=$1; _tgt=$2
	[ -n "$_exes" ] || return 1
	for _x in $_exes; do
		case "$_x" in
			/*)
				# absolute path: check as given.
				[ -x "$_x" ] && return 0 ;;
			*/*)
				# relative path-bearing: under <target> only when set, else cwd.
				if [ -n "$_tgt" ]; then
					[ -x "$_tgt/$_x" ] && return 0
				else
					[ -x "$_x" ] && return 0
				fi ;;
			*)
				# bare global name: project-local-first (target only), then PATH.
				if [ -n "$_tgt" ] && [ -x "$_tgt/$_x" ]; then return 0; fi
				command_exists "$_x" && return 0 ;;
		esac
	done
	return 1
}

# config_present <config-path> <target-dir> — true when the config file exists.
# Target scoping (B5): when <target-dir> is set, a RELATIVE config path is resolved
# ONLY under the target — the Sentinel Shield repo (cwd) must never satisfy a missing
# consumer config. When <target-dir> is empty the cwd-relative path may be used.
# Absolute paths are checked as-is in both cases.
config_present() {
	case "$1" in
		/*) [ -f "$1" ] && return 0; return 1 ;;
	esac
	if [ -n "$2" ]; then
		[ -f "$2/$1" ] && return 0
		return 1
	fi
	[ -f "$1" ] && return 0
	return 1
}

# policy_message <status> — short human explanation for a derived per-tool status.
policy_message() {
	case "$1" in
		pass) printf 'ran; no findings' ;;
		findings) printf 'ran; findings present (counted by finding gates)' ;;
		unavailable) printf 'required report absent and tool not installed (honest-absent)' ;;
		execution-error) printf 'tool present but produced no valid report' ;;
		not-configured) printf 'required config file absent' ;;
		not-applicable) printf 'stack not applicable to target' ;;
		disabled) printf 'listed in installation.json disabled_tools' ;;
		*) printf '%s' "$1" ;;
	esac
}

# tool-key | raw-filename | collector-script | emitted-tool-name
#
# NOTE: this is a DATA string. Do not put '#' comment lines inside it — each line is split
# on '|' into four positional fields, so a comment becomes a malformed row.
#
# `php-cs-fixer` and `php-style` both emit php_style on purpose: symfony declares its style
# tool as php-cs-fixer (whose runner writes an honest unavailable report, which php-style.sh
# does not), every other PHP profile uses php-style. Without the php-cs-fixer row the builder
# never read php-cs-fixer.json, so SYMFONY STYLE OUTPUT NEVER REACHED THE SUMMARY — a project
# with style violations reported style_violations=0 and passed strict. A profile declares one
# or the other, never both, so the cross-collector SUM cannot double-count.
TOOL_TABLE='gitleaks|gitleaks.json|gitleaks.sh|gitleaks
semgrep|semgrep.json|semgrep.sh|semgrep
trivy|trivy.json|trivy.sh|trivy
trivy-fs|trivy-fs.json|trivy.sh|trivy_fs
composer-audit|composer-audit.json|composer-audit.sh|composer_audit
npm-audit|npm-audit.json|npm-audit.sh|npm_audit
typescript|typescript.json|typescript.sh|typescript
eslint|eslint.json|eslint.sh|eslint
phpstan|phpstan.json|phpstan.sh|phpstan
psalm|psalm.json|psalm.sh|psalm
deptrac|deptrac.json|deptrac.sh|deptrac
tests|tests.json|tests.sh|tests
js-tests|js-tests.json|tests.sh|js_tests
hadolint|hadolint.json|hadolint.sh|hadolint
actionlint|actionlint.json|actionlint.sh|actionlint
zizmor|zizmor.json|zizmor.sh|zizmor
github-actions-pins|github-actions-pins.json|github-actions-pins.sh|github_actions_pins
docker-base-digest|docker-base-digest.json|docker-base-digest.sh|docker_base_digest
third-party-semgrep|third-party-semgrep.json|third-party-semgrep.sh|third_party_semgrep
codeql|codeql.json|codeql.sh|codeql
php-syntax|php-syntax.json|php-syntax.sh|php_syntax
php-style|php-style.json|php-style.sh|php_style
larastan|larastan.json|phpstan.sh|larastan
phpstan-symfony|phpstan-symfony.json|phpstan.sh|phpstan_symfony
phpstan-doctrine|phpstan-doctrine.json|phpstan.sh|phpstan_doctrine
pint|pint.json|php-style.sh|pint
php-cs-fixer|php-cs-fixer.json|php-style.sh|php_style
rector|rector.json|rector.sh|rector
syft|syft.json|syft.sh|syft
osv-scanner|osv-scanner.json|osv-scanner.sh|osv_scanner
grype|grype.json|grype.sh|grype
dependency-check|dependency-check.json|dependency-check.sh|dependency_check
scorecard|scorecard.json|scorecard.sh|scorecard
trufflehog|trufflehog.json|trufflehog.sh|trufflehog
checkov|checkov.json|checkov.sh|checkov
conftest|conftest.json|conftest.sh|conftest
terrascan|terrascan.json|terrascan.sh|terrascan
dockle|dockle.json|dockle.sh|dockle
zap|zap.json|zap.sh|zap
zap-full|zap-full.json|zap.sh|zap_full
nuclei|nuclei.json|nuclei.sh|nuclei
ai-security-review|ai-security-review.json|ai-security-review.sh|ai_security_review
kuzushi|kuzushi.json|kuzushi.sh|kuzushi
dependency-policy|dependency-policy.json|dependency-policy.sh|dependency_policy
architecture-tests|architecture-tests.json|architecture-tests.sh|architecture_tests
php-arkitect|php-arkitect.json|php-arkitect.sh|php_arkitect
php-architecture-tests|php-architecture-tests.json|php-architecture-tests.sh|php_architecture_tests
dependency-cruiser|dependency-cruiser.json|dependency-cruiser.sh|dependency_cruiser
eslint-boundaries|eslint-boundaries.json|eslint-boundaries.sh|eslint_boundaries
js-architecture-tests|js-architecture-tests.json|js-architecture-tests.sh|js_architecture_tests
coverage|coverage.json|coverage.sh|coverage
php-coverage|php-coverage.json|coverage.sh|php_coverage
js-coverage|js-coverage.json|coverage.sh|js_coverage
mutation|mutation.json|mutation.sh|mutation
php-mutation|php-mutation.json|mutation.sh|php_mutation
js-mutation|js-mutation.json|mutation.sh|js_mutation
complexity|complexity.json|complexity.sh|complexity
php-complexity|php-complexity.json|complexity.sh|php_complexity
js-complexity|js-complexity.json|complexity.sh|js_complexity
duplication|duplication.json|duplication.sh|duplication
php-duplication|php-duplication.json|duplication.sh|php_duplication
js-duplication|js-duplication.json|duplication.sh|js_duplication
dead-code|dead-code.json|dead-code.sh|dead_code
php-dead-code|php-dead-code.json|dead-code.sh|php_dead_code
js-dead-code|js-dead-code.json|dead-code.sh|js_dead_code
diff-coverage|diff-coverage.json|diff-coverage.sh|diff_coverage
php-diff-coverage|php-diff-coverage.json|diff-coverage.sh|php_diff_coverage
js-diff-coverage|js-diff-coverage.json|diff-coverage.sh|js_diff_coverage
focused-tests|focused-tests.json|focused-tests.sh|focused_tests
debug-code|debug-code.json|debug-code.sh|debug_code
source-size|source-size.json|source-size.sh|source_size
test-change-evidence|test-change-evidence.json|test-change-evidence.sh|test_change_evidence
behat-specs|behat-specs.json|behavior-specs.sh|behat_specs
cucumber-specs|cucumber-specs.json|behavior-specs.sh|cucumber_specs
behavior-specs|behavior-specs.json|behavior-specs.sh|behavior_specs
playwright-acceptance|playwright-acceptance.json|acceptance-tests.sh|playwright_acceptance
cypress-acceptance|cypress-acceptance.json|acceptance-tests.sh|cypress_acceptance
behat-acceptance|behat-acceptance.json|acceptance-tests.sh|behat_acceptance
cucumber-acceptance|cucumber-acceptance.json|acceptance-tests.sh|cucumber_acceptance
acceptance-tests|acceptance-tests.json|acceptance-tests.sh|acceptance_tests'

# --- defaults / CLI ----------------------------------------------------------
RAW_DIR="reports/raw"
OUTPUT="reports/security-summary.json"
PNAME="unknown"
PTYPE="unknown"
CRIT="medium"
COMMIT="unknown"
BRANCH="master"
WORKFLOW="local"
STRICT_TOOLS=0
REQUIRE_TOOLS=" "   # space-padded list for substring matching
PROFILE_NAME=""    # when set, overlay effective-profile tool policy onto summary.tools
TARGET_DIR=""      # consuming project root (applicability + one-of + installation.json)
OVERRIDE_PATH=""   # project tool-policy override passed through to the resolver

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: build-security-summary.sh [options]

Merge collector results over reports/raw/*.json into reports/security-summary.json.

Options:
  --raw-dir <path>        Directory of raw artifacts (default: reports/raw)
  --output <path>         Output summary path (default: reports/security-summary.json)
  --project-name <name>   Project name (default: unknown)
  --project-type <type>   Project type (default: unknown)
  --criticality <level>   low | medium | high | critical (default: medium)
  --commit <sha>          Source commit (default: unknown)
  --branch <branch>       Source branch (default: master)
  --workflow <name>       Producing workflow (default: local)
  --strict-tools          Fail (exit 1) if ANY expected raw artifact is missing
  --require-tool <tool>   Fail (exit 1) if this tool's artifact is missing (repeatable)
  --profile <name>        Overlay the effective-profile tool policy onto summary.tools.
                          For every required tool and one-of group member emits a
                          per-tool policy object (status pass|findings|unavailable|
                          not-configured|execution-error|not-applicable|disabled) plus
                          the counters required_tool_failures / tool_configuration_failures
                          / tool_execution_failures and a one_of_groups echo. An unavailable
                          required report is NEVER rewritten as a clean 0. Without --profile
                          behaviour is unchanged (back-compat).
  --target <dir>          Consuming project root (enables applicability, one-of selection,
                          and installation.json disabled_tools). Only with --profile.
  --override <path>       Project tool-policy override forwarded to the resolver.
  -h, --help              Show this help

Requires jq. Exit: 0 ok, 1 missing-required/collector-failure, 2 config/tooling error.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--raw-dir) RAW_DIR="${2:?--raw-dir requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--project-name) PNAME="${2:?--project-name requires a value}"; shift 2 ;;
		--project-type) PTYPE="${2:?--project-type requires a value}"; shift 2 ;;
		--criticality) CRIT="${2:?--criticality requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--branch) BRANCH="${2:?--branch requires a value}"; shift 2 ;;
		--workflow) WORKFLOW="${2:?--workflow requires a value}"; shift 2 ;;
		--strict-tools) STRICT_TOOLS=1; shift ;;
		--require-tool) REQUIRE_TOOLS="${REQUIRE_TOOLS}${2:?--require-tool requires a value} "; shift 2 ;;
		--profile) PROFILE_NAME="${2:?--profile requires a value}"; shift 2 ;;
		--target) TARGET_DIR="${2:?--target requires a value}"; shift 2 ;;
		--override) OVERRIDE_PATH="${2:?--override requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

case "$CRIT" in
	low | medium | high | critical) ;;
	*) die_cfg "invalid --criticality '$CRIT' (expected: low | medium | high | critical)" ;;
esac

command_exists jq || die_cfg "jq is required but was not found. Install jq."

REPORTS_DIR=$(dirname -- "$OUTPUT")
ensure_dir "$REPORTS_DIR"
TS=$(timestamp_utc)

# --- run collectors ----------------------------------------------------------
COLLECTED=""        # newline-delimited collector JSON objects
MISSING_REQUIRED="" # space list of required-but-missing tool keys

# Iterate the table in the CURRENT shell (not a pipeline subshell) so the COLLECTED
# and MISSING_REQUIRED accumulators persist. Split each row on '|' via IFS.
OLD_IFS=$IFS
IFS='
'
for row in $TOOL_TABLE; do
	IFS='|'
	# shellcheck disable=SC2086
	set -- $row
	IFS=$OLD_IFS
	key=$1; file=$2; script=$3; emit=$4
	raw="$RAW_DIR/$file"
	collector="$SCRIPT_DIR/collectors/$script"

	required=0
	if [ "$STRICT_TOOLS" -eq 1 ]; then required=1; fi
	case "$REQUIRE_TOOLS" in *" $key "*) required=1 ;; esac

	if [ ! -f "$raw" ] || [ ! -s "$raw" ]; then
		if [ "$required" -eq 1 ]; then
			log_error "required tool artifact missing or empty: $key ($raw)"
			MISSING_REQUIRED="$MISSING_REQUIRED $key"
			continue
		fi
		# Non-required: still invoke the collector, which emits "unavailable".
	fi

	if [ ! -f "$collector" ]; then
		die_cfg "collector not found: $collector"
	fi

	out=$(sh "$collector" --input "$raw" --tool-name "$emit") || {
		log_error "collector failed for '$key' ($collector)"
		exit 1
	}
	COLLECTED="${COLLECTED}${out}
"
done
IFS=$OLD_IFS

if [ -n "$MISSING_REQUIRED" ]; then
	log_error "missing required tool artifacts:$MISSING_REQUIRED"
	exit 1
fi

# --- merge -------------------------------------------------------------------
ARR=$(printf '%s' "$COLLECTED" | jq -s '.')

# Merge rules by key class:
#   - count keys (default): SUM across collectors (so PHP + JS coverage violations add).
#   - informational MIN keys (percentages): the weakest stack drives the gate, so take the
#     minimum across applicable stacks (docs/engineering-quality-gates.md coverage aggregation).
#   - informational MAX keys (worst-observed): take the maximum across stacks.
#   - coverage_regression is a boolean-ish flag: clamp the summed count to 0/1 (1 = ANY stack
#     regressed).
#   - architecture (v2.1.0): architecture_violations / architecture_rule_count /
#     architecture_tool_count SUM across producers (Deptrac + dependency-cruiser + ... all
#     contribute), while architecture_context_count takes the MAXIMUM — producers describe the
#     SAME codebase, so summing bounded contexts would double-count them.
#   - testing discipline (v2.2.0): the count keys SUM across producers (two BDD producers both
#     contribute scenarios), while the three missing_* keys are BOOLEAN — they OR, because ANY
#     producer that failed to produce expected evidence means evidence is missing. Adding a
#     boolean to a number would be a jq type error, so they are handled in their own branch.
COUNTS=$(printf '%s' "$ARR" | jq '
	def mins: ["coverage_line_percent","coverage_branch_percent","coverage_method_percent","coverage_class_percent","mutation_score_percent","changed_lines_coverage_percent"];
	def maxs: ["complexity_max","complexity_average","duplication_percent","max_file_lines","max_function_lines","architecture_context_count"];
	def bools: ["missing_test_change_evidence","missing_behavior_specification","missing_acceptance_evidence"];
	reduce .[] as $c (
		{secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
		 medium_vulnerabilities:0, architecture_violations:0, type_errors:0,
		 test_failures:0, unsafe_docker:0, unsafe_github_actions:0, expired_exceptions:0,
		 third_party_suspicious_code:0, third_party_install_script_risk:0,
		 third_party_obfuscation:0, third_party_network_behavior:0,
		 style_violations:0, php_syntax_errors:0, dependency_policy_violations:0,
		 iac_violations:0, dast_findings:0, container_image_violations:0,
		 repository_health_warnings:0, ai_review_findings:0,
		 coverage_threshold_violations:0, coverage_regression:0,
		 mutation_score_violations:0, complexity_violations:0,
		 duplication_violations:0, dead_code_violations:0,
		 changed_lines_coverage_violations:0, skipped_tests:0, test_count:0,
		 focused_test_violations:0, skipped_test_marker_violations:0,
		 debug_code_violations:0, large_file_violations:0, large_function_violations:0,
		 architecture_rule_count:0, architecture_tool_count:0, architecture_context_count:0,
		 production_change_without_test_change:0, behavior_spec_count:0,
		 orphan_behavior_specifications:0, acceptance_test_count:0, acceptance_test_failures:0,
		 missing_test_change_evidence:false, missing_behavior_specification:false,
		 missing_acceptance_evidence:false};
		reduce ($c.summary | keys_unsorted[]) as $k (.;
			($c.summary[$k]) as $v
			| if (bools | index($k)) then
				.[$k] = (((.[$k] // false) or ($v == true)))
			  elif (mins | index($k)) then
				.[$k] = (if .[$k] == null then $v else ([.[$k], $v] | min) end)
			  elif (maxs | index($k)) then
				.[$k] = (if .[$k] == null then $v else ([.[$k], $v] | max) end)
			  else
				.[$k] = ((.[$k] // 0) + ($v // 0))
			  end)
	)
	| .coverage_regression = ([.coverage_regression, 1] | min)')

TOOLSOBJ=$(printf '%s' "$ARR" | jq 'reduce .[] as $c ({}; .[$c.tool] = $c.tool_report)')

# --- effective-profile tool-policy overlay (optional --profile) --------------
# Wire required-tool POLICY into the summary: for every required tool (and one-of
# group member / recommended / optional) emit a per-tool policy object and derive
# the gating counters. The composition itself is NEVER reimplemented here — it is
# delegated to scripts/resolve-effective-profile.sh (canonical resolver).
HAVE_POLICY=0
POLICY_TOOLS='{}'
ONEOF_ECHO='{}'
REQ_FAIL=0
CFG_FAIL=0
EXE_FAIL=0
MISSING_COV=false   # v2.1: an applicable coverage tool produced no valid report (profile-aware)
MISSING_TEST=false  # v2.1: an applicable test stack produced no valid test report
EMPTY_SUITE=false   # v2.1: an applicable test report exists but ran zero tests
MISSING_ARCH=false  # v2.1.0: an applicable architecture producer produced no valid evidence
# v2.2.0 testing discipline. Like missing_architecture_evidence, these are FALSE unless the
# evidence was EXPECTED for this profile/policy — a project that never opted into BDD/ATDD is
# not "missing" it. Derived below, inside the --profile block, from the collector-derived tool
# status plus the collector's own missing_* verdict.
MISSING_TCE=false
MISSING_BDD=false
MISSING_ATDD=false
if [ -n "$PROFILE_NAME" ]; then
	HAVE_POLICY=1
	RESOLVER="$SCRIPT_DIR/resolve-effective-profile.sh"
	[ -f "$RESOLVER" ] || die_cfg "resolver not found: $RESOLVER"
	set -- --profile "$PROFILE_NAME"
	[ -n "$TARGET_DIR" ] && set -- "$@" --target "$TARGET_DIR"
	[ -n "$OVERRIDE_PATH" ] && set -- "$@" --override "$OVERRIDE_PATH"
	EFF=$(sh "$RESOLVER" "$@" --format json) || die_cfg "effective-profile resolution failed for '$PROFILE_NAME'"
	printf '%s' "$EFF" | jq -e . >/dev/null 2>&1 || die_cfg "resolver did not emit valid JSON for profile '$PROFILE_NAME'"

	# Tools explicitly disabled in this installation (only knowable with --target).
	DISABLED_TOOLS=" "
	if [ -n "$TARGET_DIR" ] && [ -f "$TARGET_DIR/.sentinel-shield/installation.json" ]; then
		_im="$TARGET_DIR/.sentinel-shield/installation.json"
		if jq -e . "$_im" >/dev/null 2>&1; then
			for _d in $(jq -r '(.disabled_tools // [])[]' "$_im" 2>/dev/null); do
				DISABLED_TOOLS="${DISABLED_TOOLS}${_d} "
			done
		fi
	fi

	# one-of group members (alternatives across all groups), space-padded.
	ONEOF_MEMBERS=" $(printf '%s' "$EFF" | jq -r '[ (.one_of_groups // {})[].alternatives[]? ] | join(" ")') "

	# Pipe-delimited rows (empty fields preserved):
	#   key|policy|applicability|report|exes|cfgpath|cfgclass|category
	# (category is appended LAST so the existing positional fields are untouched.)
	_rows=$(printf '%s' "$EFF" | jq -r '
		.tools | to_entries[]
		| [ .key, .value.policy, (.value.applicability // "unknown"),
			(.value.report // ""),
			((.value.executable // []) | join(" ")),
			(.value.config.path // ""), (.value.config.classification // ""),
			(.value.category // "") ]
		| join("|")')

	POLICY_COLLECTED=""
	# Emit-names of the architecture producers whose EVIDENCE is expected (v2.1.0): category
	# architecture, applicable, and not opt-in-only. Collected here, from the effective-profile
	# rows, so the evidence gate below can read the COLLECTOR-derived status per tool instead of
	# re-parsing raw reports. Space-padded for substring matching.
	ARCH_EVIDENCE_EMITS=" "
	# Emit-names of the testing-discipline producers declared by the profile (v2.2.0), split by
	# channel so TDD / BDD / ATDD stay independently gated. Only REQUIRED producers make evidence
	# expected: a recommended/optional BDD producer is an invitation, not a demand — a library
	# that never opted in must never fail for missing Gherkin. Space-padded for matching.
	TDD_EVIDENCE_EMITS=" "
	BDD_EVIDENCE_EMITS=" "
	ATDD_EVIDENCE_EMITS=" "
	# Read in the CURRENT shell (here-doc, NOT a pipe) so counters/accumulators persist.
	while IFS='|' read -r tkey tpol tappl trep texe tcfgp tcfgc tcat; do
		[ -n "$tkey" ] || continue

		# Which tools get a per-tool object: required/recommended/optional always;
		# one-of MEMBERS yes; the one-of GROUP entry (policy one-of, not a member,
		# e.g. 'tests') is represented in one_of_groups only; disabled/external skip.
		_is_member=0
		case "$ONEOF_MEMBERS" in *" $tkey "*) _is_member=1 ;; esac
		case "$tpol" in
			required | recommended | optional) : ;;
			one-of) [ "$_is_member" -eq 1 ] || continue ;;
			*) continue ;;
		esac

		emit=$(emit_name_for "$tkey")
		repfile=""
		[ -n "$trep" ] && repfile="$RAW_DIR/$(basename -- "$trep")"

		# Architecture producers whose evidence is EXPECTED (v2.1.0). Optional producers stay
		# opt-in (a project that never asked for PHPArkitect is not missing evidence), and a
		# not-applicable stack is ignored entirely.
		if [ "$tcat" = "architecture" ] && [ "$tappl" != "not-applicable" ] && [ "$tpol" != "optional" ]; then
			ARCH_EVIDENCE_EMITS="${ARCH_EVIDENCE_EMITS}${emit} "
		fi

		# Testing-discipline producers whose evidence is EXPECTED (v2.2.0). The threshold differs
		# per channel, deliberately:
		#
		#   testing-discipline (TDD proxy): required OR recommended — same rule as architecture
		#     evidence (v2.1.0), because the proxy needs NO project tooling, only a git history.
		#     It ships as `recommended` so it never trips the always-on required-tool channel;
		#     whether absent evidence BLOCKS is left to the MODE (strict/regulated), which is the
		#     adoption ramp this feature is designed around.
		#
		#   bdd / atdd: REQUIRED only. Gherkin and browser acceptance suites are real
		#     commitments, so only a profile author explicitly marking a producer `required`
		#     makes that evidence expected. A recommended/optional producer is an invitation.
		if [ "$tappl" != "not-applicable" ]; then
			case "$tcat" in
				testing-discipline)
					[ "$tpol" != "optional" ] && TDD_EVIDENCE_EMITS="${TDD_EVIDENCE_EMITS}${emit} " ;;
				bdd)
					[ "$tpol" = "required" ] && BDD_EVIDENCE_EMITS="${BDD_EVIDENCE_EMITS}${emit} " ;;
				atdd)
					[ "$tpol" = "required" ] && ATDD_EVIDENCE_EMITS="${ATDD_EVIDENCE_EMITS}${emit} " ;;
			esac
		fi

		# Reuse the collector's status when this tool has one (TOOL_TABLE), so the
		# findings/pass split matches the mapped summary counters. _hascol distinguishes
		# "a collector ran and returned a status" from "this tool has NO collector" (e.g.
		# larastan/pint/syft declare a report but no scripts/collectors/*.sh) — the latter
		# must NOT be treated as a collector emitting an empty status.
		_hascol=$(printf '%s' "$TOOLSOBJ" | jq -r --arg e "$emit" 'if has($e) then "1" else "0" end')
		cstatus=$(printf '%s' "$TOOLSOBJ" | jq -r --arg e "$emit" '(.[$e].status) // ""')

		report_ok=0
		if [ -n "$repfile" ] && [ -f "$repfile" ] && [ -s "$repfile" ] && jq -e . "$repfile" >/dev/null 2>&1; then
			report_ok=1
		fi
		_disabled=0
		case "$DISABLED_TOOLS" in *" $tkey "*) _disabled=1 ;; esac

		installed=false; configured=true; executed=false
		if [ "$tappl" = "not-applicable" ]; then
			status="not-applicable"
		elif [ "$_disabled" -eq 1 ]; then
			status="disabled"
		elif [ -z "$trep" ]; then
			# Precondition tool (no report declared, e.g. deps-install / category=setup):
			# it produces no scanner report, so its "execution" is satisfied purely by
			# its executable being present — installed => pass, absent => unavailable.
			# (Never execution-error: there is no report to be missing.)
			if tool_exe_present "$texe" "$TARGET_DIR"; then
				installed=true; executed=true; status="pass"
			else
				status="unavailable"
			fi
		elif [ "$report_ok" -eq 1 ]; then
			# A present, valid-JSON report may STILL honestly report a non-clean status
			# (unavailable / not-configured / execution-error / disabled / not-applicable) —
			# those must be PRESERVED, never collapsed into a clean pass, so the evidence gates
			# (missing_coverage_evidence / missing_test_evidence) and required-tool enforcement
			# read the truth. Unknown status fails closed as execution-error.
			case "$cstatus" in
				fail | findings | warn) status="findings"; executed=true; installed=true ;;
				pass) status="pass"; executed=true; installed=true ;;
				unavailable) status="unavailable"; executed=false ;;
				not-configured) status="not-configured"; configured=false; executed=false ;;
				execution-error) status="execution-error"; executed=false ;;
				disabled) status="disabled"; configured=false; executed=false ;;
				not-applicable) status="not-applicable"; executed=false ;;
				'')
					# Empty cstatus: no collector for this tool -> a present, valid report means it
					# ran, so pass. A collector that ran but returned an empty status is an anomaly
					# -> fail closed as execution-error.
					# KNOWN GAP, deliberately NOT closed in this hotfix. A tool with no
					# collector cannot be verified from its report, so a REQUIRED one
					# ({} in larastan.json / pint.json / syft.json) is granted a clean
					# pass on file presence alone. Making it fail closed here is a
					# one-line change — and it turns all five e2e fixtures and every
					# profile requiring these tools red, because the real remedy is to
					# WRITE the missing collectors, not to reject the reports. That is
					# Wave-2 work; shipping the strictness without the collectors would
					# be a breaking change disguised as a security fix.
					# Tracked in the audit as "required tools without collectors".
					if [ "$_hascol" = "0" ]; then
						[ "$tpol" = "required" ] && log_warn "$tkey: required tool has no collector; its report is accepted UNVERIFIED (known gap — see docs/fail-closed-evidence.md)"
						status="pass"; executed=true; installed=true
					else status="execution-error"; executed=false; fi ;;
				*) status="execution-error"; executed=false ;;
			esac
		else
			# Report absent/invalid: NEVER becomes a clean 0.
			if tool_exe_present "$texe" "$TARGET_DIR"; then installed=true; fi
			if [ "$installed" = "false" ]; then
				status="unavailable"
			elif [ -n "$tcfgp" ] && [ "$tcfgc" = "never-touch" ] && ! config_present "$tcfgp" "$TARGET_DIR"; then
				status="not-configured"; configured=false
			else
				status="execution-error"
			fi
		fi

		# Gating + counters. Only REQUIRED tools fail the gate per-tool; one-of is
		# gated at the GROUP level (see one_of_groups), recommended/optional are
		# visibility-only here (the enforcer downgrades them to warn/info).
		if [ "$tpol" = "required" ] && [ "$status" != "not-applicable" ]; then
			gate_enforced=true
			case "$status" in
				unavailable) REQ_FAIL=$((REQ_FAIL + 1)) ;;
				execution-error) REQ_FAIL=$((REQ_FAIL + 1)); EXE_FAIL=$((EXE_FAIL + 1)) ;;
				not-configured) REQ_FAIL=$((REQ_FAIL + 1)); CFG_FAIL=$((CFG_FAIL + 1)) ;;
				disabled) REQ_FAIL=$((REQ_FAIL + 1)); CFG_FAIL=$((CFG_FAIL + 1)) ;;
			esac
		else
			gate_enforced=false
		fi

		msg=$(policy_message "$status")
		obj=$(jq -n --arg emit "$emit" --arg tool "$tkey" --arg pol "$tpol" \
			--arg appl "$tappl" --argjson inst "$installed" --argjson cfg "$configured" \
			--argjson exec "$executed" --argjson ge "$gate_enforced" --arg st "$status" \
			--arg rep "$trep" --arg msg "$msg" '
			{ _emit: $emit, tool: $tool, policy: $pol, applicability: $appl,
			  installed: $inst, configured: $cfg, executed: $exec, gate_enforced: $ge,
			  status: $st, report: $rep, message: $msg }')
		POLICY_COLLECTED="${POLICY_COLLECTED}${obj}
"
	done <<EOF
$_rows
EOF

	POLICY_TOOLS=$(printf '%s' "$POLICY_COLLECTED" | jq -s 'reduce .[] as $o ({}; .[$o._emit] = ($o | del(._emit)))')

	# one-of group echo + unsatisfied groups fail the gate. POST-EXECUTION the REPORT
	# is the source of truth: a group whose normalized report (e.g. reports/raw/tests.json)
	# is present + valid JSON is SATISFIED — a member actually ran and produced evidence —
	# regardless of whether a member executable is on PATH right now (the resolver's
	# exe-based status is only a pre-flight heuristic). Absent/invalid report => fall back
	# to the resolver status; a required group with neither is unsatisfied (gate fails).
	ONEOF_ECHO='{}'
	_unsat=0
	for _g in $(printf '%s' "$EFF" | jq -r '(.one_of_groups // {}) | keys[]'); do
		_grep=$(printf '%s' "$EFF" | jq -r --arg g "$_g" '(.tools[$g].report // (.one_of_groups[$g].alternatives[]? as $m | .tools[$m].report) // "")' | head -n1)
		_gsel=$(printf '%s' "$EFF" | jq -r --arg g "$_g" '.one_of_groups[$g].selected // ""')
		_gstatus=$(printf '%s' "$EFF" | jq -r --arg g "$_g" '.one_of_groups[$g].status // "unknown"')
		if [ -n "$_grep" ]; then
			_grf="$RAW_DIR/$(basename -- "$_grep")"
			# A one-of group is satisfied by EVIDENCE, not by a file existing (v2.0.2
			# hotfix). This previously accepted any present, valid-JSON report — so
			# `printf '{}' > reports/raw/tests.json` marked the required test group
			# satisfied without a single test having run. The group's own COLLECTOR
			# result is now the authority: it must have produced a real evidence status
			# (pass/findings/fail/warn). unavailable / not-configured / execution-error /
			# disabled and unrecognized statuses leave the resolver's verdict standing.
			if [ -f "$_grf" ] && [ -s "$_grf" ] && jq -e . "$_grf" >/dev/null 2>&1; then
				# Resolve the collector by the REPORT FILENAME, not the group key. A
				# one-of group key is abstract (`php-tests`) and its members are
				# `pest`/`phpunit`, but the collector that actually parsed the file is
				# registered in TOOL_TABLE against the raw filename (tests.json -> tests).
				_gbase=$(basename -- "$_grf")
				_gemit=$(printf '%s\n' "$TOOL_TABLE" | awk -F'|' -v f="$_gbase" '$2==f{print $4; exit}')
				[ -n "$_gemit" ] || _gemit=$(emit_name_for "$_g")
				_gcol=$(printf '%s' "$TOOLSOBJ" | jq -r --arg e "$_gemit" '(.[$e].status) // ""')
				case "$_gcol" in
					pass | findings | fail | warn) _gstatus="satisfied" ;;
					'')
						# No collector understands this report at all: fall back to the
						# resolver's own verdict rather than inventing satisfaction.
						log_warn "one-of group '$_g': no collector is registered for '$_gbase'; leaving resolver status '$_gstatus'" ;;
					*)
						log_warn "one-of group '$_g': report '$_grf' is present but carries no valid evidence (collector status '$_gcol'); NOT counted as satisfied"
						_gstatus="unsatisfied" ;;
				esac
			fi
		fi
		[ "$_gstatus" = "unsatisfied" ] && _unsat=$((_unsat + 1))
		ONEOF_ECHO=$(printf '%s' "$ONEOF_ECHO" | jq --arg g "$_g" --arg st "$_gstatus" --arg sel "$_gsel" \
			'. + {($g): {status: $st, selected: (if $sel=="" then null else $sel end)}}')
	done
	REQ_FAIL=$((REQ_FAIL + _unsat))

	# missing_coverage_evidence (v2.1): an APPLICABLE coverage tool that produced no valid report
	# means strict/regulated has NO coverage evidence (so the gate can fail on ABSENT coverage, not
	# only on bad coverage). Emit-name matches /coverage/ (coverage, php_coverage, js_coverage).
	# "unknown" applicability counts as applicable (fail closed). A present report (status
	# pass/findings) is evidence and never counts as missing.
	# Main coverage tools only (php_coverage/js_coverage) — NOT diff-coverage (which has its own
	# changed_lines_coverage_violations gate), so a missing diff report never fakes a missing
	# main-coverage failure.
	MISSING_COV=$(printf '%s' "$POLICY_TOOLS" | jq -r '
		[ to_entries[]
		  | select((.key | test("coverage")) and (.key | test("diff") | not))
		  | select((.value.applicability // "unknown") != "not-applicable")
		  | select((.value.status // "") | IN("unavailable","not-configured","execution-error")) ] | length
		| if . > 0 then "true" else "false" end')

	# missing_test_evidence / empty_test_suite (v2.1): each APPLICABLE test stack must produce a
	# non-empty test report. Expected test reports = distinct reports of profile tools with
	# category=="tests" (e.g. tests.json for PHP, js-tests.json for JS) — so PHP and JS stay
	# independent (PHP tests never satisfy JS, and vice-versa). A missing/invalid report is
	# missing evidence; a present report with 0 tests is an empty suite. Never faked.
	_test_reports=$(printf '%s' "$EFF" | jq -r '
		[ .tools[]? | select((.category // "") == "tests")
		  | select((.applicability // "unknown") != "not-applicable")
		  | .report ] | map(select(. != null and . != "")) | unique[]' 2>/dev/null || true)
	for _tr in $_test_reports; do
		_trf="$RAW_DIR/$(basename -- "$_tr")"
		if [ -f "$_trf" ] && [ -s "$_trf" ] && jq -e . "$_trf" >/dev/null 2>&1; then
			# A present report that honestly reports a non-clean status (unavailable /
			# not-configured / execution-error / disabled) is MISSING test evidence — NOT an
			# empty (but successful) suite. Only a clean report with tests:0 is empty_test_suite.
			_tst=$(jq -r '.status // ""' "$_trf" 2>/dev/null || printf '')
			case "$_tst" in
				unavailable | not-configured | execution-error | disabled)
					MISSING_TEST=true ;;
				*)
					_tc=$(jq -r '((.tests // 0) | if type=="number" then floor else 0 end)' "$_trf" 2>/dev/null || printf 0)
					case "$_tc" in '' | *[!0-9]*) _tc=0 ;; esac
					[ "$_tc" -eq 0 ] && EMPTY_SUITE=true ;;
			esac
		else
			MISSING_TEST=true
		fi
	done

	# missing_architecture_evidence (v2.1.0): every APPLICABLE architecture producer declared by
	# the profile (category=="architecture") must produce VALID evidence — a report whose status
	# is pass or findings. A missing/invalid report, or an honest unavailable / not-configured /
	# execution-error / disabled status, is MISSING evidence: "we never ran it" must never read as
	# "we are clean". Unknown status fails closed (execution-error) in the collector already.
	# Producer-agnostic: Deptrac, PHPArkitect, dependency-cruiser, ESLint boundaries and custom
	# architecture tests are all just producers of the same contract.
	# The consuming project's architecture policy can switch this off honestly:
	# architecture.enabled=false or architecture.evidence_required=false -> never missing. An
	# ABSENT policy means governance is on with evidence required (the profile still decides
	# which producers are applicable, and the MODE still decides whether this blocks).
	_ap_file="${TARGET_DIR:+$TARGET_DIR/}.sentinel-shield/architecture-policy.yaml"
	_arch_required=1
	if [ -f "$_ap_file" ]; then
		# shellcheck source=scripts/lib/architecture-policy.sh
		. "$SCRIPT_DIR/lib/architecture-policy.sh"
		ap_load "$_ap_file"
		if ! ap_enabled || [ "$(ap_bool architecture.evidence_required true)" != "true" ]; then
			_arch_required=0
		fi
	fi
	if [ "$_arch_required" -eq 1 ] && [ "$ARCH_EVIDENCE_EMITS" != " " ]; then
		# Evidence is decided by the COLLECTOR-derived per-tool status in POLICY_TOOLS — never by
		# re-reading the raw report. The collector is the component that understands each
		# producer's shape: it turns an unrecognized shape, an unknown status, or a malformed
		# violation count into execution-error, and the policy overlay preserves that. Re-parsing
		# the raw file here would silently overrule it, so a valid-JSON-but-unreadable report
		# (e.g. {"some":"other","shape":true}) could satisfy strict/regulated. It must not.
		#
		#   pass | findings | fail | warn                              -> evidence exists
		#   unavailable | not-configured | execution-error | disabled  -> MISSING evidence
		#   not-applicable                                             -> ignored
		#   anything else (unknown)                                    -> MISSING evidence (fail closed)
		MISSING_ARCH=$(printf '%s' "$POLICY_TOOLS" | jq -r --arg emits "$ARCH_EVIDENCE_EMITS" '
			[ to_entries[]
			  | . as $e
			  | select($emits | contains(" " + $e.key + " "))
			  | select(($e.value.status // "") != "not-applicable")
			  | select(($e.value.status // "") | IN("pass","findings","fail","warn") | not) ]
			| length | if . > 0 then "true" else "false" end')
		case "$MISSING_ARCH" in
			true | false) : ;;
			*) die_cfg "internal: could not derive missing_architecture_evidence from tool policy statuses" ;;
		esac
	fi

	# --- testing discipline: missing_* evidence gates (v2.2.0) -----------------
	# Sentinel Shield enforces test-first discipline through EVIDENCE, never by claiming to know
	# that tests were written first. Each channel is missing only when it was EXPECTED and no
	# valid evidence exists — so a library is never failed for absent BDD/ATDD it never adopted.
	#
	# Expectation comes from two independent sources, either of which is sufficient:
	#   1. the PROFILE declares a REQUIRED producer in that category, or
	#   2. the consuming project's testing-discipline POLICY explicitly requires it
	#      (testing_discipline.bdd.enabled + require_behavior_specs, and the ATDD equivalent).
	# Policy can also switch a channel OFF honestly (testing_discipline.enabled=false, or the
	# per-channel enabled flag) — an absent policy means TDD on, BDD/ATDD off.
	# Channel switches are tracked SEPARATELY from "does the policy require evidence":
	#   _bdd_on / _atdd_on  — is the channel enabled at all?
	#   _bdd_req / _atdd_req — does the policy itself demand evidence?
	# A channel explicitly switched OFF wins over a profile that declares a REQUIRED producer:
	# `bdd.enabled: false` is the project stating this channel does not apply here, and a
	# profile default must not override that statement. The master switch
	# (testing_discipline.enabled: false) turns all three channels off.
	_td_file="${TARGET_DIR:+$TARGET_DIR/}.sentinel-shield/testing-discipline-policy.yaml"
	_td_on=1; _tdd_on=1; _bdd_on=1; _atdd_on=1; _bdd_req=0; _atdd_req=0
	if [ -f "$_td_file" ]; then
		# shellcheck source=scripts/lib/testing-discipline-policy.sh
		. "$SCRIPT_DIR/lib/testing-discipline-policy.sh"
		td_load "$_td_file"
		td_enabled || _td_on=0
		td_tdd_enabled || _tdd_on=0
		# NOTE the asymmetry, and it is deliberate: bdd.enabled DEFAULTS TO FALSE, so a policy
		# file that never mentions BDD leaves _bdd_on=0 and the channel is expectation-free
		# unless a profile requires a producer. Only an EXPLICIT `enabled: false` should be able
		# to veto a required profile producer, so the veto below tests key presence, not just
		# the resolved value.
		if td_key_present testing_discipline.bdd.enabled \
			&& [ "$(td_bool testing_discipline.bdd.enabled false)" != "true" ]; then _bdd_on=0; fi
		if td_key_present testing_discipline.atdd.enabled \
			&& [ "$(td_bool testing_discipline.atdd.enabled false)" != "true" ]; then _atdd_on=0; fi
		td_bdd_required && _bdd_req=1
		td_atdd_required && _atdd_req=1
	fi

	# td_missing_for <space-padded-emit-list> <report-flag> — "true" when ANY expected producer
	# in that channel failed to produce valid evidence. Two independent signals are honoured:
	#   * the collector-derived STATUS (unavailable / not-configured / execution-error /
	#     disabled, or anything unrecognized) — "we never ran it", and
	#   * the collector's own missing_* verdict in its tool_report — the case where a producer
	#     DID run but knows its result is not evidence (0 acceptance tests, 0 behavior specs,
	#     no resolvable diff base).
	# The raw report is never re-parsed here: the collector is the component that understands
	# each producer's shape, and re-reading the file would silently overrule it.
	# td_no_evidence_for <space-padded-emit-list> <report-flag> — "true" when NOT ONE producer in
	# the list produced usable evidence. The ANY-of counterpart to td_missing_for, used when a
	# POLICY demands a channel but the profile names no specific producer: any single producer
	# that ran and reported real evidence satisfies the requirement.
	td_no_evidence_for() {
		printf '%s' "$TOOLSOBJ" | jq -r --arg emits "$1" --arg flag "$2" '
			[ to_entries[]
			  | . as $e
			  | select($emits | contains(" " + $e.key + " "))
			  | select((($e.value.status // "") | IN("pass","findings","fail","warn"))
					and (($e.value[$flag] // false) != true)) ]
			| length | if . > 0 then "false" else "true" end'
	}

	td_missing_for() {
		printf '%s' "$TOOLSOBJ" | jq -r --arg emits "$1" --arg flag "$2" '
			[ to_entries[]
			  | . as $e
			  | select($emits | contains(" " + $e.key + " "))
			  | select(($e.value.status // "") != "not-applicable")
			  | select((($e.value.status // "") | IN("pass","findings","fail","warn") | not)
					or (($e.value[$flag] // false) == true)) ]
			| length | if . > 0 then "true" else "false" end'
	}

	if [ "$_td_on" -eq 1 ] && [ "$_tdd_on" -eq 1 ] && [ "$TDD_EVIDENCE_EMITS" != " " ]; then
		MISSING_TCE=$(td_missing_for "$TDD_EVIDENCE_EMITS" missing_test_change_evidence)
	fi
	# Two different questions, two different quantifiers:
	#   profile declares REQUIRED producers -> EVERY one of them must produce evidence (ALL).
	#     The profile author named each producer deliberately; a silent one is missing evidence.
	#   policy requires the channel but the profile names no producer -> ANY known producer
	#     satisfies it. The project asked for "behavior specs", not for Behat specifically, so a
	#     Cucumber-only project is not failed for the absence of Behat.
	BDD_ALL_EMITS=" behat_specs cucumber_specs behavior_specs "
	ATDD_ALL_EMITS=" playwright_acceptance cypress_acceptance behat_acceptance cucumber_acceptance acceptance_tests "

	if [ "$_td_on" -eq 1 ] && [ "$_bdd_on" -eq 1 ]; then
		if [ "$BDD_EVIDENCE_EMITS" != " " ]; then
			MISSING_BDD=$(td_missing_for "$BDD_EVIDENCE_EMITS" missing_behavior_specification)
		elif [ "$_bdd_req" -eq 1 ]; then
			MISSING_BDD=$(td_no_evidence_for "$BDD_ALL_EMITS" missing_behavior_specification)
		fi
	fi
	if [ "$_td_on" -eq 1 ] && [ "$_atdd_on" -eq 1 ]; then
		if [ "$ATDD_EVIDENCE_EMITS" != " " ]; then
			MISSING_ATDD=$(td_missing_for "$ATDD_EVIDENCE_EMITS" missing_acceptance_evidence)
		elif [ "$_atdd_req" -eq 1 ]; then
			MISSING_ATDD=$(td_no_evidence_for "$ATDD_ALL_EMITS" missing_acceptance_evidence)
		fi
	fi
	for _tdv in "$MISSING_TCE" "$MISSING_BDD" "$MISSING_ATDD"; do
		case "$_tdv" in
			true | false) : ;;
			*) die_cfg "internal: could not derive a testing-discipline evidence flag from tool policy statuses" ;;
		esac
	done

	# Merge policy objects onto the collector tool reports (policy fields win; the
	# unavailable/etc. status overwrites any collector "unavailable"); detail kept.
	TOOLSOBJ=$(jq -n --argjson base "$TOOLSOBJ" --argjson pol "$POLICY_TOOLS" '$base * $pol')
fi

# --- evidence ----------------------------------------------------------------
SBOM_PATH="$REPORTS_DIR/sbom.spdx.json"
RELEASE_PATH="$REPORTS_DIR/release-evidence.md"
if [ -f "$SBOM_PATH" ]; then SP=true; MS=false; else SP=false; MS=true; fi
if [ -f "$RELEASE_PATH" ]; then RP=true; MR=false; else RP=false; MR=true; fi

# --- exceptions --------------------------------------------------------------
EXC="$REPORTS_DIR/exceptions.json"
EA=0
EE=0
if [ -f "$EXC" ] && [ -s "$EXC" ]; then
	if jq -e . "$EXC" >/dev/null 2>&1; then
		EA=$(jq '(.active // 0)' "$EXC")
		EE=$(jq '(.expired // 0)' "$EXC")
		case "$EA" in '' | *[!0-9]*) die_cfg "exceptions.active must be a non-negative integer in $EXC" ;; esac
		case "$EE" in '' | *[!0-9]*) die_cfg "exceptions.expired must be a non-negative integer in $EXC" ;; esac
	else
		die_cfg "invalid JSON in $EXC"
	fi
fi

# --- assemble ----------------------------------------------------------------
jq -n \
	--argjson counts "$COUNTS" \
	--argjson tools "$TOOLSOBJ" \
	--arg version "1.0" \
	--arg gen "$TS" \
	--arg pname "$PNAME" --arg ptype "$PTYPE" --arg crit "$CRIT" \
	--arg commit "$COMMIT" --arg branch "$BRANCH" --arg workflow "$WORKFLOW" \
	--argjson ms "$MS" --argjson mr "$MR" \
	--argjson sp "$SP" --argjson rp "$RP" \
	--arg sbom_path "$SBOM_PATH" --arg rel_path "$RELEASE_PATH" \
	--argjson ea "$EA" --argjson ee "$EE" \
	--argjson havepol "$HAVE_POLICY" --argjson oneof "$ONEOF_ECHO" \
	--argjson reqf "$REQ_FAIL" --argjson cfgf "$CFG_FAIL" --argjson exef "$EXE_FAIL" \
	--argjson misscov "$MISSING_COV" --argjson misstest "$MISSING_TEST" --argjson emptysuite "$EMPTY_SUITE" \
	--argjson missarch "$MISSING_ARCH" \
	--argjson misstce "$MISSING_TCE" --argjson missbdd "$MISSING_BDD" --argjson missatdd "$MISSING_ATDD" '
	{
		version: $version,
		project: { name: $pname, type: $ptype, criticality: $crit },
		generated_at: $gen,
		source: { commit: $commit, branch: $branch, workflow: $workflow },
		summary: ($counts
			+ { missing_sbom: $ms, missing_release_evidence: $mr }
			# expired_exceptions has TWO independent sources and both must survive
			# (v2.0.2 hotfix, #51). This previously read `expired_exceptions: $ee`, which
			# unconditionally OVERWROTE any collector-reported expiry with the count from
			# reports/exceptions.json alone — so a collector that detected an expired
			# waiver had its finding silently discarded on the way into the summary.
			+ { expired_exceptions: (($counts.expired_exceptions // 0) + $ee) }
			+ (if $havepol == 1 then { required_tool_failures: $reqf, tool_configuration_failures: $cfgf, tool_execution_failures: $exef, missing_coverage_evidence: $misscov, missing_test_evidence: $misstest, empty_test_suite: $emptysuite, missing_architecture_evidence: $missarch, missing_test_change_evidence: $misstce, missing_behavior_specification: $missbdd, missing_acceptance_evidence: $missatdd } else {} end)),
		tools: $tools,
		exceptions: { active: $ea, expired: $ee },
		evidence: {
			sbom: { present: $sp, path: $sbom_path },
			release_evidence: { present: $rp, path: $rel_path }
		}
	} + (if $havepol == 1 then { one_of_groups: $oneof } else {} end)' > "$OUTPUT"

# Final self-check: valid JSON and consistent evidence booleans.
jq -e '
	(.summary.missing_sbom == (.evidence.sbom.present | not))
	and (.summary.missing_release_evidence == (.evidence.release_evidence.present | not))
	# expired_exceptions aggregates the exceptions file AND any collector-reported
	# expiry, so it must be >= the file count — never equal-by-construction (v2.0.2).
	# The old `==` assertion is precisely what cemented the overwrite it was meant to
	# verify: it could only hold if collector-reported expiries were discarded.
	and (.summary.expired_exceptions >= .exceptions.expired)
' "$OUTPUT" >/dev/null || die_cfg "internal consistency check failed for $OUTPUT"

log_info "wrote $OUTPUT (mode-agnostic findings; enforce with scripts/enforce-gates.sh)"
log_info "summary: $(printf '%s' "$COUNTS" | jq -c '.')  missing_sbom=$MS missing_release_evidence=$MR"
