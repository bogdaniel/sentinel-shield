#!/bin/sh
# Sentinel Shield — production health / operational-readiness command.
#
# READ-ONLY operational health probe for an adopted target. It inspects the on-disk state of a
# Sentinel Shield adoption and reports a single rolled-up health verdict — healthy | degraded |
# unhealthy | unknown — plus a per-check breakdown with STABLE reason codes, as a machine-readable
# health-report (schemas/health-report.schema.json) on STDOUT and a human summary on STDERR.
#
# It NEVER mutates the target, NEVER runs scanners, and — unless EXPLICITLY asked with
# --check-network — NEVER touches the network: every other check is fully OFFLINE. It reuses the
# production primitives from earlier tasks: bounded-process (Task 1) for the only network probe,
# the transaction journal verifier (Task 2) for journal integrity, and the redaction library
# (Task 4) so the report carries no secret and no repo-local absolute path (the target identity is
# a non-reversible hash).
#
# CHECKS (each yields one of healthy|degraded|unhealthy|unknown|skipped + a stable reason code):
#   metadata_consistency   installation.json present + structurally valid
#   operation_state        stale / incomplete / torn operation lock detection
#   journal_integrity      append-only transaction journal chain intact
#   tool_availability      required tools present on PATH
#   scanner_health         scanner vulnerability-db freshness
#   report_freshness       most recent local report not stale
#   ref_immutability       recorded source ref is immutable (not a moving branch)
#   source_verification    pinned vs resolved source commit agree
#   managed_file_drift     managed files present + match their recorded digests
#   package_manager_state  package-manager resolution is supported/unambiguous
#   disk_space             free space at/above the configured minimum
#   write_permissions      the adoption directory is writable
#   time_sync              recorded timestamps are not in the future (clock-skew warning)
#   github_connectivity    required GitHub reachability — ONLY when --check-network is given
#
# EXIT CODES (map to the rolled-up verdict; precedence unhealthy > degraded > unknown > healthy):
#   0  healthy    every check healthy or not-applicable
#   1  degraded   at least one degraded condition; adoption usable but should be reviewed
#   2  unhealthy  at least one unhealthy condition; adoption needs intervention
#   3  unknown    at least one check could not be determined (and nothing worse)
#   64 usage      invalid invocation (distinct from any health verdict)
#
# Usage: sh scripts/health.sh [--target <dir>] [--check-network] [--format json|text]
#                             [--report <path>] [--quiet]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/redaction.sh
. "$SCRIPT_DIR/lib/redaction.sh"
# shellcheck source=scripts/lib/bounded-process.sh
. "$SCRIPT_DIR/lib/bounded-process.sh"
# shellcheck source=scripts/lib/transaction.sh
. "$SCRIPT_DIR/lib/transaction.sh"
# shellcheck source=scripts/lib/source-verification.sh
. "$SCRIPT_DIR/lib/source-verification.sh"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$SCRIPT_DIR/lib/installation-metadata.sh"
# Operational-events is opt-in; source defensively so a minimal copied tree still works.
if [ -f "$SCRIPT_DIR/lib/operational-events.sh" ]; then
	# shellcheck source=scripts/lib/operational-events.sh
	. "$SCRIPT_DIR/lib/operational-events.sh"
fi

EX_USAGE=64

# --- tunables (env-overridable) ---------------------------------------------------------------
: "${SENTINEL_SHIELD_HEALTH_DISK_MIN_KB:=51200}"          # minimum free KB (default 50 MiB).
: "${SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS:=14}"    # scanner db older than this => stale.
: "${SENTINEL_SHIELD_HEALTH_REPORT_MAX_AGE_DAYS:=7}"      # newest report older than this => stale.
: "${SENTINEL_SHIELD_HEALTH_REQUIRED_TOOLS:=jq git}"      # required tools (space-separated).
: "${SENTINEL_SHIELD_HEALTH_NET_TIMEOUT:=15}"             # bounded network-probe timeout (seconds).
: "${SENTINEL_SHIELD_HEALTH_GITHUB_URL:=https://github.com/anthropics/.git}"  # probe URL.

