#!/bin/sh
# Sentinel Shield — shared POSIX shell library.
#
# Source this file; do not execute it. It defines helper functions only and does
# not enable `set -eu` itself (the caller decides). All functions are POSIX sh
# compatible: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
#
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_COMMON_LOADED=1

# --- logging -----------------------------------------------------------------
# Informational output goes to stderr so stdout can carry machine-readable data.
log_info() { printf '%s\n' "[sentinel-shield] $*" >&2; }
log_warn() { printf '%s\n' "[sentinel-shield][warn] $*" >&2; }
log_error() { printf '%s\n' "[sentinel-shield][error] $*" >&2; }

# die <message...> — log an error and exit non-zero.
die() {
	log_error "$*"
	exit 1
}

# --- environment -------------------------------------------------------------
# command_exists <name> — true if the command is on PATH.
command_exists() { command -v "$1" >/dev/null 2>&1; }

# ensure_dir <path> — create a directory (and parents) if it does not exist.
ensure_dir() {
	[ -n "${1:-}" ] || die "ensure_dir: missing path argument"
	if [ ! -d "$1" ]; then
		mkdir -p "$1" || die "ensure_dir: cannot create '$1'"
	fi
}

# NOTE: `write_file` lived here and was `cat > "$1"` — it truncated the destination before the
# replacement bytes existed, followed a symlink wherever it pointed, never inspected the parent
# and left a partial file behind on interruption, all while writing into consumer repositories.
# It is replaced by `fs_publish` in lib/filesystem-safety.sh (#147), which is where the symlink,
# hard-link, ownership and atomic-replace guards already lived. It cannot live in this file:
# filesystem-safety.sh sources THIS library, so the dependency only runs one way.

# --- values ------------------------------------------------------------------
# bool_value <value> — normalise a boolean; echo true|false; return 1 if invalid.
# Accepts a small, explicit set; anything else is rejected so callers can fail.
bool_value() {
	case "${1:-}" in
		true | True | TRUE | yes | Yes | YES | on | On | ON | 1) printf 'true' ;;
		false | False | FALSE | no | No | NO | off | Off | OFF | 0) printf 'false' ;;
		*) return 1 ;;
	esac
}

# upper <string> — uppercase using tr (portable).
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# json_escape <string> — escape backslash and double-quote for JSON string values.
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# timestamp_utc — ISO-8601 UTC timestamp. `date` is POSIX.
timestamp_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# utc_timestamp — backward-compatible alias for timestamp_utc.
utc_timestamp() { timestamp_utc; }

# --- digests -----------------------------------------------------------------
# ss_sha256_file <path> — print the lowercase 64-hex SHA-256 of a file (no name),
# using sha256sum or shasum (whichever exists). Prints nothing and returns 1 when
# neither tool is available or the file is unreadable.
ss_sha256_file() {
	[ -n "${1:-}" ] && [ -f "$1" ] || return 1
	# Capture the hasher's exit status BEFORE trimming the filename field: a piped
	# `... | cut` would mask a hasher failure as success with empty output.
	if command_exists sha256sum; then
		_ss_h=$(sha256sum "$1" 2>/dev/null) || return 1
	elif command_exists shasum; then
		_ss_h=$(shasum -a 256 "$1" 2>/dev/null) || return 1
	else
		return 1
	fi
	[ -n "$_ss_h" ] || return 1
	printf '%s\n' "${_ss_h%% *}"
}

# ss_sha256_stdin — print the lowercase 64-hex SHA-256 of stdin (no name).
ss_sha256_stdin() {
	if command_exists sha256sum; then
		_ss_h=$(sha256sum 2>/dev/null) || return 1
	elif command_exists shasum; then
		_ss_h=$(shasum -a 256 2>/dev/null) || return 1
	else
		return 1
	fi
	[ -n "$_ss_h" ] || return 1
	printf '%s\n' "${_ss_h%% *}"
}

# ss_have_sha256 — true when a SHA-256 tool is available.
ss_have_sha256() { command_exists sha256sum || command_exists shasum; }

# --- collector helpers (jq-dependent; used by scripts/collectors/*.sh) -------
# These are only used by the scanner-normalization collectors, which require jq.
# The resolver path does not call them, so jq remains optional for resolve-gates.

# ss_require_jq — exit 2 if jq is not available.
ss_require_jq() {
	command_exists jq || {
		log_error "jq is required for JSON parsing but was not found. Install jq."
		exit 2
	}
}

