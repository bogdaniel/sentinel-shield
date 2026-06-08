#!/bin/sh
# Sentinel Shield — DAST safety guard (sourced by zap/nuclei runners).
# Enforces: no target URL -> SKIP (exit 0, no scan). Host not allowlisted -> FAIL CLOSED
# (exit 3). NEVER scans an arbitrary target. POSIX sh.
#
# Env:
#   SENTINEL_SHIELD_DAST_TARGET_URL    required to run; absent => skip
#   SENTINEL_SHIELD_DAST_ALLOWED_HOST  required allowlist; must equal the target host
#
# Usage in a runner:
#   . "$SCRIPT_DIR/dast-guard.sh"; ss_dast_check || exit $?
ss_dast_host_of() {
	# strip scheme, then path, then port
	_h=${1#*://}; _h=${_h%%/*}; _h=${_h%%\?*}; _h=${_h%%:*}
	printf '%s' "$_h"
}
ss_dast_check() {
	_url="${SENTINEL_SHIELD_DAST_TARGET_URL:-}"
	_allow="${SENTINEL_SHIELD_DAST_ALLOWED_HOST:-}"
	if [ -z "$_url" ]; then
		echo "[sentinel-shield][dast] SENTINEL_SHIELD_DAST_TARGET_URL not set; SKIPPING DAST (no scan run)." >&2
		return 10
	fi
	case "$_url" in
		http://*|https://*) : ;;
		*) echo "[sentinel-shield][dast] target URL must start with http:// or https:// — refusing." >&2; return 3 ;;
	esac
	if [ -z "$_allow" ]; then
		echo "[sentinel-shield][dast] SENTINEL_SHIELD_DAST_ALLOWED_HOST not set; FAIL CLOSED (refusing to scan an un-allowlisted target)." >&2
		return 3
	fi
	_host=$(ss_dast_host_of "$_url")
	if [ "$_host" != "$_allow" ]; then
		echo "[sentinel-shield][dast] target host '$_host' is not the allowed host '$_allow'; FAIL CLOSED (no scan)." >&2
		return 3
	fi
	echo "[sentinel-shield][dast] target host '$_host' allowlisted; proceeding." >&2
	return 0
}
