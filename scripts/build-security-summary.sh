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
# Date validation and the trusted-UTC-date rule live in ONE place (#226); exception records
# are classified with the same clock and the same calendar rules as control waivers.
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"
# Canonical identifier grammar + structural set primitives (#251).
# shellcheck source=scripts/lib/profile-schema.sh
. "$SCRIPT_DIR/lib/profile-schema.sh"

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

# resolve_report_path <declared-report-path> — the artifact a PROFILE-declared report
# resolves to, with its directory components PRESERVED (#236). The declared path used to
# be reduced to `$RAW_DIR/$(basename …)`, which threw away every directory: two contexts
# declaring `web/reports/raw/eslint.json` and `api/reports/raw/eslint.json` collided, a
# missing report could be satisfied by an unrelated file with the same basename, and a
# profile declaring an absolute or traversing path was never checked as such because only
# its last component survived.
#
# The declared path is repository-relative and must live under the canonical raw-report
# root `reports/raw/`; the remainder (directories included) is joined to the ACTUAL raw
# directory, which the caller may relocate with --raw-dir (downloaded CI artifacts).
# Anything else fails closed: an absolute path, traversal, a backslash separator, a
# control or shell-unsafe character, an empty remainder, or a symlinked artifact.
resolve_report_path() {
	_rp="$1"
	case "$_rp" in
		/*) die_cfg "profile declares an ABSOLUTE report path '$_rp'; report paths must be repository-relative under reports/raw/" ;;
		*..*) die_cfg "profile declares a traversing report path '$_rp'; report paths may not contain '..'" ;;
		*\\*) die_cfg "profile declares a report path with a backslash separator '$_rp'; use '/'" ;;
	esac
	if printf '%s' "$_rp" | LC_ALL=C grep -q '[^A-Za-z0-9._/-]'; then
		die_cfg "profile declares an unsafe report path '$_rp' (allowed: letters, digits, '.', '_', '-', '/')"
	fi
	case "$_rp" in
		reports/raw/*) _rel=${_rp#reports/raw/} ;;
		*) die_cfg "profile declares report path '$_rp' outside the canonical raw-report root reports/raw/" ;;
	esac
	[ -n "$_rel" ] || die_cfg "profile declares an empty report path under reports/raw/"
	case "$_rel" in
		*/) die_cfg "profile declares a directory as a report path '$_rp'" ;;
	esac
	printf '%s/%s' "$RAW_DIR" "$_rel"
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
# Require evidence to be BOUND to this run by a producer manifest (#237). Off by default so
# a project without the cross-workflow handoff still gets content validation; on, an
# unattributed artifact is not evidence.
REQUIRE_EV_PROVENANCE=0
PNAME="unknown"
PTYPE="unknown"
CRIT="medium"
COMMIT="unknown"
BRANCH="master"
WORKFLOW="local"
# Source attestation (#241). These are DERIVED from the CI platform when it is present; a
# CLI value that contradicts the platform is a configuration failure, not an override.
REPOSITORY=""
REF=""
EVENT=""
RUN_ID=""
RUN_ATTEMPT=""
STRICT_TOOLS=0
# (#251) A newline-delimited STRUCTURAL set of validated tool identifiers, tested
# with whole-line equality. It was a space-padded string matched with
# `*" $key "*`, so `--require-tool "trivy fs"` silently became two requirements
# and a key could match across element boundaries.
REQUIRE_TOOLS=""
PROFILE_NAME=""    # when set, overlay effective-profile tool policy onto summary.tools
STAGE=""
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
  --stage <stage>         pr | main | scheduled. Scopes REQUIRED-tool gating to the tools the
                          profile selects for that stage (matching run-tool-plan.sh). Status is
                          still reported for every tool; only gating is scoped. Omit to keep the
                          stage-blind behaviour.
  --strict-tools          Fail (exit 1) if ANY expected raw artifact is missing
  --require-tool <tool>   Fail (exit 1) if this tool's artifact is missing (repeatable)
  --repository <owner/name>  Source repository. Derived from GITHUB_REPOSITORY in CI; a
                          conflicting value fails closed.
  --ref <ref>             Full ref (refs/heads/…, refs/tags/…). Derived from GITHUB_REF.
  --event <name>          Triggering event. Derived from GITHUB_EVENT_NAME.
  --run-id <id>           CI run id. Only meaningful in CI; refused for a local build.
  --run-attempt <n>       CI run attempt. Only meaningful in CI.
  --require-evidence-provenance
                          Treat SBOM/release evidence that no producer manifest binds to
                          this repository/run/commit as MISSING, not merely unattributed.
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
		--require-evidence-provenance) REQUIRE_EV_PROVENANCE=1; shift ;;
		--project-name) PNAME="${2:?--project-name requires a value}"; shift 2 ;;
		--project-type) PTYPE="${2:?--project-type requires a value}"; shift 2 ;;
		--criticality) CRIT="${2:?--criticality requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--branch) BRANCH="${2:?--branch requires a value}"; shift 2 ;;
		--workflow) WORKFLOW="${2:?--workflow requires a value}"; shift 2 ;;
		--repository) REPOSITORY="${2:?--repository requires a value}"; shift 2 ;;
		--ref) REF="${2:?--ref requires a value}"; shift 2 ;;
		--event) EVENT="${2:?--event requires a value}"; shift 2 ;;
		--run-id) RUN_ID="${2:?--run-id requires a value}"; shift 2 ;;
		--run-attempt) RUN_ATTEMPT="${2:?--run-attempt requires a value}"; shift 2 ;;
		--strict-tools) STRICT_TOOLS=1; shift ;;
		--require-tool)
			_rt="${2:?--require-tool requires a value}"
			ps_valid_id "$_rt" || die_cfg "--require-tool: invalid tool identifier: reason=$(ps_id_reject_reason "$_rt" || true) value=$(ps_id_render "$_rt") (must match $PS_ID_PATTERN)"
			REQUIRE_TOOLS=$(ps_set_add "$_rt" "$REQUIRE_TOOLS"); shift 2 ;;
		--profile) PROFILE_NAME="${2:?--profile requires a value}"; shift 2 ;;
		--stage) STAGE="${2:?--stage requires a value}"; shift 2 ;;
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

case "$STAGE" in
	'' | pr | main | scheduled) ;;
	*) log_error "--stage must be pr|main|scheduled (got '$STAGE')"; exit 2 ;;
esac

