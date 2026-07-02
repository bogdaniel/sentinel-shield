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

# write_file <path> — write stdin to <path>, creating parent directories.
# Usage:  printf '%s\n' "content" | write_file out.txt
write_file() {
	[ -n "${1:-}" ] || die "write_file: missing path argument"
	ensure_dir "$(dirname -- "$1")"
	cat > "$1" || die "write_file: cannot write '$1'"
}

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
	if [ -n "${1:-}" ] && [ -f "$1" ] && [ -s "$1" ] && jq -e . "$1" >/dev/null 2>&1; then
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
