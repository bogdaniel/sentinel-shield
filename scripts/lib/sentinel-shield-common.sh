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

# ss_emit_collector <tool> <status> <tool_report_json> <summary_overrides_json>
# Emit a canonical collector object on stdout. The summary always has all ten count
# keys (zeroed), with <summary_overrides_json> merged on top.
ss_emit_collector() {
	# Defensive: validate the two JSON arguments before feeding them to
	# `jq --argjson`, so a malformed/empty report surfaces a structured error
	# (fail closed, exit 2 — matching ss_collector_guard) instead of a raw jq crash.
	if ! printf '%s' "$3" | jq empty 2>/dev/null; then
		log_error "ss_emit_collector: <tool_report_json> for '$1' is not valid JSON"
		return 2
	fi
	if ! printf '%s' "$4" | jq empty 2>/dev/null; then
		log_error "ss_emit_collector: <summary_overrides_json> for '$1' is not valid JSON"
		return 2
	fi
	# Every override key must be a canonical summary key. An unknown key is rejected here,
	# at the shared boundary, rather than trusting every collector author to spell it right.
	# `jq -e` is deliberately not used: an EMPTY unknown-key list is the success case, and
	# `-e` would report empty output as failure.
	if [ "$(printf '%s' "$4" | jq -r 'type' 2>/dev/null)" != "object" ]; then
		log_error "ss_emit_collector: <summary_overrides_json> for '$1' is not a JSON object"
		return 2
	fi
	_ss_unknown=$(printf '%s' "$4" | jq -r --arg canon "$SS_SUMMARY_KEYS" '
		keys - ($canon | split(" ") | map(select(length > 0))) | .[]' 2>/dev/null) || {
		log_error "ss_emit_collector: could not validate <summary_overrides_json> for '$1'"
		return 2
	}
	if [ -n "$_ss_unknown" ]; then
		log_error "ss_emit_collector: '$1' emits summary key(s) outside the canonical set: $(printf '%s' "$_ss_unknown" | tr '\n' ' ')"
		return 2
	fi
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