TARGET="."
CHECK_NETWORK=0
FORMAT="json"
REPORT_PATH=""
QUIET=0
while [ $# -gt 0 ]; do case "$1" in
	--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
	--check-network) CHECK_NETWORK=1; shift ;;
	--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
	--report) REPORT_PATH="${2:?--report requires a value}"; shift 2 ;;
	--quiet) QUIET=1; shift ;;
	-h|--help)
		echo "Usage: health.sh [--target <dir>] [--check-network] [--format json|text] [--report <path>] [--quiet]"
		exit 0 ;;
	*) log_error "health: unknown argument: $1"; exit "$EX_USAGE" ;;
esac; done

command_exists jq || { log_error "health: jq is required"; exit "$EX_USAGE"; }
case "$FORMAT" in json|text) ;; *) log_error "health: invalid --format '$FORMAT' (json|text)"; exit "$EX_USAGE" ;; esac
[ -d "$TARGET" ] || { log_error "health: target not a directory: $TARGET"; exit "$EX_USAGE"; }

# Canonicalize the target PHYSICALLY (pwd -P resolves symlink components) so the redacted
# identity + df/writability act on the REAL path, not a symlinked alias.
TARGET=$(CDPATH= cd -- "$TARGET" 2>/dev/null && pwd -P) || { log_error "health: cannot resolve target"; exit "$EX_USAGE"; }
SS_DIR="$TARGET/.sentinel-shield"
export SS_DIR

# Redaction roots so any detail that slips a path through is relativized (defence in depth).
RD_TARGET_ROOT="$TARGET"; RD_HOME="${HOME:-}"
export RD_TARGET_ROOT RD_HOME

# --- result accumulation ----------------------------------------------------------------------
# One line per check in RESULTS: name<TAB>status<TAB>reason<TAB>detail  (detail already sanitized).
RESULTS=$(mktemp 2>/dev/null || mktemp -t sshealth)
cleanup() { rm -f -- "$RESULTS" 2>/dev/null || :; }
trap cleanup EXIT INT TERM
TAB=$(printf '\t')

# _h_sanitize — reduce a detail string to a single safe line: redact secrets/paths, then collapse
# tabs/newlines to spaces so it can never break the TSV or the JSON line.
_h_sanitize() {
	printf '%s' "$1" | rd_redact_stream 2>/dev/null | tr '\t\n' '  ' | sed 's/  */ /g; s/^ //; s/ $//'
}

# _h_str_gt <a> <b> — return 0 iff string <a> sorts strictly AFTER <b> in the C locale. POSIX
# `test` has no '>' operator, so compare via a stable sort. ISO-8601 UTC timestamps sort
# chronologically, so this doubles as "a is later than b".
_h_str_gt() {
	[ "$1" != "$2" ] || return 1
	[ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -n1)" = "$2" ]
}

# _h_record <name> <status> <reason> <detail> — append one check result.
_h_record() {
	_hr_detail=$(_h_sanitize "${4:-}")
	printf '%s%s%s%s%s%s%s\n' "$1" "$TAB" "$2" "$TAB" "$3" "$TAB" "$_hr_detail" >> "$RESULTS"
	unset _hr_detail
}

# =============================================================================================
# CHECK: metadata_consistency
# =============================================================================================
_h_check_metadata() {
	_m_path="$SS_DIR/installation.json"
	if [ ! -f "$_m_path" ]; then
		_h_record metadata_consistency unhealthy metadata_missing "no installation.json at the adoption root"
		return 0
	fi
	if im_validate "$_m_path" >/dev/null 2>&1; then
		_h_record metadata_consistency healthy metadata_ok "installation.json present and valid"
	else
		_h_record metadata_consistency unhealthy metadata_invalid "installation.json failed structural validation"
	fi
	unset _m_path
}