# --- source attestation (#241) -----------------------------------------------
# `commit`, `branch` and `workflow` were free-form CLI labels defaulting to
# `unknown`/`master`/`local`, emitted verbatim: a summary could claim any commit, and
# nothing distinguished a real CI run from a local build asserting one.
#
# THE BUILDER NEVER ASSERTS TRUST. `GITHUB_*` variables are CLAIMS supplied to this process —
# any local shell can export them — so they populate source METADATA and nothing more. The
# emitted trust level is always `unverified`; only a separate attestation-verification step
# (scripts/verify-source-attestation.sh) may raise it to `github-actions-attested`, and it
# does that by verifying platform provenance, not by reading the environment.
#
# Because neither the CLI value nor the environment value is trusted, a disagreement between
# them is RECORDED (both are kept, and the platform claim is reported) rather than fatal: a
# fixture or replay build legitimately names a commit the surrounding process does not have,
# and refusing it would only push callers to unset the variable — buying no security while
# breaking honest use.
ss_token_ok() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/@+-]{0,199}$'; }

# sa_claim <label> <cli-value> <platform-value> — record the value. The caller wins when it
# supplied one; otherwise the platform claim fills it in. A disagreement is reported and
# recorded in SA_DIVERGED.
#
# This assigns to SA_DIVERGED rather than echoing, because a command substitution runs in a
# SUBSHELL — an assignment made there is discarded, which silently emptied the divergence
# list. The resolved value comes back in SA_VALUE.
sa_claim() {
	if [ -n "$2" ]; then
		SA_VALUE="$2"
		if [ -n "$3" ] && [ "$2" != "$3" ]; then
			log_warn "source: --$1 '$2' differs from the environment claim '$3'; recording the value you passed. Neither is trusted — trust comes from attestation verification, not from either of these."
			SA_DIVERGED="${SA_DIVERGED}${1} "
		fi
	else
		SA_VALUE="$3"
	fi
}

# Always `unverified` out of this script. See the note above.
SOURCE_TRUST="unverified"
SA_DIVERGED=""

sa_claim repository "$REPOSITORY" "${GITHUB_REPOSITORY:-}";   REPOSITORY="$SA_VALUE"
sa_claim ref "$REF" "${GITHUB_REF:-}";                        REF="$SA_VALUE"
sa_claim event "$EVENT" "${GITHUB_EVENT_NAME:-}";             EVENT="$SA_VALUE"
sa_claim run-id "$RUN_ID" "${GITHUB_RUN_ID:-}";               RUN_ID="$SA_VALUE"
sa_claim run-attempt "$RUN_ATTEMPT" "${GITHUB_RUN_ATTEMPT:-}"; RUN_ATTEMPT="$SA_VALUE"
if [ -n "${GITHUB_SHA:-}" ] && [ "$COMMIT" = "unknown" ]; then COMMIT="${GITHUB_SHA}"; fi
if [ -n "${GITHUB_SHA:-}" ] && [ "$COMMIT" != "unknown" ] && [ "$COMMIT" != "${GITHUB_SHA}" ]; then
	log_warn "source: --commit '$COMMIT' differs from the environment claim '${GITHUB_SHA}'; recording the value you passed. Neither is trusted — a summary is bound to a commit by attestation verification, not by this field."
	SA_DIVERGED="${SA_DIVERGED}commit "
fi

# A COMMIT is either a full 40-hex SHA or the explicit non-claim `unknown`. An abbreviated
# or invented commit is neither, and must not look like provenance.
if [ "$COMMIT" != "unknown" ]; then
	printf '%s' "$COMMIT" | grep -Eq '^[0-9a-fA-F]{40}$' \
		|| die_cfg "--commit must be a full 40-hex commit SHA or the literal 'unknown' (got '$COMMIT'); an abbreviated or invented commit is not provenance"
	COMMIT=$(printf '%s' "$COMMIT" | tr 'A-F' 'a-f')
