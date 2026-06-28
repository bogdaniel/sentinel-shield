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
TOOL_TABLE='gitleaks|gitleaks.json|gitleaks.sh|gitleaks
semgrep|semgrep.json|semgrep.sh|semgrep
trivy|trivy.json|trivy.sh|trivy
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
nuclei|nuclei.json|nuclei.sh|nuclei
ai-security-review|ai-security-review.json|ai-security-review.sh|ai_security_review
kuzushi|kuzushi.json|kuzushi.sh|kuzushi
dependency-policy|dependency-policy.json|dependency-policy.sh|dependency_policy
architecture-tests|architecture-tests.json|architecture-tests.sh|architecture_tests'

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

COUNTS=$(printf '%s' "$ARR" | jq '
	reduce .[] as $c (
		{secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
		 medium_vulnerabilities:0, architecture_violations:0, type_errors:0,
		 test_failures:0, unsafe_docker:0, unsafe_github_actions:0, expired_exceptions:0,
		 third_party_suspicious_code:0, third_party_install_script_risk:0,
		 third_party_obfuscation:0, third_party_network_behavior:0,
		 style_violations:0, php_syntax_errors:0, dependency_policy_violations:0,
		 iac_violations:0, dast_findings:0, container_image_violations:0,
		 repository_health_warnings:0, ai_review_findings:0};
		reduce ($c.summary | keys_unsorted[]) as $k (.; .[$k] = ((.[$k] // 0) + ($c.summary[$k] // 0)))
	)')

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

	# Pipe-delimited rows (empty fields preserved): key|policy|applicability|report|exes|cfgpath|cfgclass
	_rows=$(printf '%s' "$EFF" | jq -r '
		.tools | to_entries[]
		| [ .key, .value.policy, (.value.applicability // "unknown"),
			(.value.report // ""),
			((.value.executable // []) | join(" ")),
			(.value.config.path // ""), (.value.config.classification // "") ]
		| join("|")')

	POLICY_COLLECTED=""
	# Read in the CURRENT shell (here-doc, NOT a pipe) so counters/accumulators persist.
	while IFS='|' read -r tkey tpol tappl trep texe tcfgp tcfgc; do
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

		# Reuse the collector's status when this tool has one (TOOL_TABLE), so the
		# findings/pass split matches the mapped summary counters.
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
			executed=true; installed=true
			case "$cstatus" in
				fail | findings) status="findings" ;;
				*) status="pass" ;;
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
			if [ -f "$_grf" ] && [ -s "$_grf" ] && jq -e . "$_grf" >/dev/null 2>&1; then
				_gstatus="satisfied"
			fi
		fi
		[ "$_gstatus" = "unsatisfied" ] && _unsat=$((_unsat + 1))
		ONEOF_ECHO=$(printf '%s' "$ONEOF_ECHO" | jq --arg g "$_g" --arg st "$_gstatus" --arg sel "$_gsel" \
			'. + {($g): {status: $st, selected: (if $sel=="" then null else $sel end)}}')
	done
	REQ_FAIL=$((REQ_FAIL + _unsat))

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
	--argjson reqf "$REQ_FAIL" --argjson cfgf "$CFG_FAIL" --argjson exef "$EXE_FAIL" '
	{
		version: $version,
		project: { name: $pname, type: $ptype, criticality: $crit },
		generated_at: $gen,
		source: { commit: $commit, branch: $branch, workflow: $workflow },
		summary: ($counts + { missing_sbom: $ms, missing_release_evidence: $mr, expired_exceptions: $ee }
			+ (if $havepol == 1 then { required_tool_failures: $reqf, tool_configuration_failures: $cfgf, tool_execution_failures: $exef } else {} end)),
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
	and (.summary.expired_exceptions == .exceptions.expired)
' "$OUTPUT" >/dev/null || die_cfg "internal consistency check failed for $OUTPUT"

log_info "wrote $OUTPUT (mode-agnostic findings; enforce with scripts/enforce-gates.sh)"
log_info "summary: $(printf '%s' "$COUNTS" | jq -c '.')  missing_sbom=$MS missing_release_evidence=$MR"