# =============================================================================================
# CHECK: operation_state (stale / incomplete / torn operation lock)
# =============================================================================================
_h_check_operation() {
	_o_lock="$SS_DIR/operation-lock.json"
	_o_mutex="$SS_DIR/operation-lock.d"
	if [ ! -f "$_o_lock" ]; then
		if [ -d "$_o_mutex" ]; then
			_h_record operation_state unhealthy operation_lock_torn "mutex directory present with no lock marker (torn acquisition)"
		else
			_h_record operation_state healthy operation_clean "no in-flight or leftover operation lock"
		fi
		unset _o_lock _o_mutex
		return 0
	fi
	if ! jq -e . "$_o_lock" >/dev/null 2>&1; then
		_h_record operation_state unknown operation_state_unknown "operation lock present but not parseable"
		unset _o_lock _o_mutex
		return 0
	fi
	_o_state=$(jq -r '.state // "unknown"' "$_o_lock" 2>/dev/null) || _o_state="unknown"
	case "$_o_state" in
		rollback-incomplete)
			_h_record operation_state unhealthy operation_incomplete "a prior rollback did not complete (state=rollback-incomplete)"
			;;
		completed)
			_h_record operation_state degraded operation_completed_unreleased "a completed operation left its lock behind (benign; next run clears it)"
			;;
		initializing|active|validating|committing|rolling-back)
			# Reuse the transaction subsystem's owner classifier (defeats PID reuse via
			# pid_start) rather than a hand-rolled hostname + kill -0 check that would
			# misread a recycled PID as a live operation.
			LOCK="$_o_lock"
			case "$(_tx_owner_classify)" in
				live)
					_h_record operation_state degraded operation_in_progress "an operation appears to be running now (state=$_o_state)" ;;
				foreign)
					_h_record operation_state unhealthy operation_stale "lock owned by a different host (cannot be live locally); state=$_o_state" ;;
				*)
					_h_record operation_state unhealthy operation_stale "an interrupted operation left a stale lock (state=$_o_state)" ;;
			esac
			unset LOCK
			;;
		*)
			_h_record operation_state unknown operation_state_unknown "operation lock has an unrecognized state"
			;;
	esac
	unset _o_lock _o_mutex _o_state
}

# =============================================================================================
# CHECK: journal_integrity (reuses Task 2 tx_journal_verify)
# =============================================================================================
_h_check_journal() {
	_j_file="$SS_DIR/transaction-journal.jsonl"
	if [ ! -f "$_j_file" ]; then
		_h_record journal_integrity healthy journal_absent "no transaction journal (no mutating operation has run)"
		unset _j_file
		return 0
	fi
	_j_rc=0
	tx_journal_verify strict >/dev/null 2>&1 || _j_rc=$?
	if [ "$_j_rc" -eq 0 ]; then
		_h_record journal_integrity healthy journal_ok "append-only journal chain verified"
	elif [ "$_j_rc" -eq 4 ]; then
		_h_record journal_integrity unhealthy journal_tampered "journal chain broken (truncated, altered, or tampered)"
	else
		_h_record journal_integrity unknown journal_unverifiable "journal could not be verified (rc=$_j_rc)"
	fi
	unset _j_file _j_rc
}

# =============================================================================================
# CHECK: tool_availability
# =============================================================================================
_h_check_tools() {
	_t_missing=""
	for _t_tool in $SENTINEL_SHIELD_HEALTH_REQUIRED_TOOLS; do
		[ -n "$_t_tool" ] || continue
		command_exists "$_t_tool" || _t_missing="${_t_missing:+$_t_missing }$_t_tool"
	done
	if [ -z "$_t_missing" ]; then
		_h_record tool_availability healthy tools_ok "all required tools present"
	else
		_h_record tool_availability unhealthy required_tool_missing "missing required tool(s): $_t_missing"
	fi
	unset _t_missing _t_tool
}