# SS_SUMMARY_KEYS — the canonical summary-key set, verbatim from
# schemas/security-summary.schema.json (`properties.summary.properties`, which declares
# "additionalProperties": false). It is duplicated here rather than read from the schema at
# runtime so a collector never depends on the schema file being present in an installed
# layout; tests/prod/273 asserts the two sets are EXACTLY equal, so drift cannot survive CI.
#
# Why this is a hard boundary and not a lint: ss_emit_collector merges arbitrary overrides
# into the summary, so a misspelled key is not a no-op — it invents a summary field that no
# gate reads, while the real gating key silently keeps its zeroed default. The gate then
# resolves clean on evidence that was meant to be an error. #327 shipped exactly that
# (`diff_coverage_violations` for `changed_lines_coverage_violations`) and nothing caught it.
SS_SUMMARY_KEYS="acceptance_test_count acceptance_test_failures ai_review_findings \
architecture_context_count architecture_rule_count architecture_tool_count \
architecture_violations behavior_spec_count changed_lines_coverage_percent \
changed_lines_coverage_violations complexity_average complexity_max complexity_violations \
container_image_violations coverage_branch_percent coverage_class_percent \
coverage_line_percent coverage_method_percent coverage_regression \
coverage_threshold_violations critical_vulnerabilities dast_findings dead_code_count \
dead_code_violations debug_code_violations dependency_policy_violations duplication_percent \
duplication_violations empty_test_suite expired_exceptions focused_test_violations \
high_vulnerabilities iac_violations large_file_violations large_function_violations \
max_file_lines max_function_lines medium_vulnerabilities missing_acceptance_evidence \
missing_architecture_evidence missing_behavior_specification missing_coverage_evidence \
missing_release_evidence missing_sbom missing_test_change_evidence missing_test_evidence \
mutation_score_percent mutation_score_violations orphan_behavior_specifications \
php_syntax_errors production_change_without_test_change repository_health_warnings \
required_tool_failures secrets skipped_test_marker_violations skipped_tests style_violations \
test_count test_failures third_party_install_script_risk third_party_network_behavior \
third_party_obfuscation third_party_suspicious_code tool_configuration_failures \
tool_execution_failures type_errors unsafe_docker unsafe_github_actions"

# --- the collector output contract (#145) ------------------------------------------------
#
# ss_emit_collector is the ONE place a collector's evidence becomes a document, so it is the
# only place the whole shape can be judged at once. Everything a consumer later trusts about
# that document — the outer status vocabulary, its agreement with the tool report's own status,
# the summary vocabulary, and the type and range of every summary value — is decided here, for
# built-in and custom collectors alike.
#
# Validating downstream instead is too late. build-security-summary.sh SUMS these counts across
# collectors before any schema runs, and several tools read a collector's stdout directly. Until
# #145 the emitter checked only that both JSON arguments PARSED: `pass` beside `{"status":"fail"}`
# beside `{"secrets":-1}` was emitted without complaint, and `-1` then cancelled another
# scanner's real finding in the aggregate.
#
# Like SS_SUMMARY_KEYS, these lists are duplicated from schemas/security-summary.schema.json
# rather than read from it at runtime, so a collector never depends on the schema file being
# present in an installed layout. tests/prod/312 asserts each list is EXACTLY the schema's (and
# the gating set exactly enforce-gates.sh's count gates), so drift is a CI failure, not a
# surprise.

# SS_COLLECTOR_STATUSES — the outer status vocabulary, verbatim from the schema's
# properties.tools.additionalProperties.properties.status enum. An outer status outside this set
# reaches the summary's `tools` map and makes the whole document schema-invalid, so it is refused
# where it is produced rather than where it is finally parsed.
SS_COLLECTOR_STATUSES="pass fail warn skipped unavailable findings not-configured \
not-applicable execution-error disabled"

