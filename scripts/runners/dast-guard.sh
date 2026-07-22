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
	# strip scheme, then path/query, then USERINFO, then port. Userinfo must go before
	# the port strip: 'http://allowed.host:x@evil.com/' would otherwise truncate at the
	# first ':' and report 'allowed.host' while the scanner actually hits 'evil.com'.
	_h=${1#*://}; _h=${_h%%/*}; _h=${_h%%\?*}; _h=${_h##*@}; _h=${_h%%:*}
	printf '%s' "$_h"
}
# ss_dast_check — guarded DAST preflight check (target/host validation).
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
	# The dispatch input above is self-attested (target_url + allowed_host both come from the
	# dispatcher). If a COMMITTED allowlist file is configured, the host must ALSO appear in it —
	# a repo change gated by review/branch-protection, not a dispatch-time claim. Default path is
	# checked when present; SENTINEL_SHIELD_DAST_ALLOWLIST_FILE overrides. Fail closed on a
	# configured-but-missing file or an absent host.
	_allowfile="${SENTINEL_SHIELD_DAST_ALLOWLIST_FILE:-}"
	if [ -z "$_allowfile" ] && [ -f .sentinel-shield/dast-allowlist.txt ]; then
		_allowfile=".sentinel-shield/dast-allowlist.txt"
	fi
	if [ -n "$_allowfile" ]; then
		if [ ! -f "$_allowfile" ]; then
			echo "[sentinel-shield][dast] committed allowlist '$_allowfile' configured but not found; FAIL CLOSED (no scan)." >&2
			return 3
		fi
		# Exact, whole-line match; '#' comments and blank lines ignored.
		if ! grep -q -x -F -e "$_host" -- "$_allowfile" 2>/dev/null; then
			echo "[sentinel-shield][dast] target host '$_host' is not listed in the committed allowlist '$_allowfile'; FAIL CLOSED (no scan)." >&2
			return 3
		fi
		echo "[sentinel-shield][dast] target host '$_host' present in committed allowlist '$_allowfile'; proceeding." >&2
		return 0
	fi
	echo "[sentinel-shield][dast] target host '$_host' matches the dispatch allowed_host (no committed allowlist file present; consider committing .sentinel-shield/dast-allowlist.txt for review-gated targets); proceeding." >&2
	return 0
}

# ss_nuclei_template_check — code-enforced controlled template-path guard (v0.1.25).
# Independent of ss_dast_check (which zap runners depend on; do NOT fold this in there).
# Enforces SENTINEL_SHIELD_NUCLEI_TEMPLATES (required curated template dir/file path):
#   - MISSING (unset/empty)                                  -> return 3
#   - PATH TRAVERSAL ('..' anywhere in the path)             -> return 3
#   - REMOTE URL (http://, https://, git@) w/o explicit
#     SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1                  -> return 3
#   - PATH ABSENT on disk                                    -> return 3
# Returns 0 only when a local, non-traversing template path exists on disk (or an
# explicitly-allowed remote URL is supplied).
ss_nuclei_template_check() {
	_tpl="${SENTINEL_SHIELD_NUCLEI_TEMPLATES:-}"
	_allow_remote="${SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE:-}"
	if [ -z "$_tpl" ]; then
		echo "[sentinel-shield][dast] SENTINEL_SHIELD_NUCLEI_TEMPLATES not set; FAIL CLOSED (a curated template path is required for a controlled run)." >&2
		return 3
	fi
	case "$_tpl" in
		*..*)
			echo "[sentinel-shield][dast] template path '$_tpl' contains '..' (path traversal); FAIL CLOSED." >&2
			return 3 ;;
	esac
	case "$_tpl" in
		http://*|https://*|git@*)
			if [ "$_allow_remote" = "1" ]; then
				echo "[sentinel-shield][dast] remote template source '$_tpl' explicitly allowed (SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1); proceeding." >&2
				return 0
			fi
			echo "[sentinel-shield][dast] template path '$_tpl' is a remote URL; FAIL CLOSED (set SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1 to explicitly allow)." >&2
			return 3 ;;
	esac
	if [ ! -e "$_tpl" ]; then
		echo "[sentinel-shield][dast] template path '$_tpl' does not exist on disk; FAIL CLOSED." >&2
		return 3
	fi
	echo "[sentinel-shield][dast] curated template path '$_tpl' validated; proceeding." >&2
	return 0
}