# =============================================================================================
# CHECK: scanner_health (vulnerability-db freshness; pure-integer epoch math, no date parsing)
# =============================================================================================
_h_check_scanner() {
	_s_prov="$SS_DIR/scanner-provenance.json"
	if [ ! -f "$_s_prov" ]; then
		_h_record scanner_health skipped scanner_not_configured "no scanner provenance recorded"
		unset _s_prov
		return 0
	fi
	if ! jq -e 'type == "object"' "$_s_prov" >/dev/null 2>&1; then
		_h_record scanner_health degraded scanner_provenance_invalid "scanner provenance is not a valid JSON object"
		unset _s_prov
		return 0
	fi
	_s_epoch=$(jq -r '.vulnerability_db.built_epoch // empty' "$_s_prov" 2>/dev/null) || _s_epoch=""
	_s_now=$(date -u +%s 2>/dev/null) || _s_now=""
	if [ -n "$_s_epoch" ] && printf '%s' "$_s_epoch" | grep -Eq '^[0-9]+$' && printf '%s' "$_s_now" | grep -Eq '^[0-9]+$'; then
		_s_maxage=$((SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS * 86400))
		_s_threshold=$((_s_now - _s_maxage))
		if [ "$_s_epoch" -lt "$_s_threshold" ]; then
			_h_record scanner_health degraded scanner_db_stale "scanner vulnerability-db older than ${SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS}d"
		else
			_h_record scanner_health healthy scanner_ok "scanner vulnerability-db is fresh"
		fi
		unset _s_maxage _s_threshold
	elif find "$_s_prov" -mtime "+${SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS}" 2>/dev/null | grep -q .; then
		_h_record scanner_health degraded scanner_db_stale "scanner provenance file older than ${SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS}d (no built_epoch)"
	else
		_h_record scanner_health healthy scanner_ok "scanner provenance present (freshness by file age)"
	fi
	unset _s_prov _s_epoch _s_now
}

# =============================================================================================
# CHECK: report_freshness
# =============================================================================================
_h_check_reports() {
	_r_dir="$SS_DIR/reports"
	if [ ! -d "$_r_dir" ]; then
		_h_record report_freshness skipped report_not_configured "no local report directory"
		unset _r_dir
		return 0
	fi
	if ! find "$_r_dir" -type f 2>/dev/null | grep -q .; then
		_h_record report_freshness skipped report_not_configured "report directory is empty"
		unset _r_dir
		return 0
	fi
	# Stale iff NO file was modified within the freshness window (i.e. the newest is too old).
	if find "$_r_dir" -type f -mtime "-${SENTINEL_SHIELD_HEALTH_REPORT_MAX_AGE_DAYS}" 2>/dev/null | grep -q .; then
		_h_record report_freshness healthy report_fresh "a report was produced within ${SENTINEL_SHIELD_HEALTH_REPORT_MAX_AGE_DAYS}d"
	else
		_h_record report_freshness degraded report_stale "newest report older than ${SENTINEL_SHIELD_HEALTH_REPORT_MAX_AGE_DAYS}d"
	fi
	unset _r_dir
}