# THE SUMMARY IS NOT ALL INTEGERS, AND PRETENDING IT IS WOULD REJECT VALID EVIDENCE.
#
# The default class is #146's bounded non-negative integer. These three lists are the entire
# exception, each taken from the schema's declared type for that field:
#   BOOL   — nine boolean evidence flags; a number here is not a "0 findings" claim, it is a
#            malformed flag, so the type is enforced rather than coerced.
#   RATIO  — seven percentages, `number` with maximum 100. Fractional values are legitimate
#            (87.5% line coverage), so integrality is NOT required; the 0..100 range is.
#   METRIC — two complexity metrics, `number` bounded at SS_MAX_COUNT. Fractional values are
#            legitimate (an average of 12.75), so integrality is NOT required; the ceiling is.
#            SS_MAX_COUNT is not a new constant chosen for them: build-security-summary.sh
#            already refuses ANY summary number above it at the aggregation boundary, and their
#            sibling worst-observed metrics (max_file_lines, max_function_lines) already carry
#            it. The schema was the half that was out of step, and #145 closed that; a complexity
#            threshold (quality-policy max_cyclomatic_complexity) is a POLICY value an observed
#            maximum is meant to exceed, so it is not a representational ceiling and is not used
#            as one.
SS_SUMMARY_BOOL_KEYS="empty_test_suite missing_acceptance_evidence \
missing_architecture_evidence missing_behavior_specification missing_coverage_evidence \
missing_release_evidence missing_sbom missing_test_change_evidence missing_test_evidence"
SS_SUMMARY_RATIO_KEYS="changed_lines_coverage_percent coverage_branch_percent \
coverage_class_percent coverage_line_percent coverage_method_percent duplication_percent \
mutation_score_percent"
SS_SUMMARY_METRIC_KEYS="complexity_average complexity_max"

# SS_GATING_SUMMARY_KEYS — the summary keys whose positive value IS a finding the collector
# itself declared: every count gate enforce-gates.sh evaluates (INT_SUMMARY_KEYS,
# THIRD_PARTY_KEYS, ENTERPRISE_COUNT_KEYS, QUALITY_COUNT_KEYS, TESTING_DISCIPLINE_COUNT_KEYS),
# minus the census carve-out below.
#
# A collector emitting `pass` while carrying one of these above zero is emitting evidence that
# contradicts itself, and the contradiction is not harmless: the per-tool status says the tool is
# clean while the counts it shipped are summed into the aggregate the gates read. Only `pass` is
# constrained — `warn`, `findings` and `fail` are already claims that something was found, and
# the non-run statuses carry the zeroed defaults their emit paths supply.
SS_GATING_SUMMARY_KEYS="secrets critical_vulnerabilities high_vulnerabilities \
medium_vulnerabilities architecture_violations type_errors test_failures unsafe_docker \
unsafe_github_actions expired_exceptions third_party_suspicious_code \
third_party_install_script_risk third_party_obfuscation third_party_network_behavior \
php_syntax_errors style_violations dependency_policy_violations iac_violations \
container_image_violations dast_findings repository_health_warnings ai_review_findings \
coverage_threshold_violations coverage_regression mutation_score_violations \
complexity_violations duplication_violations dead_code_violations \
changed_lines_coverage_violations focused_test_violations skipped_test_marker_violations \
debug_code_violations large_file_violations large_function_violations \
production_change_without_test_change orphan_behavior_specifications acceptance_test_failures"

# SS_NONGATING_COUNT_KEYS — count gates that are a CENSUS, not a verdict. `skipped_tests` is the
# number of tests a runner skipped; the suite that ran still PASSED, and whether skipping is
# tolerable is a policy decision enforce-gates.sh makes per mode, not a finding the collector
# declared. Constraining `pass` on it would refuse scripts/collectors/tests.sh's ordinary,
# correct output. This carve-out is per-KEY and declared here, never per-tool: a channel is
# non-gating for every collector or for none.
SS_NONGATING_COUNT_KEYS="skipped_tests"