fi
if [ -n "$REPOSITORY" ]; then
	case "$REPOSITORY" in
		*/*) ss_token_ok "$REPOSITORY" || die_cfg "--repository '$REPOSITORY' is not a safe owner/name identifier" ;;
		*) die_cfg "--repository must be owner/name (got '$REPOSITORY')" ;;
	esac
fi
for _sv in "branch:$BRANCH" "workflow:$WORKFLOW" "ref:$REF" "event:$EVENT"; do
	_sn=${_sv%%:*}; _svv=${_sv#*:}
	if [ -z "$_svv" ]; then continue; fi
	ss_token_ok "$_svv" || die_cfg "--$_sn '$_svv' contains characters that cannot appear in a ref/label"
done
for _sn in run-id run-attempt; do
	if [ "$_sn" = "run-id" ]; then _svv="$RUN_ID"; else _svv="$RUN_ATTEMPT"; fi
	if [ -z "$_svv" ]; then continue; fi
	case "$_svv" in *[!0-9]*) die_cfg "--$_sn must be numeric (got '$_svv')" ;; esac
done
# A run id is metadata like everything else here; it confers nothing, because the trust level
# this script emits is always `unverified`.
command_exists jq || die_cfg "jq is required but was not found. Install jq."

REPORTS_DIR=$(dirname -- "$OUTPUT")
ensure_dir "$REPORTS_DIR"
TS=$(timestamp_utc)

# --- publication safety (#238) -----------------------------------------------
# The summary used to be written by redirecting jq straight at $OUTPUT: the previous
# summary was TRUNCATED before generation began, the self-check ran on a file that had
# already replaced it, a symlinked destination redirected the write, and two concurrent
# builders raced with no interlock. The build now happens in a staging directory INSIDE
# the reports directory (same filesystem, so the final rename is atomic), is validated
# there, and is published only after its destination has been proven safe.
#
# OPERATION_ID identifies this build in the published artifact; INPUT_MANIFEST accumulates
# `producer<TAB>path<TAB>sha256` for every raw report actually consumed, so the summary
# states which bytes it was derived from.
OPERATION_ID="${GITHUB_RUN_ID:-}"
if [ -n "$OPERATION_ID" ]; then
	OPERATION_ID="gh-${OPERATION_ID}-${GITHUB_RUN_ATTEMPT:-1}"
else
	OPERATION_ID="local-${TS}-$$"
fi
INPUT_MANIFEST=""

# Single writer: mkdir is atomic on POSIX, so it is the lock. A stale lock is an explicit,
# actionable failure — never something to break automatically, because the other builder
# may still be running.
SUMMARY_LOCK="$REPORTS_DIR/.security-summary.lock"
STAGE_DIR=""
publish_cleanup() {
	if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then rm -rf -- "$STAGE_DIR"; fi
	if [ -d "$SUMMARY_LOCK" ]; then rmdir -- "$SUMMARY_LOCK" 2>/dev/null || true; fi
	return 0
}
if ! mkdir "$SUMMARY_LOCK" 2>/dev/null; then
	die_cfg "another security-summary build holds $SUMMARY_LOCK; refusing to race a second writer for $OUTPUT (remove the directory only if no build is running)"
fi
trap 'publish_cleanup' EXIT INT TERM HUP

# summary_dest_ok <path> — the destination must be a real file in a real directory: no
# symlink (which redirects the write), no directory, no FIFO/device, no missing parent.
summary_dest_ok() {
	_dd=$(dirname -- "$1")
	[ -d "$_dd" ] || { log_error "output directory does not exist: $_dd"; return 1; }
	[ -L "$_dd" ] && { log_error "output directory is a symlink: $_dd"; return 1; }
	if [ -e "$1" ] || [ -L "$1" ]; then
		[ -L "$1" ] && { log_error "refusing to publish through a symlinked destination: $1"; return 1; }
		[ -d "$1" ] && { log_error "destination is a directory: $1"; return 1; }
		[ -f "$1" ] || { log_error "destination exists and is not a regular file: $1"; return 1; }
	fi
	return 0
}

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
	ps_set_has "$key" "$REQUIRE_TOOLS" && required=1

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

	# TWO IDENTITIES, PASSED SEPARATELY (#310/#204).
	#   --tool-name  "$emit"  the CHANNEL this evidence aggregates under; renamed per stack
	#                         (php-coverage -> php_coverage) and legitimately shared by several
	#                         producers (php-style and php-cs-fixer both emit php_style).
	#   --producer-key "$key" the PRODUCER that actually ran; the identity an execution record
	#                         names and ne_execution_verify checks against.
	# This loop already distinguished them for row identity (see #235 below); collapsing them at
	# the collector boundary is what made osv-scanner and dependency-check reject their own real
	# execution records — the audit wrote "osv-scanner", the collector was told "osv_scanner".
	out=$(sh "$collector" --input "$raw" --tool-name "$emit" --producer-key "$key") || {
		log_error "collector failed for '$key' ($collector)"
		exit 1
	}
	# Producer identity travels with the row (#235). `$emit` is the normalised CHANNEL
	# (php_style), which several producers legitimately feed; `$key` is the PRODUCER
	# (php-cs-fixer). Collapsing both into one object key is what let a later report
	# silently overwrite an earlier one while its counts stayed in the aggregate.
	_psha=""
	if [ -f "$raw" ] && [ -s "$raw" ]; then _psha=$(ss_sha256_file "$raw" 2>/dev/null || printf '') ; fi
	if [ -n "$_psha" ]; then
		INPUT_MANIFEST="${INPUT_MANIFEST}${key}	${raw}	${_psha}
"
	fi
	# `-e` is load-bearing, not decoration (#145). Without it this guard NEVER fired: jq exits 0
	# on EMPTY input, printing nothing, so a collector that refused to emit — which is exactly
	# what a fail-closed emitter now does — was appended to COLLECTED as a blank line, skipped by
	# the later `jq -s`, and silently dropped from the aggregate. `-e` makes empty input exit 4
	# and a false/null document exit 1, so a collector that produced no object is a hard failure.
	out=$(printf '%s' "$out" | jq -ce --arg p "$key" --arg rp "$raw" --arg sha "$_psha" \
		'. + {producer: $p, producer_report: $rp,
		      producer_sha256: (if $sha == "" then null else $sha end)}') \
		|| die_cfg "collector '$key' did not return a JSON object"
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
# #146 — every count crossing this boundary is validated, and the SUM is bounded.
#
# The reduce below used a bare `+`. jq performs arithmetic in double, so two individually
# plausible operands could produce a sum that is not the true sum: 9007199254740991 + 2
# aggregated to 9007199254740992 on this path. Beyond that, an unbounded aggregate reaches
# `enforce-gates.sh`, where it is fed to shell `[ -gt ]` — a HARD ERROR at 2^63 with a
# different message in each supported shell.
#
# Operands are validated FIRST, because an out-of-range operand must be refused as untrusted
# evidence rather than added and inspected afterwards. The check here is RANGE only —
# non-negative and within the maximum — because integrality is already enforced upstream by
# `ss_counts_or_fail` and by the schema, and several informational keys (the coverage,
# complexity and duplication percentages) are legitimately fractional. Widening this to demand
# integers would reject valid evidence, which is not what #146 is about. Then the accumulation
# checks
# `total <= MAX - value` BEFORE adding: at 2^63 a sum wraps negative, and a negative sum
# passes a naive `<= MAX` test, so checking after the addition accepts exactly the overflow it
# is meant to catch.
_badcounts=$(printf '%s' "$ARR" | jq -r --argjson max "$SS_MAX_COUNT" '
	def bools: ["missing_test_change_evidence","missing_behavior_specification","missing_acceptance_evidence"];
	[ .[] as $c
	  | ($c.summary // {}) | to_entries[]
	  | .key as $k | select((bools | index($k)) | not)
	  | select((.value | type) == "number")
	  | select((.value < 0) or (.value > $max))
	  | "\($c.tool).\($k)=\(.value)" ] | unique | join(", ")' 2>/dev/null || printf 'unreadable')
if [ -n "$_badcounts" ]; then
	log_error "collector count(s) outside the bounded-integer contract (max $SS_MAX_COUNT): $_badcounts"
	die_cfg "a count outside the safe-integer range is untrusted evidence; it is never rounded, clamped or read as a clean 0"
fi

COUNTS=$(printf '%s' "$ARR" | jq --argjson max "$SS_MAX_COUNT" '
	def ckadd($a; $b): if $a > ($max - $b) then error("count-aggregate-overflow") else $a + $b end;
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
				.[$k] = ckadd((.[$k] // 0); ($v // 0))
			  end)
	)
	| .coverage_regression = ([.coverage_regression, 1] | min)')

# Channels with a REGISTERED deterministic merger. `php_style` is fed by php-style.sh and
# by php-cs-fixer.json (symfony declares the latter, every other PHP profile the former);
# both are the same normalised channel, so a merger is defined for it. Any OTHER duplicate
# emit name is a configuration failure — an unregistered collision means two producers are
# claiming one identity and nothing can say which report explains the aggregate counts.
MERGEABLE_CHANNELS='["php_style"]'
_dupes=$(printf '%s' "$ARR" | jq -r --argjson ok "$MERGEABLE_CHANNELS" '
	[ .[] | {t: .tool, p: .producer} ]
	| group_by(.t) | map(select(length > 1))
	| map(select(. as $g | ($ok | index($g[0].t)) == null))
	| .[] | "\(.[0].t) <- \(map(.p) | sort | join(", "))"' 2>/dev/null || true)
if [ -n "$_dupes" ]; then
	printf '%s\n' "$_dupes" | while IFS= read -r _l; do
		[ -n "$_l" ] && log_error "duplicate collector emit name: $_l"
	done
	die_cfg "two or more producers emit the same tool name with no registered merger; the later report would overwrite the earlier evidence while both remain in the aggregate counts"
fi
# Assemble the channel view. Every contributing producer is preserved under `.producers`
# (id, declared report, checksum, status), and the channel's own fields come from the
# HIGHEST-SEVERITY contributor with ties broken by producer name — so registry order can
# never change the result or the evidence.
TOOLSOBJ=$(printf '%s' "$ARR" | jq '
	def sevmap: {"execution-error":6, "not-configured":5, "unavailable":4,
	             "fail":3, "findings":3, "warn":3, "pass":2, "disabled":1, "not-applicable":0};
	def sev($s): (sevmap[$s] // 7);
	group_by(.tool)
	| map(
		# A producer that left NO artifact contributes nothing to the channel. Several
		# producers legitimately feed one channel while a given PROFILE declares only one of
		# them (symfony declares php-cs-fixer, every other PHP profile php-style), so the
		# absent producer must not outrank the real report from the applicable one with its
		# "unavailable". When NOTHING was produced, the whole set decides — so a channel with no
		# evidence is still unavailable, never a clean pass.
		( [ .[] | select(.producer_sha256 != null) ] ) as $produced
		| (if ($produced | length) > 0 then $produced else . end) as $deciding
		| {
			key: .[0].tool,
			value: (
				($deciding | sort_by([ -(sev(.tool_report.status // "")), .producer ])[0].tool_report)
				# EVERY contributor is still listed, including the ones that produced nothing.
				+ { producers: ( sort_by(.producer)
					| map({ producer: .producer, report: .producer_report,
					        sha256: .producer_sha256, status: (.tool_report.status // null) }) ) }
			)
		})
	| from_entries')

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
	# (#251) Structural, newline-delimited sets of VALIDATED identifiers, tested
	# with whole-line equality. Both were space-padded strings built by word-split
	# command substitution and matched with `*" $tkey "*`.
	DISABLED_TOOLS=""
	if [ -n "$TARGET_DIR" ] && [ -f "$TARGET_DIR/.sentinel-shield/installation.json" ]; then
		_im="$TARGET_DIR/.sentinel-shield/installation.json"
		if jq -e . "$_im" >/dev/null 2>&1; then
			_dts=$(jq -r '(.disabled_tools // [])[]' "$_im" 2>/dev/null || true)
			while IFS= read -r _d; do
				[ -n "$_d" ] || continue
				ps_valid_id "$_d" || die_cfg "invalid tool identifier in $_im .disabled_tools: reason=$(ps_id_reject_reason "$_d" || true) value=$(ps_id_render "$_d") (must match $PS_ID_PATTERN)"
				DISABLED_TOOLS=$(ps_set_add "$_d" "$DISABLED_TOOLS")
			done <<BSS_DISABLED
$_dts
BSS_DISABLED
		fi
	fi

	# one-of group members (alternatives across all groups).
	ONEOF_MEMBERS=$(printf '%s' "$EFF" | jq -r '[ (.one_of_groups // {})[].alternatives[]? ] | unique | .[]')

	# Pipe-delimited rows (empty fields preserved):
	#   key|policy|applicability|report|exes|cfgpath|cfgclass|category
	# (category is appended LAST so the existing positional fields are untouched.)
	# The STAGE column carries whether this tool is selected to run at $STAGE. A required tool
	# that does not run at this stage must not be gate-enforced here: the profiles legitimately
	# require Dependency-Check nightly, and gating it in the main-gate summary made a main run
	# unpassable no matter what the consumer did. Its status is still reported honestly — only
	# the gating is stage-scoped. With no --stage the previous (stage-blind) behaviour is kept.
	_rows=$(printf '%s' "$EFF" | jq -r --arg stage "$STAGE" '
		.tools | to_entries[]
		| [ .key, .value.policy, (.value.applicability // "unknown"),
			(.value.report // ""),
			((.value.executable // []) | join(" ")),
			(.value.config.path // ""), (.value.config.classification // ""),
			(.value.category // ""),
			(if $stage == "" then "yes"
			 # UNDECLARED is not the same as declared-false. `// false` collapsed the two, so a
			 # tool whose execution map is missing, or which simply does not name this stage,
			 # was read as "deliberately not selected here" and its required-tool enforcement
			 # was skipped — a missing declaration silently turning into a clean result.
			 # Undeclared now selects the tool: an unstated stage policy is not permission to
			 # stop enforcing a REQUIRED tool. Explicit true/false still mean exactly that.
			 elif ((.value.execution | type) != "object") then "yes"
			 elif ((.value.execution | has($stage)) | not) then "yes"
			 elif (.value.execution[$stage] == true) then "yes"
			 else "no" end) ]
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
	while IFS='|' read -r tkey tpol tappl trep texe tcfgp tcfgc tcat tstage; do
		[ -n "$tkey" ] || continue

		# Which tools get a per-tool object: required/recommended/optional always;
		# one-of MEMBERS yes; the one-of GROUP entry (policy one-of, not a member,
		# e.g. 'tests') is represented in one_of_groups only; disabled/external skip.
		_is_member=0
		ps_set_has "$tkey" "$ONEOF_MEMBERS" && _is_member=1
		case "$tpol" in
			required | recommended | optional) : ;;
			one-of) [ "$_is_member" -eq 1 ] || continue ;;
			*) continue ;;
		esac

		emit=$(emit_name_for "$tkey")
		repfile=""
		if [ -n "$trep" ]; then
			repfile=$(resolve_report_path "$trep")
			# A symlinked artifact can redirect the read outside the raw-report root; the
			# builder consumes exactly the declared artifact or nothing.
			if [ -L "$repfile" ]; then
				die_cfg "declared report '$trep' resolves to a symlink ($repfile); refusing to read evidence through it"
			fi
		fi

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
		ps_set_has "$tkey" "$DISABLED_TOOLS" && _disabled=1

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
		# WHY a required tool is not gate-enforced has to travel with the summary. The
		# enforcer used to accept any non-empty top-level `stage`, so a hand-built summary
		# could mark arbitrary required tools non-enforced by declaring a stage. The reason is
		# now per-tool and derived from the effective profile's own execution matrix.
		stage_selected=true
		[ "${tstage:-yes}" = "yes" ] || stage_selected=false
		if [ "$tpol" = "required" ] && [ "$status" != "not-applicable" ] && [ "${tstage:-yes}" = "yes" ]; then
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
			--arg rep "$trep" --arg msg "$msg" --argjson stagesel "$stage_selected" \
			--arg stage "$STAGE" '
			{ _emit: $emit, tool: $tool, policy: $pol, applicability: $appl,
			  installed: $inst, configured: $cfg, executed: $exec, gate_enforced: $ge,
			  status: $st, report: $rep, message: $msg,
			  # Per-tool execution scope, derived from the effective profile: stage_selected
			  # is false ONLY when the profile execution matrix excludes this tool at THIS
			  # stage.
			  stage: (if $stage == "" then null else $stage end),
			  stage_selected: $stagesel }')
		POLICY_COLLECTED="${POLICY_COLLECTED}${obj}
"
	done <<EOF
$_rows
EOF

	# (#251) EMIT-NAME COLLISION. `_emit` is a NORMALIZED name — the tool key with
	# `-` -> `_`, or an explicit TOOL_TABLE mapping — so two DISTINCT profile tool
	# identifiers can land on one key: `php-style` (php-library) and
	# `php-cs-fixer` (symfony) both emit `php_style`, and a profile extending both
	# composes both. The reduce below was last-wins, so the other producer's whole
	# policy row — including its `gate_enforced` verdict — vanished from the
	# summary while its counts stayed in the aggregate. An UNREGISTERED collision
	# is a configuration failure; a registered channel resolves deterministically
	# to the row that can never hide a failure.
	_pdupes=$(printf '%s' "$POLICY_COLLECTED" | jq -s -r --argjson ok "$MERGEABLE_CHANNELS" '
		[ .[] | {e: ._emit, t: .tool} ] | group_by(.e) | map(select(length > 1))
		| map(select(. as $g | ($ok | index($g[0].e)) == null))
		| .[] | "\(.[0].e) <- \(map(.t) | sort | join(", "))"' 2>/dev/null || true)
	if [ -n "$_pdupes" ]; then
		printf '%s\n' "$_pdupes" | while IFS= read -r _l; do
			[ -n "$_l" ] && log_error "profile tool identifiers collide after emit-name normalization: $_l"
		done
		die_cfg "two or more profile tool identifiers normalize to one summary key with no registered merger; the later policy row would silently replace the earlier one, including its gate_enforced verdict"
	fi
	POLICY_TOOLS=$(printf '%s' "$POLICY_COLLECTED" | jq -s '
		def sevmap: {"execution-error":6, "not-configured":5, "unavailable":4,
		             "fail":3, "findings":3, "warn":3, "pass":2, "disabled":1, "not-applicable":0};
		def sev($s): (if (sevmap | has($s)) then sevmap[$s] else 7 end);
		group_by(._emit)
		| map({ key: .[0]._emit,
		        value: ( sort_by([ (if .gate_enforced then 0 else 1 end),
		                           (0 - sev(.status)),
		                           .tool ])[0] | del(._emit) ) })
		| from_entries')

	# one-of group echo + unsatisfied groups fail the gate. POST-EXECUTION the REPORT
	# is the source of truth: a group whose normalized report (e.g. reports/raw/tests.json)
	# is present + valid JSON is SATISFIED — a member actually ran and produced evidence —
	# regardless of whether a member executable is on PATH right now (the resolver's
	# exe-based status is only a pre-flight heuristic). Absent/invalid report => fall back
	# to the resolver status; a required group with neither is unsatisfied (gate fails).
	ONEOF_ECHO='{}'
	_unsat=0
	# (#251) One group key per LINE, not word-split command substitution.
	_bgroups=$(printf '%s' "$EFF" | jq -r '(.one_of_groups // {}) | keys[]')
	while IFS= read -r _g; do
		[ -n "$_g" ] || continue
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
	done <<BSS_GROUPS
$_bgroups
BSS_GROUPS
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

# --- evidence (#237) ---------------------------------------------------------
# `present` used to mean `test -f`: touching two filenames cleared two non-suppressible
# missing-evidence gates, an empty or malformed file was indistinguishable from verified
# evidence, and a previous run's artifacts authorised the current commit. `present` now
# means VALIDATED, and the reason it is not present travels with it.
SBOM_PATH="$REPORTS_DIR/sbom.spdx.json"
RELEASE_PATH="$REPORTS_DIR/release-evidence.md"
# The producer-side manifest (scripts/build-evidence-manifest.sh) is the canonical binding
# of an artifact to a repository, run and commit. It is REUSED here, never re-implemented.
EVIDENCE_MANIFEST="$REPORTS_DIR/sentinel-shield-artifact-manifest.json"

# ev_file_state <path> — "ok", or why the path is not usable as evidence at all.
ev_file_state() {
	if [ -L "$1" ]; then printf 'symlink'; return 0; fi
	if [ ! -e "$1" ]; then printf 'absent'; return 0; fi
	if [ ! -f "$1" ]; then printf 'not-a-regular-file'; return 0; fi
	if [ ! -r "$1" ]; then printf 'unreadable'; return 0; fi
	if [ ! -s "$1" ]; then printf 'empty'; return 0; fi
	printf 'ok'
}

# ev_provenance <path> — bind the artifact to this run using the producer manifest:
#   verified          the manifest covers this file, its digest matches, and (when the
#                     caller passed a real commit) the manifest is for THAT commit
#   unbound           no manifest was produced — the artifact is unattributed
#   commit-mismatch   the manifest attests a different commit (replayed evidence)
#   digest-mismatch   the file on disk is not the file the producer recorded
#   not-in-manifest   the manifest covers this run but not this artifact
ev_provenance() {
	if [ ! -f "$EVIDENCE_MANIFEST" ]; then printf 'unbound'; return 0; fi
	if ! jq -e . "$EVIDENCE_MANIFEST" >/dev/null 2>&1; then printf 'manifest-malformed'; return 0; fi
	_mc=$(jq -r '(.commit // "")' "$EVIDENCE_MANIFEST" 2>/dev/null | tr 'A-F' 'a-f')
	_cc=$(printf '%s' "$COMMIT" | tr 'A-F' 'a-f')
	if printf '%s' "$_cc" | grep -Eq '^[0-9a-f]{40}$'; then
		if [ "$_mc" != "$_cc" ]; then printf 'commit-mismatch'; return 0; fi
	fi
	_rel=${1#"$REPORTS_DIR/"}
	_exp=$(jq -r --arg p "$_rel" '(.files // [])[] | select(.path == $p) | .sha256' "$EVIDENCE_MANIFEST" 2>/dev/null | head -1)
	if [ -z "$_exp" ]; then printf 'not-in-manifest'; return 0; fi
	_act=$(ss_sha256_file "$1" 2>/dev/null || printf '')
	if [ -z "$_act" ]; then printf 'unhashable'; return 0; fi
	if [ "$_act" != "$_exp" ]; then printf 'digest-mismatch'; return 0; fi
	printf 'verified'
}

# ev_sbom_content <path> — "ok" or the reason this is not a usable SPDX document.
#
# A ZERO-PACKAGE SBOM IS NOT INHERENTLY INVALID. This previously rejected `packages: []` outright,
# on the reasoning that an SBOM documenting nothing is not an SBOM. That is true of a document
# nothing vouches for, and false of a scan that ran against a project with no resolvable packages
# and said so — which is exactly what #135-AC3 requires to be acceptable when the document carries
# complete metadata, a target identity, and provenance proving an applicable scan completed.
#
# The rejection is preserved where the proof is ABSENT: no document name, no creation time, no
# producer, a non-array packages field, or malformed metadata. What is no longer rejected is the
# empty array alone. Whether a completed scan stands behind it is decided by the provenance
# binding, which is a separate and stronger check than counting array elements.
ev_sbom_content() {
	if ! jq -e . "$1" >/dev/null 2>&1; then printf 'malformed-json'; return 0; fi
	jq -r '
		if ((.spdxVersion // "") | test("^SPDX-2\\.[0-9]+$") | not) then "not-spdx"
		elif ((.SPDXID // "") != "SPDXRef-DOCUMENT") then "not-spdx-document"
		elif (((.name // "") | type) != "string" or ((.name // "") | length) == 0) then "no-document-name"
		elif ((.creationInfo.created // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") | not) then "no-creation-time"
		elif (((.creationInfo.creators // []) | length) == 0) then "no-producer"
		elif (((.packages // []) | type) != "array") then "no-packages"
		elif ([ (.packages // [])[] | select(((.name // "") | length) == 0 or ((.SPDXID // "") | length) == 0) ] | length) > 0 then "incomplete-packages"
		else "ok" end' "$1" 2>/dev/null || printf 'malformed-json'
}

# ev_release_content <path> — "ok" or why this Markdown is not release evidence. A file
# with a title and nothing under it is a touched filename, not an attestation.
ev_release_content() {
	if ! grep -q '^#' "$1" 2>/dev/null; then printf 'no-heading'; return 0; fi
	_lines=$(grep -c '[^[:space:]]' "$1" 2>/dev/null || printf '0')
	if [ "$_lines" -lt 3 ]; then printf 'no-content'; return 0; fi
	printf 'ok'
}

# ev_evaluate <path> <kind> — set EV_PRESENT / EV_REASON / EV_PROV / EV_SHA for one artifact.
ev_evaluate() {
	EV_PRESENT=false; EV_PROV="none"; EV_SHA=""
	EV_REASON=$(ev_file_state "$1")
	if [ "$EV_REASON" != "ok" ]; then return 0; fi
	case "$2" in
		sbom) EV_REASON=$(ev_sbom_content "$1") ;;
		release) EV_REASON=$(ev_release_content "$1") ;;
	esac
	if [ "$EV_REASON" != "ok" ]; then return 0; fi
	EV_SHA=$(ss_sha256_file "$1" 2>/dev/null || printf '')
	EV_PROV=$(ev_provenance "$1")
	case "$EV_PROV" in
		verified) EV_REASON="verified"; EV_PRESENT=true ;;
		unbound)
			# No producer manifest: the content is valid but nothing binds it to this run.
			# Callers that require attributable evidence pass --require-evidence-provenance.
			if [ "$REQUIRE_EV_PROVENANCE" -eq 1 ]; then
				EV_REASON="unattributed"
			else
				EV_REASON="verified-content-unattributed"; EV_PRESENT=true
			fi ;;
		*) EV_REASON="$EV_PROV" ;;
	esac
}

ev_evaluate "$SBOM_PATH" sbom
SP="$EV_PRESENT"; SBOM_REASON="$EV_REASON"; SBOM_PROV="$EV_PROV"; SBOM_SHA="$EV_SHA"
if [ "$SP" = "true" ]; then MS=false; else MS=true; fi
ev_evaluate "$RELEASE_PATH" release
RP="$EV_PRESENT"; REL_REASON="$EV_REASON"; REL_PROV="$EV_PROV"; REL_SHA="$EV_SHA"
if [ "$RP" = "true" ]; then MR=false; else MR=true; fi
if [ "$SP" != "true" ]; then log_warn "SBOM evidence not accepted ($SBOM_PATH): $SBOM_REASON"; fi
if [ "$RP" != "true" ]; then log_warn "release evidence not accepted ($RELEASE_PATH): $REL_REASON"; fi

# --- exceptions (#242) -------------------------------------------------------
# `.active`/`.expired` were two unauthenticated integers: `{}` meant "no exceptions" and a
# forged zero hid every expired one. A PRESENT file must now be a versioned record set, and
# the counts are DERIVED from the records rather than trusted. An ABSENT file still means
# "this project has no exceptions" — that is the honest default, not an assertion.
EXC="$REPORTS_DIR/exceptions.json"
EA=0
EE=0
EP=0
EXC_RECORDS='[]'
if [ -f "$EXC" ] && [ -s "$EXC" ]; then
	if [ -L "$EXC" ]; then die_cfg "exceptions file is a symlink: $EXC"; fi
	jq -e . "$EXC" >/dev/null 2>&1 || die_cfg "invalid JSON in $EXC"
	if ! jq -e '(.version | type == "string") and ((.exceptions // null) | type == "array")' "$EXC" >/dev/null 2>&1; then
		die_cfg "exceptions evidence must be a versioned record set { \"version\": \"1\", \"exceptions\": [ … ] } (schemas/exceptions.schema.json): $EXC. A count-only object asserts governance through two unauthenticated integers — a forged zero hides every expired exception — so it is no longer accepted. An ABSENT file still means 'no exceptions'."
	fi
	_ev=$(jq -r '.version' "$EXC")
	[ "$_ev" = "1" ] || die_cfg "unsupported exceptions version '$_ev' (expected \"1\"): $EXC"
	_today=$(cw_today_utc) || die_cfg "no trusted UTC date is available to classify exceptions"
	_ebad=$(jq -r --arg today "$_today" '
		def realdate:
			type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$");
		def ids: [ .exceptions[]? | (.id? // "") ];
		ids as $ids
		| .exceptions | to_entries[]
		| .key as $i | .value as $e
		| ( [ "id","type","scope","owner","approved_by","created_at","expires_at","reason","source" ] ) as $req
		| ( [ $req[] | select((($e[.]?) // "") | (type != "string") or (length == 0)) ] ) as $missing
		| if ($e | type != "object") then "record \($i): not an object"
		  elif ($missing | length) > 0 then "record \($i): missing/empty \($missing | join(","))"
		  elif ($e.id | test("^[A-Za-z0-9][A-Za-z0-9._-]{2,63}$") | not) then "record \($i): id \($e.id|tojson) is not a stable token"
		  elif ([ $ids[] | select(. == $e.id) ] | length) > 1 then "exception \($e.id): duplicate id — a governed exception must have exactly one identity"
		  elif ([ "accepted-risk","control-waiver","manual" ] | index($e.source) | not) then "exception \($e.id): unknown source \($e.source|tojson) (accepted-risk|control-waiver|manual)"
		  elif ($e.created_at | realdate | not) then "exception \($e.id): created_at \($e.created_at|tojson) is not a real calendar date"
		  elif ($e.expires_at | realdate | not) then "exception \($e.id): expires_at \($e.expires_at|tojson) is not a real calendar date"
		  elif ($e.created_at > $e.expires_at) then "exception \($e.id): created_at is after expires_at"
		  elif ($e.owner == $e.approved_by) then "exception \($e.id): owner == approved_by (self-approval)"
		  elif (($e.status? // null) != null)
		    and ($e.status != (if $e.expires_at < $today then "expired" else "active" end))
		    then "exception \($e.id): declared status \($e.status|tojson) contradicts its dates (expires_at \($e.expires_at), today \($today))"
		  else empty end' "$EXC" 2>/dev/null || printf 'exceptions could not be validated')
	if [ -n "$_ebad" ]; then
		printf '%s\n' "$_ebad" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "exceptions: $_l"; done
		die_cfg "invalid exception records in $EXC"
	fi
	# REAL calendar dates: the jq pass above proves the shape, but 2026-02-31 has the shape
	# of a date and is not one. The canonical calendar check is cw__valid_date (the control
	# waiver validator) — reused here, never re-implemented.
	_edates=$(jq -r '.exceptions[] | "\(.id)\t\(.created_at)\t\(.expires_at)"' "$EXC" 2>/dev/null || true)
	_erc=0
	_etab="$(printf '\t')"
	while IFS="$_etab" read -r _eid _ecre _eexp; do
		[ -n "$_eid" ] || continue
		cw__valid_date "$_ecre" || { log_error "exceptions: exception $_eid: created_at '$_ecre' is not a real calendar date"; _erc=2; }
		cw__valid_date "$_eexp" || { log_error "exceptions: exception $_eid: expires_at '$_eexp' is not a real calendar date"; _erc=2; }
	done <<EOF
$_edates
EOF
	[ "$_erc" -eq 0 ] || die_cfg "invalid exception dates in $EXC"
	# Counts are DERIVED, never read: an aggregate that disagrees with the records is a
	# forged aggregate.
	# An exception is ACTIVE only inside its own window: created_at <= today <= expires_at.
	# Classifying on expiry alone counted a record dated NEXT MONTH as active today — a
	# pre-positioned exception suppressing findings before anyone authored it.
	EA=$(jq --arg today "$_today" '[ .exceptions[] | select(.created_at <= $today and .expires_at >= $today) ] | length' "$EXC")
	EE=$(jq --arg today "$_today" '[ .exceptions[] | select(.expires_at <  $today) ] | length' "$EXC")
	EP=$(jq --arg today "$_today" '[ .exceptions[] | select(.created_at >  $today) ] | length' "$EXC")
	# A declared aggregate is allowed, but only as a CHECK on the records.
	for _k in active expired not_yet_effective; do
		_decl=$(jq -r --arg k "$_k" '(.[$k] // "") | tostring' "$EXC")
		[ -n "$_decl" ] || continue
		case "$_k" in
			active) _der="$EA" ;;
			expired) _der="$EE" ;;
			*) _der="$EP" ;;
		esac
		[ "$_decl" = "$_der" ] || die_cfg "exceptions.$_k declares $_decl but the records classify $_der — the aggregate does not match the evidence: $EXC"
	done
	EXC_RECORDS=$(jq --arg today "$_today" '[ .exceptions[]
		| { id, type, scope, source, owner, approved_by, created_at, expires_at,
		    status: (if .expires_at < $today then "expired"
		              elif .created_at > $today then "not-yet-effective"
		              else "active" end) } ]' "$EXC")
	if [ "${EP:-0}" -gt 0 ]; then
		log_warn "exceptions: $EP record(s) are dated in the FUTURE and are reported as not-yet-effective, not active — an exception cannot suppress a finding before the date it was authored."
	fi
fi

# --- assemble ----------------------------------------------------------------
# Staging lives inside the reports directory so the publishing rename is atomic (a rename
# across filesystems is a copy, which is exactly the partial-file window being closed).
STAGE_DIR=$(mktemp -d "$REPORTS_DIR/.security-summary.stage.XXXXXX") \
	|| die_cfg "could not create a staging directory under $REPORTS_DIR"
STAGED="$STAGE_DIR/security-summary.json"
# One digest over the sorted producer|path|sha256 manifest: the source attestation is bound
# to the exact evidence this summary was built from (#241).
INPUTS_DIGEST=$(printf '%s' "$INPUT_MANIFEST" | LC_ALL=C sort | ss_sha256_stdin 2>/dev/null || printf '')
INPUTS_JSON=$(printf '%s' "$INPUT_MANIFEST" | jq -R -s '
	split("\n") | map(select(length > 0) | split("\t"))
	| map({ producer: .[0], report: .[1], sha256: .[2] })')

jq -n \
	--arg opid "$OPERATION_ID" \
	--argjson inputs "$INPUTS_JSON" \
	--argjson counts "$COUNTS" \
	--argjson tools "$TOOLSOBJ" \
	--arg version "1.0" \
	--arg contract "2.2" \
	--arg stage "$STAGE" \
	--arg gen "$TS" \
	--arg pname "$PNAME" --arg ptype "$PTYPE" --arg crit "$CRIT" \
	--arg commit "$COMMIT" --arg branch "$BRANCH" --arg workflow "$WORKFLOW" \
	--arg repository "$REPOSITORY" --arg ref "$REF" --arg event "$EVENT" \
	--arg run_id "$RUN_ID" --arg run_attempt "$RUN_ATTEMPT" --arg trust "$SOURCE_TRUST" \
	--arg diverged "$SA_DIVERGED" \
	--arg inputs_digest "$INPUTS_DIGEST" \
	--argjson ms "$MS" --argjson mr "$MR" \
	--argjson sp "$SP" --argjson rp "$RP" \
	--arg sbom_path "$SBOM_PATH" --arg rel_path "$RELEASE_PATH" \
	--arg sbom_reason "$SBOM_REASON" --arg sbom_prov "$SBOM_PROV" --arg sbom_sha "$SBOM_SHA" \
	--arg rel_reason "$REL_REASON" --arg rel_prov "$REL_PROV" --arg rel_sha "$REL_SHA" \
	--argjson exc_records "$EXC_RECORDS" \
	--argjson ep "${EP:-0}" \
	--argjson ea "$EA" --argjson ee "$EE" \
	--argjson havepol "$HAVE_POLICY" --argjson oneof "$ONEOF_ECHO" \
	--argjson reqf "$REQ_FAIL" --argjson cfgf "$CFG_FAIL" --argjson exef "$EXE_FAIL" \
	--argjson misscov "$MISSING_COV" --argjson misstest "$MISSING_TEST" --argjson emptysuite "$EMPTY_SUITE" \
	--argjson missarch "$MISSING_ARCH" \
	--argjson misstce "$MISSING_TCE" --argjson missbdd "$MISSING_BDD" --argjson missatdd "$MISSING_ATDD" '
	{
		version: $version,
		# The GATE/EVIDENCE contract this summary was built for. A summary that DECLARES it is
		# held to it completely by the enforcer: a counter missing for an ENABLED gate is a
		# build defect, never a clean zero. A summary that declares nothing is legacy, and the
		# assurance modes refuse it rather than inferring evidence from absent fields.
		# Additive: consumers that do not know the field ignore it.
		gate_contract_version: $contract,
		# The STAGE this summary was built for, when the caller scoped it (--stage). Required-tool
		# gating is stage-scoped, so the enforcer needs to know that a required tool marked
		# not-gate-enforced is out of scope for this stage rather than quietly opted out.
		stage: (if $stage == "" then null else $stage end),
		project: { name: $pname, type: $ptype, criticality: $crit },
		generated_at: $gen,
		# Source ATTESTATION (#241), not source labels. `trust` says how much of this was
		# derived from a CI platform rather than asserted by the caller; `inputs_digest`
		# binds it to the exact raw reports this summary was built from, so the identity
		# cannot be transplanted onto another set of evidence.
		source: { commit: $commit, branch: $branch, workflow: $workflow,
			attestation_version: "1",
			repository: (if $repository == "" then null else $repository end),
			ref: (if $ref == "" then null else $ref end),
			event: (if $event == "" then null else $event end),
			run_id: (if $run_id == "" then null else $run_id end),
			run_attempt: (if $run_attempt == "" then null else $run_attempt end),
			# ALWAYS "unverified" from the builder. Only scripts/verify-source-attestation.sh
			# may raise this, and only by verifying platform provenance.
			trust: $trust,
			# Fields whose CLI value and environment claim disagreed. Neither is trusted, so
			# the disagreement is recorded rather than resolved here.
			diverged_claims: ($diverged | split(" ") | map(select(length > 0))),
			inputs_digest: (if $inputs_digest == "" then null else $inputs_digest end) },
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
		exceptions: {
			# `active` counts only records inside their own window. A record dated in the
			# future is NOT-YET-EFFECTIVE and is reported separately, so a pre-positioned
			# exception cannot suppress anything before the date it was authored.
			active: $ea, expired: $ee, not_yet_effective: $ep,
			# The RECORDS the counts were derived from, and the per-source split so one
			# exception cannot be counted twice through two channels (#242).
			records: $exc_records,
			by_source: ($exc_records | group_by(.source) | map({ key: .[0].source, value: length }) | from_entries)
		},
		evidence: {
			# `present` is a VERIFIED state, not `test -f` (#237). `verification` says how it
			# was decided, so a consumer can tell "no SBOM" from "an SBOM we refused".
			sbom: { present: $sp, path: $sbom_path,
				# CONTENT and PROVENANCE are separate facts. Calling an artifact
				# "verified" when nothing binds it to this run overstated what was
				# checked: the bytes parsed, that is all. `content-verified-unattributed`
				# says exactly that, and the enforcing modes treat it as not-evidence.
				verification: { status: (if ($sp | not) then "rejected"
					elif $sbom_prov == "verified" then "verified"
					else "content-verified-unattributed" end),
					reason: $sbom_reason, provenance: $sbom_prov,
					sha256: (if $sbom_sha == "" then null else $sbom_sha end),
					validator: "build-security-summary/2.2" } },
			release_evidence: { present: $rp, path: $rel_path,
				verification: { status: (if ($rp | not) then "rejected"
					elif $rel_prov == "verified" then "verified"
					else "content-verified-unattributed" end),
					reason: $rel_reason, provenance: $rel_prov,
					sha256: (if $rel_sha == "" then null else $rel_sha end),
					validator: "build-security-summary/2.2" } }
		}
	} + (if $havepol == 1 then { one_of_groups: $oneof } else {} end)
	  + { build: { operation_id: $opid, inputs: $inputs } }' > "$STAGED"

# --- validate the STAGED summary, before it is anyone's evidence -------------
# Every check below runs on the staging file. Previously the only check ran on $OUTPUT —
# after it had already replaced the previous summary — and covered three consistency
# expressions, so a structurally broken summary became the current evidence and stayed
# there.
jq -e . "$STAGED" >/dev/null 2>&1 || die_cfg "assembled summary is not valid JSON ($STAGED)"
_verr=$(jq -r '
	def bad($m): $m;
	[ (if (.version | type) != "string" then bad("version must be a string") else empty end),
	  (if (.gate_contract_version | type) != "string" then bad("gate_contract_version must be a string") else empty end),
	  (if (.generated_at | type) != "string" or (.generated_at | length) == 0 then bad("generated_at must be a non-empty string") else empty end),
	  # `[…] | index(.stage)` indexes the ARRAY with a string: inside the pipe `.` is the
	  # array, not the document. Only reachable when --stage was passed, which is why it
	  # surfaced on staged e2e runs rather than the plain smoke build.
	  (if (.stage != null) and ((.stage | IN("pr","main","scheduled")) | not) then bad("stage must be null or pr|main|scheduled") else empty end),
	  (if (.project | type) != "object" then bad("project must be an object") else empty end),
	  (if (.source | type) != "object" then bad("source must be an object") else empty end),
	  (if (.summary | type) != "object" then bad("summary must be an object") else empty end),
	  (if (.tools | type) != "object" then bad("tools must be an object") else empty end),
	  (if (.exceptions | type) != "object" then bad("exceptions must be an object") else empty end),
	  (if (.evidence | type) != "object" then bad("evidence must be an object") else empty end),
	  (if (.build.operation_id | type) != "string" or (.build.operation_id | length) == 0 then bad("build.operation_id must be a non-empty string") else empty end),
	  (if (.build.inputs | type) != "array" then bad("build.inputs must be an array") else empty end),
	  ( .summary | to_entries[]
	    | select((.value | type) != "number" and (.value | type) != "boolean")
	    | bad("summary.\(.key) must be a number or a boolean, got \(.value | type)") ),
	  ( .tools | to_entries[]
	    | select((.value | type) != "object")
	    | bad("tools.\(.key) must be an object, got \(.value | type)") ),
	  (if .summary.missing_sbom != (.evidence.sbom.present | not) then bad("summary.missing_sbom disagrees with evidence.sbom.present") else empty end),
	  (if .summary.missing_release_evidence != (.evidence.release_evidence.present | not) then bad("summary.missing_release_evidence disagrees with evidence.release_evidence.present") else empty end),
	  # expired_exceptions aggregates the exceptions file AND any collector-reported
	  # expiry, so it must be >= the file count — never equal-by-construction (v2.0.2).
	  # The old `==` assertion is precisely what cemented the overwrite it was meant to
	  # verify: it could only hold if collector-reported expiries were discarded.
	  (if .summary.expired_exceptions < .exceptions.expired then bad("summary.expired_exceptions is below exceptions.expired") else empty end)
	] | join("; ")' "$STAGED" 2>/dev/null || printf 'summary could not be validated')
[ -z "$_verr" ] || die_cfg "assembled summary failed validation and was NOT published: $_verr"

# Destination safety is proven BEFORE the previous summary is replaced.
summary_dest_ok "$OUTPUT" || die_cfg "refusing to publish $OUTPUT"
mv -- "$STAGED" "$OUTPUT" || die_cfg "could not publish the summary to $OUTPUT"

# Belt-and-braces: the PUBLISHED file is the validated one.
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