# =============================================================================================
# CHECK: ref_immutability + source_verification (reuse Task-adjacent sv_is_hex40)
# =============================================================================================
_h_check_source() {
	_sv_file="$SS_DIR/source.json"
	if [ ! -f "$_sv_file" ]; then
		_h_record ref_immutability skipped ref_absent "no recorded source ref"
		_h_record source_verification skipped source_not_configured "no recorded source pin"
		unset _sv_file
		return 0
	fi
	if ! jq -e 'type == "object"' "$_sv_file" >/dev/null 2>&1; then
		_h_record ref_immutability unknown ref_unknown "source.json is not a valid JSON object"
		_h_record source_verification unknown source_unverifiable "source.json is not a valid JSON object"
		unset _sv_file
		return 0
	fi
	# ref immutability
	_sv_ref=$(jq -r '.ref // empty' "$_sv_file" 2>/dev/null) || _sv_ref=""
	if [ -z "$_sv_ref" ]; then
		_h_record ref_immutability skipped ref_absent "no ref recorded in source.json"
	elif sv_is_hex40 "$_sv_ref"; then
		_h_record ref_immutability healthy ref_immutable "source ref pinned to a full commit SHA"
	else
		case "$_sv_ref" in
			refs/tags/*|v[0-9]*|[0-9]*.[0-9]*)
				_h_record ref_immutability healthy ref_immutable "source ref is an immutable tag" ;;
			HEAD|main|master|refs/heads/*|heads/*)
				_h_record ref_immutability degraded ref_moving "source ref is a MOVING branch, not an immutable pin" ;;
			*)
				_h_record ref_immutability unknown ref_unknown "source ref immutability could not be classified" ;;
		esac
	fi
	# source verification: pinned vs resolved commit
	_sv_pin=$(jq -r '.pinned_commit // empty' "$_sv_file" 2>/dev/null) || _sv_pin=""
	_sv_res=$(jq -r '.resolved_commit // empty' "$_sv_file" 2>/dev/null) || _sv_res=""
	if [ -z "$_sv_pin" ] || [ -z "$_sv_res" ]; then
		_h_record source_verification skipped source_not_configured "no pinned/resolved commit pair recorded"
	elif ! sv_is_hex40 "$_sv_pin" || ! sv_is_hex40 "$_sv_res"; then
		_h_record source_verification unknown source_unverifiable "pinned/resolved commit is not a 40-hex SHA"
	else
		_sv_pl=$(printf '%s' "$_sv_pin" | tr 'A-F' 'a-f')
		_sv_rl=$(printf '%s' "$_sv_res" | tr 'A-F' 'a-f')
		if [ "$_sv_pl" = "$_sv_rl" ]; then
			_h_record source_verification healthy source_verified "resolved source commit matches the pinned commit"
		else
			_h_record source_verification unhealthy source_ref_mismatch "resolved source commit does NOT match the pinned commit"
		fi
		unset _sv_pl _sv_rl
	fi
	unset _sv_file _sv_ref _sv_pin _sv_res
}

# =============================================================================================
# CHECK: managed_file_drift
# =============================================================================================
_h_check_drift() {
	_d_meta="$SS_DIR/installation.json"
	_d_manifest="$SS_DIR/managed-manifest.json"
	if [ ! -f "$_d_meta" ]; then
		_h_record managed_file_drift skipped managed_not_configured "no installation record to derive managed files"
		unset _d_meta _d_manifest
		return 0
	fi
	_d_drift=0; _d_checked=0
	# 1) Every managed file listed in installation.json must exist.
	_d_list=$(im_list_managed_files "$TARGET" 2>/dev/null) || _d_list=""
	if [ -n "$_d_list" ]; then
		# shellcheck disable=SC2030
		printf '%s\n' "$_d_list" | while IFS= read -r _d_rel; do
			[ -n "$_d_rel" ] || continue
			[ -e "$TARGET/$_d_rel" ] || printf 'x'
		done > "$RESULTS.drift" 2>/dev/null || :
		if [ -s "$RESULTS.drift" ]; then _d_drift=1; fi
		_d_checked=1
		rm -f -- "$RESULTS.drift" 2>/dev/null || :
	fi
	# 2) If a digest manifest exists, verify each recorded digest.
	if [ -f "$_d_manifest" ]; then
		if ! jq -e 'type == "object"' "$_d_manifest" >/dev/null 2>&1; then
			_h_record managed_file_drift degraded managed_manifest_invalid "managed-manifest.json is not a valid JSON object"
			unset _d_meta _d_manifest _d_drift _d_checked _d_list
			return 0
		fi
		_d_checked=1
		_d_pairs=$(jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$_d_manifest" 2>/dev/null) || _d_pairs=""
		if [ -n "$_d_pairs" ]; then
			_d_mm=$(mktemp 2>/dev/null || mktemp -t sshealthmm)
			printf '%s\n' "$_d_pairs" | while IFS="$TAB" read -r _d_rel _d_want; do
				[ -n "$_d_rel" ] || continue
				_d_got=$(ss_sha256_file "$TARGET/$_d_rel" 2>/dev/null) || _d_got=""
				[ "$_d_got" = "$_d_want" ] || printf 'x' >> "$_d_mm"
			done
			[ -s "$_d_mm" ] && _d_drift=1
			rm -f -- "$_d_mm" 2>/dev/null || :
			unset _d_mm
		fi
	fi
	if [ "$_d_checked" -eq 0 ]; then
		_h_record managed_file_drift healthy managed_clean "no managed files recorded"
	elif [ "$_d_drift" -eq 1 ]; then
		_h_record managed_file_drift degraded managed_file_drift "one or more managed files are missing or changed"
	else
		_h_record managed_file_drift healthy managed_clean "all managed files present and matching"
	fi
	unset _d_meta _d_manifest _d_drift _d_checked _d_list _d_pairs 2>/dev/null || :
}

# =============================================================================================
# CHECK: package_manager_state
# =============================================================================================
_h_check_pm() {
	_p_file="$SS_DIR/package-manager.json"
	if [ ! -f "$_p_file" ]; then
		_h_record package_manager_state skipped package_manager_not_configured "no package-manager state recorded"
		unset _p_file
		return 0
	fi
	if ! jq -e 'type == "object"' "$_p_file" >/dev/null 2>&1; then
		_h_record package_manager_state degraded package_manager_ambiguous "package-manager state is not a valid JSON object"
		unset _p_file
		return 0
	fi
	_p_status=$(jq -r '.status // "unknown"' "$_p_file" 2>/dev/null) || _p_status="unknown"
	case "$_p_status" in
		supported|ok)   _h_record package_manager_state healthy package_manager_ok "package manager resolved and supported" ;;
		unsupported)    _h_record package_manager_state degraded package_manager_unsupported "the resolved package manager is unsupported" ;;
		ambiguous)      _h_record package_manager_state degraded package_manager_ambiguous "package-manager resolution is ambiguous" ;;
		*)              _h_record package_manager_state degraded package_manager_ambiguous "package-manager state is unrecognized" ;;
	esac
	unset _p_file _p_status
}

# =============================================================================================
# CHECK: disk_space
# =============================================================================================
_h_check_disk() {
	_k_avail=$(df -Pk "$TARGET" 2>/dev/null | awk 'NR==2 {print $4}') || _k_avail=""
	if ! printf '%s' "$_k_avail" | grep -Eq '^[0-9]+$'; then
		_h_record disk_space unknown disk_space_unknown "could not determine free space on the target filesystem"
		unset _k_avail
		return 0
	fi
	if [ "$_k_avail" -lt "$SENTINEL_SHIELD_HEALTH_DISK_MIN_KB" ]; then
		_h_record disk_space unhealthy disk_space_low "free space ${_k_avail}KB below minimum ${SENTINEL_SHIELD_HEALTH_DISK_MIN_KB}KB"
	else
		_h_record disk_space healthy disk_ok "free space at/above the configured minimum"
	fi
	unset _k_avail
}

# =============================================================================================
# CHECK: write_permissions
# =============================================================================================
_h_check_write() {
	_w_dir="$SS_DIR"
	[ -d "$_w_dir" ] || _w_dir="$TARGET"
	_w_probe="$_w_dir/.ss-health-write.$$"
	if ( umask 077; : > "$_w_probe" ) 2>/dev/null; then
		rm -f -- "$_w_probe" 2>/dev/null || :
		_h_record write_permissions healthy write_ok "the adoption directory is writable"
	else
		_h_record write_permissions unhealthy write_permission_denied "the adoption directory is not writable"
	fi
	unset _w_dir _w_probe
}

# =============================================================================================
# CHECK: time_sync (clock-skew warning; ISO-8601 UTC sorts chronologically, so compare lexically)
# =============================================================================================
_h_check_time() {
	_ts_now=$(timestamp_utc 2>/dev/null) || _ts_now=""
	if [ -z "$_ts_now" ]; then
		_h_record time_sync skipped time_unknown "system clock could not be read"
		unset _ts_now
		return 0
	fi
	_ts_max=""
	for _ts_f in "$SS_DIR/installation.json:.updated_at" "$SS_DIR/installation.json:.installed_at" "$SS_DIR/operation-lock.json:.started_at"; do
		_ts_p="${_ts_f%%:*}"; _ts_q="${_ts_f#*:}"
		[ -f "$_ts_p" ] || continue
		_ts_v=$(jq -r "$_ts_q // empty" "$_ts_p" 2>/dev/null) || _ts_v=""
		[ -n "$_ts_v" ] || continue
		if [ -z "$_ts_max" ] || _h_str_gt "$_ts_v" "$_ts_max"; then _ts_max="$_ts_v"; fi
	done
	if [ -z "$_ts_max" ]; then
		_h_record time_sync skipped time_unknown "no recorded timestamps to compare against the clock"
	elif _h_str_gt "$_ts_max" "$_ts_now"; then
		_h_record time_sync degraded time_skew_future "a recorded timestamp is in the FUTURE relative to the system clock"
	else
		_h_record time_sync healthy time_ok "recorded timestamps are consistent with the system clock"
	fi
	unset _ts_now _ts_max _ts_f _ts_p _ts_q _ts_v
}

# =============================================================================================
# CHECK: github_connectivity — ONLY when --check-network. Bounded (Task 1) with a DISTINCT timeout.
# =============================================================================================
_h_check_network() {
	if [ "$CHECK_NETWORK" -ne 1 ]; then
		_h_record github_connectivity skipped network_not_requested "network check not requested (offline)"
		return 0
	fi
	# The probe is overridable so it can be exercised deterministically and offline in tests. The
	# default performs a read-only ref listing against the configured URL (no clone, no write).
	_n_out=$(mktemp 2>/dev/null || mktemp -t sshealthno)
	_n_err=$(mktemp 2>/dev/null || mktemp -t sshealthne)
	_n_rc=0
	if [ -n "${SENTINEL_SHIELD_HEALTH_NET_PROBE:-}" ]; then
		# Operator-supplied probe is an explicit shell command (their responsibility).
		bp_run network "$SENTINEL_SHIELD_HEALTH_NET_TIMEOUT" "$_n_out" "$_n_err" -- sh -c "$SENTINEL_SHIELD_HEALTH_NET_PROBE" || _n_rc=$?
	else
		# Default: pass the URL as a DISTINCT argv element (no `sh -c`), so a URL carrying
		# shell metacharacters cannot inject a command.
		bp_run network "$SENTINEL_SHIELD_HEALTH_NET_TIMEOUT" "$_n_out" "$_n_err" -- git ls-remote --quiet --exit-code "$SENTINEL_SHIELD_HEALTH_GITHUB_URL" HEAD || _n_rc=$?
	fi
	rm -f -- "$_n_out" "$_n_err" 2>/dev/null || :
	if [ "$_n_rc" -eq 0 ]; then
		_h_record github_connectivity healthy network_ok "required GitHub endpoint reachable"
	elif [ "$_n_rc" -eq "${BP_RC_TIMEOUT:-124}" ]; then
		_h_record github_connectivity unhealthy network_timeout "GitHub connectivity probe timed out after ${SENTINEL_SHIELD_HEALTH_NET_TIMEOUT}s"
	elif [ "$_n_rc" -eq "${BP_RC_UNAVAILABLE:-127}" ]; then
		_h_record github_connectivity unknown network_probe_invalid "connectivity probe tool not available"
	else
		_h_record github_connectivity unhealthy network_unreachable "required GitHub endpoint not reachable (probe rc=$_n_rc)"
	fi
	unset _n_out _n_err _n_rc
}

# --- run all checks ---------------------------------------------------------------------------
_ss_start_ms=""
if command -v oe_now_ms >/dev/null 2>&1; then _ss_start_ms=$(oe_now_ms); fi
if command -v oe_emit >/dev/null 2>&1; then
	oe_emit --command health --phase start --event-type start --status in-progress \
		--reason-code health_begin --component health --target "$TARGET" ${_ss_start_ms:+--start-ms "$_ss_start_ms"} || :
fi

_h_check_metadata
_h_check_operation
_h_check_journal
_h_check_tools
_h_check_scanner
_h_check_reports
_h_check_source
_h_check_drift
_h_check_pm
_h_check_disk
_h_check_write
_h_check_time
_h_check_network

# --- roll up ----------------------------------------------------------------------------------
N_HEALTHY=0; N_DEGRADED=0; N_UNHEALTHY=0; N_UNKNOWN=0; N_SKIPPED=0
while IFS="$TAB" read -r _agg_name _agg_status _agg_reason _agg_detail; do
	[ -n "$_agg_name" ] || continue
	case "$_agg_status" in
		healthy)   N_HEALTHY=$((N_HEALTHY + 1)) ;;
		degraded)  N_DEGRADED=$((N_DEGRADED + 1)) ;;
		unhealthy) N_UNHEALTHY=$((N_UNHEALTHY + 1)) ;;
		unknown)   N_UNKNOWN=$((N_UNKNOWN + 1)) ;;
		skipped)   N_SKIPPED=$((N_SKIPPED + 1)) ;;
	esac
done < "$RESULTS"

if [ "$N_UNHEALTHY" -gt 0 ]; then OVERALL="unhealthy"; EXIT_CODE=2
elif [ "$N_DEGRADED" -gt 0 ]; then OVERALL="degraded"; EXIT_CODE=1
elif [ "$N_UNKNOWN" -gt 0 ]; then OVERALL="unknown"; EXIT_CODE=3
else OVERALL="healthy"; EXIT_CODE=0
fi

# reason_codes: the actionable (non-healthy, non-skipped) reason codes, de-duplicated, in order.
REASONS_JSON=$(awk -F"$TAB" '
	$2 == "degraded" || $2 == "unhealthy" || $2 == "unknown" { if (!seen[$3]++) print $3 }' "$RESULTS" \
	| jq -R -n '[inputs | select(length > 0)]')
[ -n "$REASONS_JSON" ] || REASONS_JSON='[]'

CHECKS_JSON=$(awk -F"$TAB" 'NF>=3 {
	name=$1; status=$2; reason=$3; detail=$4;
	print name "\t" status "\t" reason "\t" detail
}' "$RESULTS" | jq -R -n '
	[ inputs
	  | select(length > 0)
	  | split("\t")
	  | { name: .[0], status: .[1], reason_code: .[2], detail: (.[3] // "") } ]')
[ -n "$CHECKS_JSON" ] || CHECKS_JSON='[]'

TARGET_ID="target:unknown"
if command -v oe_target_id >/dev/null 2>&1; then TARGET_ID=$(oe_target_id "$TARGET"); fi

_offline=true; [ "$CHECK_NETWORK" -eq 1 ] && _offline=false
_netchecked=false; [ "$CHECK_NETWORK" -eq 1 ] && _netchecked=true

REPORT_JSON=$(jq -n \
	--arg generated_at "$(timestamp_utc)" \
	--arg target "$TARGET_ID" \
	--arg status "$OVERALL" \
	--argjson offline "$_offline" \
	--argjson network_checked "$_netchecked" \
	--argjson checks "$CHECKS_JSON" \
	--argjson reason_codes "$REASONS_JSON" \
	--argjson healthy "$N_HEALTHY" \
	--argjson degraded "$N_DEGRADED" \
	--argjson unhealthy "$N_UNHEALTHY" \
	--argjson unknown "$N_UNKNOWN" \
	--argjson skipped "$N_SKIPPED" '
	{
		schema: "health-report",
		schema_version: "1",
		generated_at: $generated_at,
		target: $target,
		mode: { offline: $offline, network_checked: $network_checked },
		status: $status,
		checks: $checks,
		reason_codes: $reason_codes,
		summary: {
			healthy: $healthy,
			degraded: $degraded,
			unhealthy: $unhealthy,
			unknown: $unknown,
			skipped: $skipped
		}
	}')

# --- emit -------------------------------------------------------------------------------------
if [ -n "$REPORT_PATH" ]; then
	printf '%s\n' "$REPORT_JSON" > "$REPORT_PATH" 2>/dev/null || log_warn "health: could not write report to the requested path"
fi

if [ "$QUIET" -ne 1 ]; then
	{
		printf 'Sentinel Shield health: %s\n' "$OVERALL"
		printf '  healthy=%s degraded=%s unhealthy=%s unknown=%s skipped=%s\n' \
			"$N_HEALTHY" "$N_DEGRADED" "$N_UNHEALTHY" "$N_UNKNOWN" "$N_SKIPPED"
		while IFS="$TAB" read -r _pr_name _pr_status _pr_reason _pr_detail; do
			[ -n "$_pr_name" ] || continue
			printf '  [%-9s] %-22s %s\n' "$_pr_status" "$_pr_name" "$_pr_reason"
		done < "$RESULTS"
	} >&2
fi

if [ "$FORMAT" = "json" ]; then
	printf '%s\n' "$REPORT_JSON"
fi

if command -v oe_emit >/dev/null 2>&1; then
	_ss_ev_type=complete; _ss_ev_sev=info; _ss_ev_status=success
	case "$OVERALL" in
		unhealthy) _ss_ev_type=error; _ss_ev_sev=error; _ss_ev_status=failure ;;
		degraded)  _ss_ev_sev=warning ;;
		unknown)   _ss_ev_status=unknown ;;
	esac
	oe_emit --command health --phase complete --event-type "$_ss_ev_type" --severity "$_ss_ev_sev" \
		--status "$_ss_ev_status" --reason-code "$OVERALL" --component health --target "$TARGET" \
		${_ss_start_ms:+--start-ms "$_ss_start_ms"} || :
fi

exit "$EXIT_CODE"