# ss_in_set <value> <space-separated-set> — exact membership, no substring or prefix matches.
# The set word is quoted, so glob metacharacters in <value> are literal.
ss_in_set() {
	case " $2 " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# ss_redact <value> — a diagnostic-safe rendering of untrusted text: control characters dropped,
# 60 characters kept. A refusal has to say WHAT it refused to be actionable, and a collector's
# status or count value is attacker-influenced input being written to a log.
ss_redact() {
	printf '%s' "$1" | tr -d '[:cntrl:]' | cut -c1-60
}

# ss_collector_contract_or_fail <tool> <status> <tool_report_json> <summary_overrides_json>
# THE canonical collector-output validator. Returns 0 when the four arguments describe a
# self-consistent collector object, or 2 having logged exactly which invariant failed.
#
# It never rounds, clamps, floors or coerces, and it never accepts a partial override: one
# invalid sibling refuses the whole object, because a caller cannot tell which of its fields
# survived and would otherwise publish a summary built half from its own evidence and half from
# zeroed defaults.
#
# Two jq calls, one per JSON argument. Both do their own parse check — a parse failure is jq's
# non-zero exit, not a separate `jq empty` pass — so this validates strictly more than the code
# it replaces while running fewer processes.
ss_collector_contract_or_fail() {
	_ccf_tool=$1; _ccf_status=$2; _ccf_report=$3; _ccf_ov=$4

	# (1) OUTER STATUS VOCABULARY. Checked first and in pure shell: it costs nothing and an
	# invented status is the one defect that makes the finished document schema-invalid.
	if ! ss_in_set "$_ccf_status" "$SS_COLLECTOR_STATUSES"; then
		log_error "ss_emit_collector: '$_ccf_tool' emits status '$(ss_redact "$_ccf_status")', outside the collector vocabulary ($SS_COLLECTOR_STATUSES)"
		return 2
	fi

	# (2) THE TOOL REPORT PARSES, AND ITS STATUS AGREES WITH THE OUTER ONE.
	#
	# The documented mapping is IDENTITY: when the tool report states a status, it is the same
	# string as the outer status. The tool report carries the finer-grained detail — `health`,
	# `reason` — precisely so the status field does not have to disagree to say more. A report
	# with NO status makes no claim and is left alone; a non-string status is malformed.
	#
	# The comparison happens INSIDE jq against the outer status passed in as --arg, so an
	# attacker-shaped status string never comes back to be re-parsed by the shell. Anything this
	# does not recognise (including a status carrying a newline, which would split the result
	# into lines no branch matches) lands on the catch-all and is refused.
	_ccf_rs=$(printf '%s' "$_ccf_report" | jq -r --arg s "$_ccf_status" '
		if type != "object" then "none"
		elif (.status | type) == "null" then "none"
		elif (.status | type) != "string" then "nonstring:" + (.status | type)
		elif .status == $s then "agree"
		else "differs:" + .status
		end' 2>/dev/null) || {
		log_error "ss_emit_collector: <tool_report_json> for '$_ccf_tool' is not valid JSON"
		return 2
	}
	case "$_ccf_rs" in
		agree | none) : ;;
		differs:*)
			log_error "ss_emit_collector: '$_ccf_tool' emits outer status '$_ccf_status' while its tool_report claims '$(ss_redact "${_ccf_rs#differs:}")'. Contradictory evidence is never published; put the finer detail in tool_report.health or .reason."
			return 2 ;;
		*)
			log_error "ss_emit_collector: '$_ccf_tool' tool_report.status is not a string ($(ss_redact "$_ccf_rs"))"
			return 2 ;;
	esac

	# (3) THE SUMMARY OVERRIDES. One jq pass reports every structural problem it can see and
	# hands the integer-class candidates back as STRINGS for #146's validator to judge.
	#
	# Integer range is deliberately NOT decided here. ss_count_valid is the shared authority and
	# is string-only until a candidate is proven small, so an out-of-range value cannot break the
	# check that exists to reject it. Duplicating a numeric policy in jq is exactly the second
	# maximum #146 exists to prevent.
	_ccf_lines=$(printf '%s' "$_ccf_ov" | jq -r \
		--argjson max "$SS_MAX_COUNT" \
		--arg canon "$SS_SUMMARY_KEYS" \
		--arg bools "$SS_SUMMARY_BOOL_KEYS" \
		--arg ratios "$SS_SUMMARY_RATIO_KEYS" \
		--arg metrics "$SS_SUMMARY_METRIC_KEYS" '
		def s($x): $x | split(" ") | map(select(length > 0));
		if type != "object" then "ERR\tnot-a-json-object"
		else
			s($canon) as $C | s($bools) as $B | s($ratios) as $R | s($metrics) as $M
			| to_entries[] | .key as $k | .value as $v | ($v | type) as $t
			| if ($C | index($k)) == null then "UNK\t\($k)"
			  elif ($B | index($k)) then
				(if $t == "boolean" then empty else "BAD\t\($k)\tnot-a-boolean-but-\($t)" end)
			  elif $t != "number" then "BAD\t\($k)\tnot-a-number-but-\($t)"
			  elif ($R | index($k)) then
				(if ($v >= 0 and $v <= 100) then empty else "BAD\t\($k)\toutside-0-to-100" end)
			  elif ($M | index($k)) then
				(if ($v >= 0 and $v <= $max) then empty else "BAD\t\($k)\toutside-0-to-\($max)" end)
			  else "INT\t\($k)\t\($v | tostring)"
			  end
		end' 2>/dev/null) || {
		log_error "ss_emit_collector: <summary_overrides_json> for '$_ccf_tool' is not valid JSON"
		return 2
	}

	_ccf_bad=""; _ccf_unknown=""; _ccf_contra=""
	_ccf_oldifs=$IFS
	IFS='	'
	# A `while read` fed by a here-document runs in the CURRENT shell in sh, dash and bash, so
	# the accumulators below survive the loop. A pipeline would put them in a subshell, and every
	# refusal would be silently discarded — a validator that forgets what it found has not
	# validated anything.
	while read -r _ccf_kind _ccf_key _ccf_val; do
		case "$_ccf_kind" in
			'') continue ;;
			ERR)
				IFS=$_ccf_oldifs
				log_error "ss_emit_collector: <summary_overrides_json> for '$_ccf_tool' is not a JSON object"
				return 2 ;;
			UNK) _ccf_unknown="$_ccf_unknown $_ccf_key" ;;
			BAD) _ccf_bad="$_ccf_bad $_ccf_key($_ccf_val)" ;;
			INT)
				if ss_count_valid "$_ccf_val"; then
					# ss_count_valid has proven this is at most ten digits, so `-gt` is safe.
					if [ "$_ccf_status" = "pass" ] && [ "$_ccf_val" -gt 0 ] \
						&& ss_in_set "$_ccf_key" "$SS_GATING_SUMMARY_KEYS"; then
						_ccf_contra="$_ccf_contra $_ccf_key=$_ccf_val"
					fi
				else
					_ccf_bad="$_ccf_bad $_ccf_key=$(ss_redact "$_ccf_val")"
				fi ;;
			*) _ccf_bad="$_ccf_bad unreadable-validator-output" ;;
		esac
	done <<EOF
$_ccf_lines
EOF
	IFS=$_ccf_oldifs

	if [ -n "$_ccf_unknown" ]; then
		log_error "ss_emit_collector: '$_ccf_tool' emits summary key(s) outside the canonical set:$_ccf_unknown"
		return 2
	fi
	if [ -n "$_ccf_bad" ]; then
		log_error "ss_emit_collector: '$_ccf_tool' emits summary value(s) outside the bounded contract (non-negative, integral unless the schema declares otherwise, at or below $SS_MAX_COUNT):$_ccf_bad"
		return 2
	fi
	if [ -n "$_ccf_contra" ]; then
		log_error "ss_emit_collector: '$_ccf_tool' reports status 'pass' while declaring gating finding(s):$_ccf_contra. A clean status and a positive gating count cannot both be true."
		return 2
	fi
	return 0
}

# ss_emit_collector <tool> <status> <tool_report_json> <summary_overrides_json>
# Emit a canonical collector object on stdout. The summary always carries the eighteen
# always-present count keys (zeroed), with <summary_overrides_json> merged on top.
ss_emit_collector() {
	# THE WHOLE CONTRACT, OR NOTHING IS PUBLISHED.
	#
	# Validation runs to completion BEFORE the first byte of the object is produced, so a refusal
	# leaves no partial document behind for a consumer to read: the `jq -n` below is the only
	# writer and it is never reached on a refusal path.
	#
	# `exit 2` rather than `return 2`. A refusal that merely RETURNED was swallowed by this
	# library's own callers: ss_shape_or_fail, ss_counts_or_fail, td_bad_count and
	# arch_passthrough_status all emit and then `exit 0` unconditionally, so a refused emit
	# became a collector that exited 0 having printed nothing — and build-security-summary.sh
	# dropped it from the aggregate without a word. Exiting here fails the collector closed at
	# every one of those sites at once. Callers that need the status (the tests, and any future
	# in-process consumer) already run this inside a command substitution, where `exit` ends the
	# subshell and surfaces as exit status 2 exactly as before.
	ss_collector_contract_or_fail "$1" "$2" "$3" "$4" || exit 2
	jq -n \
		--arg tool "$1" \
		--arg status "$2" \
		--argjson report "$3" \
		--argjson ov "$4" '
		{
			tool: $tool,
			status: $status,
			summary: ({
				secrets: 0,
				critical_vulnerabilities: 0,
				high_vulnerabilities: 0,
				medium_vulnerabilities: 0,
				architecture_violations: 0,
				type_errors: 0,
				test_failures: 0,
				unsafe_docker: 0,
				unsafe_github_actions: 0,
				expired_exceptions: 0,
				style_violations: 0,
				php_syntax_errors: 0,
				dependency_policy_violations: 0,
				iac_violations: 0,
				dast_findings: 0,
				container_image_violations: 0,
				repository_health_warnings: 0,
				ai_review_findings: 0
			} + $ov),
			tool_report: $report
		}'
}

# ss_provenance_object <sidecar-path> <fallback-version> <fallback-db-timestamp>
# Echo a normalized provenance object for a scanner collector's tool_report. Prefers
# fields from the sidecar written by isolated_tool_provenance_record (scripts/lib/
# isolated-tools.sh) when it is present and valid JSON; otherwise falls back to values
# parsed from the scanner's own native report (e.g. Grype's .descriptor). A populated
# scanner_version / vulnerability_db.timestamp is what distinguishes an EMPTY report
# (scanner ran, found nothing) from a scanner that DID NOT RUN (no provenance at all).
# Requires jq. Fields that resolve to nothing become "unknown" (version) or null.
ss_provenance_object() {
	_pv_side='{}'
	# Require an actual JSON object: `jq -e .` also accepts arrays/scalars, which
	# would then fail when indexed as $side.version / $side.vulnerability_db.
	if [ -n "${1:-}" ] && [ -f "$1" ] && [ -s "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
		_pv_side=$(cat "$1")
	fi
	jq -n --argjson side "$_pv_side" --arg fv "${2:-}" --arg fdb "${3:-}" '
		def nn(s): if s == "" or s == null then null else s end;
		(($side.version // "") | if type == "string" then . else "" end) as $sv
		| (($side.vulnerability_db.timestamp // "") | if type == "string" then . else "" end) as $sdb
		| {
			scanner_version: (
				if $sv != "" and $sv != "unknown" then $sv
				elif $fv != "" then $fv
				elif $sv != "" then $sv
				else "unknown" end ),
			vulnerability_db: { timestamp: ( if $sdb != "" then $sdb elif $fdb != "" then $fdb else null end ) },
			source: nn($side.source),
			image: ($side.image // null),
			captured_at: nn($side.recorded_at)
		}'
	unset _pv_side
}

# ss_collector_guard <tool> <input-path>
# Preflight for a collector: requires jq; emits an "unavailable" object and exits 0
# when the input is missing/empty; exits 2 on invalid JSON. Returns 0 when the input
# is present and parseable so the collector can proceed.
ss_collector_guard() {
	ss_require_jq
	if [ ! -f "$2" ] || [ ! -s "$2" ]; then
		log_warn "$1: input '$2' missing or empty; status=unavailable"
		ss_emit_collector "$1" "unavailable" '{"status":"unavailable"}' '{}'
		exit 0
	fi
	if ! jq -e . "$2" >/dev/null 2>&1; then
		log_error "$1: invalid JSON in '$2'"
		exit 2
	fi
}

# ss_shape_or_fail <tool> <input> <jq-recognizer> [summary-overrides-json]
# Fail closed when a scanner report is valid JSON but its SHAPE is not recognized.
#
# v2.0.2 security hotfix. The security collectors used to end their extraction with
# `else 0 end`, or relied on jq's `?` operator, so a document whose top-level keys had
# been renamed upstream produced ZERO findings and status=pass. A scanner version bump
# could therefore convert every real finding into a clean gate silently. Unrecognized
# output is untrusted evidence, not an absence of findings.
#
# <jq-recognizer> must evaluate truthy for a shape this collector genuinely understands.
# Emits execution-error and exits 0 (the collector ran; its INPUT is the problem) so the
# builder's per-tool policy records it and the evidence gates see a non-clean status.
ss_shape_or_fail() {
	_sot=$1; _soi=$2; _sor=$3; _sov=${4:-}; [ -n "$_sov" ] || _sov='{}'
	_soo=$(jq -r "if ($_sor) then \"ok\" else \"unknown\" end" "$_soi" 2>/dev/null || printf 'unknown')
	[ "$_soo" = "ok" ] && return 0
	log_warn "$_sot: unrecognized report shape in '$_soi'; status=execution-error (never reported as clean)"
	ss_emit_collector "$_sot" "execution-error" \
		"$(jq -n --arg t "$_sot" '{status:"execution-error", reason:("unrecognized " + $t + " report shape")}')" \
		"$_sov"
	exit 0
}

# --- the bounded-count contract (#146) ---------------------------------------------------
# SS_MAX_COUNT — the canonical maximum for an individual count AND for an aggregate.
#
# 2^31-1, chosen from measurement rather than taste:
#
#   - exact as a jq literal AND through jq ARITHMETIC. That distinction is the whole issue:
#     jq >= 1.7 round-trips an untouched literal unchanged, so a value surviving a round trip
#     proves nothing. The summary aggregation ADDS, which converts to double.
#   - exact through JSON.parse / JS Number, where 9007199254740993 silently becomes
#     9007199254740992.
#   - inside the range of `[ -gt ]` and `$(( ))` in sh, dash and bash. At 2^63 `[ -gt ]` is a
#     HARD ERROR with three different messages across those shells, and `$(( ))` wraps to a
#     NEGATIVE value, diverging between dash and sh/bash beyond it.
#   - exact for a 32-bit signed consumer, which 2^53-1 is not.
#   - operationally absurd to reach: 2.1e9 findings of ONE kind in ONE run.
#
# 2^53-1 is the cross-runtime CEILING, not a policy maximum. Two individually valid operands
# can sum past double exactness — 9007199254740991 + 2 aggregated to ...992 on the production
# path, losing the true sum. With this bound and checked addition holding every partial sum at
# or below it, aggregates are exact everywhere too, so ONE constant serves both classes and
# there is no second maximum to drift.
#
# An aggregate is itself a count and reaches the same consumers, so it gets the same ceiling:
# a higher aggregate limit would let a value pass aggregation and then be un-representable
# downstream. Kept in lockstep with schemas/security-summary.schema.json and
# docs/security-summary-schema.md by tests/prod/311-count-bounds.sh.
SS_MAX_COUNT=2147483647

# ss_count_valid <value> — true when <value> is a non-negative integer at or below SS_MAX_COUNT.
#
# DELIBERATELY STRING-ONLY UNTIL THE VALUE IS PROVEN SMALL. A validator that reached for
# `[ "$v" -le … ]` or `$(( v ))` on the candidate would be broken by exactly the inputs it
# exists to reject: those constructs error or wrap on an out-of-range value, and a validator
# that crashes has not failed closed. So the digits are checked lexically, then the LENGTH, and
# only a same-length candidate — at most ten digits, far inside every shell's range — is
# compared numerically.
ss_count_valid() {
	_cv=${1:-}
	# Rejects '', whitespace, '-1', '1.5', '1e3', '0x10', '+1' and every non-digit form.
	case "$_cv" in
		'' | *[!0-9]*) return 1 ;;
	esac
	# A leading zero is not a canonical count; '007' and '0000000000000' are shapes a
	# length comparison would otherwise have to reason about.
	case "$_cv" in
		0) return 0 ;;
		0*) return 1 ;;
	esac
	if [ "${#_cv}" -lt "${#SS_MAX_COUNT}" ]; then return 0; fi
	if [ "${#_cv}" -gt "${#SS_MAX_COUNT}" ]; then return 1; fi
	[ "$_cv" -le "$SS_MAX_COUNT" ]
}

# ss_count_add <a> <b> — echo a+b, or fail (1) printing nothing.
#
# Both operands are validated INDEPENDENTLY, and the overflow test is a PRECONDITION —
# `a <= MAX - b` — evaluated before the addition ever happens. Adding first and inspecting the
# result afterwards is not equivalent: at 2^63 the sum wraps NEGATIVE, and a negative sum
# passes a naive `<= MAX` test, so check-after-addition accepts precisely the overflow it was
# meant to catch. `MAX - b` is itself safe because b has already been proven at or below MAX.
ss_count_add() {
	ss_count_valid "${1:-}" || return 1
	ss_count_valid "${2:-}" || return 1
	[ "$1" -le "$((SS_MAX_COUNT - $2))" ] || return 1
	printf '%s' "$(($1 + $2))"
}

# ss_counts_or_fail <tool> <counts-json> [summary-overrides-json]
# Validate that every value in a collector's count object is a NON-NEGATIVE INTEGER.
#
# v2.0.2 security hotfix. Counts were passed through unvalidated and the builder SUMS
# them across collectors, so one report carrying `critical: -99` cancelled another
# scanner's real findings — exact cancellation to 0 produced a full PASS. Floats and
# strings were equally unchecked. A malformed count is untrusted evidence.
ss_counts_or_fail() {
	_cot=$1; _coc=$2; _cov=${3:-}; [ -n "$_cov" ] || _cov='{}'
	# Keys prefixed with "_" are the collectors' existing internal-metadata convention
	# (grype/osv carry _native/_results alongside the counts); they are not gate counts.
	_cobad=$(printf '%s' "$_coc" | jq -r --argjson max "$SS_MAX_COUNT" '
		[ to_entries[]
		  | select(.key | startswith("_") | not)
		  | select((.value | type) != "number"
			or (.value < 0)
			or ((.value | floor) != .value)
			or (.value > $max))
		  | "\(.key)=\(.value)" ] | join(", ")' 2>/dev/null || printf 'unreadable')
	[ -z "$_cobad" ] && return 0
	log_warn "$_cot: invalid count(s) [$_cobad]; status=execution-error (never coerced to a clean 0)"
	ss_emit_collector "$_cot" "execution-error" \
		"$(jq -n --arg r "$_cobad" '{status:"execution-error", reason:("invalid counts: " + $r)}')" \
		"$_cov"
	exit 0
}

# --- the gates artifact: ONE parser for every consumer ------------------------------------
# The resolver writes `sentinel-shield-gates.env`; the enforcer, the summary selector and the
# report generator all read it. They each used to parse it their own way — `head -n1`, `sed`,
# `awk ... exit` — so the SAME policy file could resolve differently depending on which tool
# read it: a duplicated key was first-wins in two consumers while the enforcer rejected it.
# That is the ambiguity the input contract exists to remove, so the parser lives here and
# every consumer uses it.
#
# ss_gates_env_read <file> — echo the validated content, or fail (2) having said why.
# Validates: regular non-symlink file; every non-comment line is a safe
# SENTINEL_SHIELD_<KEY>=<safe-value> assignment; no duplicate keys; no unknown keys.
ss_gates_env_read() {
	_ge_f="${1:-}"
	[ -n "$_ge_f" ] || { log_error "gates env: no file given"; return 2; }
	if [ -L "$_ge_f" ]; then
		log_error "gates env '$_ge_f' is a symlink; policy is never read through a link"
		return 2
	fi
	[ -f "$_ge_f" ] || { log_error "gates env '$_ge_f' is not a regular file"; return 2; }
	_ge_out=""
	_ge_n=0
	while IFS= read -r _ge_line || [ -n "$_ge_line" ]; do
		_ge_n=$((_ge_n + 1))
		case "$_ge_line" in
			'' | '#'*) continue ;;
		esac
		if printf '%s' "$_ge_line" | grep -Eq '^SENTINEL_SHIELD_[A-Z0-9_]+=[A-Za-z0-9._-]*$'; then
			_ge_out="${_ge_out}${_ge_line}
"
		else
			log_error "suspicious or invalid line in gates env ($_ge_f:$_ge_n): '$_ge_line'"
			return 2
		fi
	done < "$_ge_f"
	_ge_dupes=$(printf '%s\n' "$_ge_out" | sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' | sort | uniq -d)
	if [ -n "$_ge_dupes" ]; then
		log_error "gates env declares duplicate key(s): $(printf '%s' "$_ge_dupes" | tr '\n' ' ') — a duplicated policy value is ambiguous, not a value to pick from ($_ge_f)"
		return 2
	fi
	_ge_unknown=$(printf '%s\n' "$_ge_out" | sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' |
		grep -Ev '^SENTINEL_SHIELD_(MODE|PROJECT_[A-Z0-9_]+|FAIL_ON_[A-Z0-9_]+)$' || true)
	if [ -n "$_ge_unknown" ]; then
		log_error "gates env declares unknown key(s): $(printf '%s' "$_ge_unknown" | tr '\n' ' ') — regenerate it with scripts/resolve-gates.sh ($_ge_f)"
		return 2
	fi
	printf '%s' "$_ge_out"
}

# ss_gates_env_value <validated-content> <KEY> — the value, or empty. Uniqueness is proven by
# ss_gates_env_read, so "first match" cannot differ from "the value".
ss_gates_env_value() {
	printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'
}
