#!/bin/sh
# Sentinel Shield — bounded-process helper (POSIX sh library, bp_* functions).
#
# Source this file; do NOT execute it. It defines helper functions only and does
# not enable `set -eu` itself (the caller decides). All functions are POSIX sh
# compatible: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
#
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/bounded-process.sh"
#
# WHY THIS EXISTS
#   Every external process the engine shells out to (docker info/inspect, scanner
#   version probes, scanner runs, gh api, git signature verification, package
#   managers, archive inspection, consumer validation) can HANG indefinitely when
#   the far side is unreachable/unhealthy — a wedged Docker daemon, a stuck API, a
#   scanner waiting on a dead network. An unbounded child freezes the whole gate.
#   This helper runs any command under a hard, bounded wall-clock timeout, escalates
#   TERM -> (bounded grace) -> KILL, reaps the whole descendant tree so nothing is
#   orphaned, preserves the real exit code on normal completion, and classifies the
#   outcome into a stable, machine-readable status. It NEVER leaks command arguments
#   (which may carry credentials) into diagnostics — only the executable basename and
#   the command category are ever surfaced.
#
# EXECUTION MODEL
#   * When GNU `timeout` (or `gtimeout`) is present it is used (it handles process
#     groups natively), UNLESS SENTINEL_SHIELD_BP_FORCE_PORTABLE=1.
#   * Otherwise a PORTABLE watchdog is used: the command runs in the background, a
#     watchdog polls it once per second up to <timeout>, then sends TERM to the whole
#     descendant tree, waits a bounded grace, then sends KILL. The watchdog and any
#     leftover descendants are reaped before bp_run returns — no orphans.
#
# OUTPUT CONTRACT (bp_result_json, schemas/bounded-command-result.schema.json)
#   { schema, command, command_category, status, exit_code, signal,
#     timeout_seconds, duration_seconds, timed_out, timestamp }
#   status is one of: success | failed | timed-out | unavailable | signalled.
#   exit_code is null on timed-out / unavailable / signalled; signal is the number on
#   signalled (else null). `command` is the executable BASENAME only — never args.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_BOUNDED_PROCESS_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_BOUNDED_PROCESS_LOADED=1

# --- result codes ------------------------------------------------------------
# Distinct, stable return codes so a caller can branch without parsing text.
# A normally-completed command's own exit code is PRESERVED (returned verbatim);
# the codes below are reserved for the classes that have no natural exit code.
BP_RC_TIMEOUT=124        # command exceeded its bounded wall-clock timeout
BP_RC_UNAVAILABLE=127    # the executable was not found on PATH (never launched)
BP_RC_INVALID=2          # invalid invocation (bad/zero/negative/excessive timeout)

# --- configuration -----------------------------------------------------------
# bp_default_for_category <category> — the built-in default timeout (seconds) for a
# category, used when no category-specific env override is set.
bp_default_for_category() {
	case "$1" in
		docker-probe)        printf '15' ;;   # docker info / inspect / image inspect
		github-api)          printf '60' ;;   # gh api / gh release
		package-install)     printf '600' ;;  # composer/npm/yarn install
		package-probe)       printf '30' ;;   # package-manager --version probes
		scanner-version)     printf '30' ;;   # scanner version probes
		scanner-exec)        printf '300' ;;  # scanner execution
		git-verify)          printf '60' ;;   # git verify-tag / signature verification
		archive)             printf '120' ;;  # archive inspection / extraction
		consumer-validation) printf '300' ;;  # external consumer validation
		*)                   printf '120' ;;  # generic external process
	esac
}

# bp_category_env <category> — the category-specific env var name that overrides the
# default for that category (e.g. docker-probe -> SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS).
bp_category_env() {
	case "$1" in
		docker-probe)        printf 'SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS' ;;
		github-api)          printf 'SENTINEL_SHIELD_GITHUB_API_TIMEOUT_SECONDS' ;;
		package-install)     printf 'SENTINEL_SHIELD_PACKAGE_INSTALL_TIMEOUT_SECONDS' ;;
		package-probe)       printf 'SENTINEL_SHIELD_PACKAGE_PROBE_TIMEOUT_SECONDS' ;;
		scanner-version)     printf 'SENTINEL_SHIELD_SCANNER_VERSION_TIMEOUT_SECONDS' ;;
		scanner-exec)        printf 'SENTINEL_SHIELD_SCANNER_TIMEOUT_SECONDS' ;;
		git-verify)          printf 'SENTINEL_SHIELD_GIT_VERIFY_TIMEOUT_SECONDS' ;;
		archive)             printf 'SENTINEL_SHIELD_ARCHIVE_TIMEOUT_SECONDS' ;;
		consumer-validation) printf 'SENTINEL_SHIELD_CONSUMER_TIMEOUT_SECONDS' ;;
		*)                   printf '' ;;
	esac
}

# bp_env_get <NAME> — indirect read of an env var by name (POSIX, no bashisms).
bp_env_get() { eval "printf '%s' \"\${$1:-}\""; }

# bp_max_timeout — the upper bound (seconds) a timeout may take. Anything larger is
# rejected as "excessive" (a runaway config that would defeat the purpose of bounding).
bp_max_timeout() { printf '%s' "${SENTINEL_SHIELD_PROCESS_TIMEOUT_MAX_SECONDS:-86400}"; }

# bp_kill_grace — seconds to wait after TERM before escalating to KILL. Bounded and
# validated; falls back to the safe default if the override is invalid.
bp_kill_grace() {
	_bp_g="${SENTINEL_SHIELD_PROCESS_KILL_GRACE_SECONDS:-5}"
	case "$_bp_g" in
		'' | *[!0-9]*) _bp_g=5 ;;
	esac
	[ "$_bp_g" -ge 1 ] 2>/dev/null || _bp_g=5
	[ "$_bp_g" -le 300 ] 2>/dev/null || _bp_g=5
	printf '%s' "$_bp_g"
	unset _bp_g
}

# bp_is_valid_timeout <value> — return 0 iff <value> is a positive integer within the
# allowed range. Rejects empty, non-numeric, zero, negative (a leading '-' is
# non-numeric here), and excessive values. FAIL CLOSED: no silent coercion.
bp_is_valid_timeout() {
	case "${1:-}" in
		'' | *[!0-9]*) return 1 ;;   # empty, sign, decimal point, or any non-digit
	esac
	# Reject a bare zero and any all-zero string.
	[ "$1" -gt 0 ] 2>/dev/null || return 1
	[ "$1" -le "$(bp_max_timeout)" ] 2>/dev/null || return 1
	return 0
}

# bp_validate_timeout <value> — bp_is_valid_timeout with a logged reason on failure.
bp_validate_timeout() {
	if bp_is_valid_timeout "${1:-}"; then
		return 0
	fi
	log_error "bounded-process: invalid timeout '${1:-}' (require a positive integer 1..$(bp_max_timeout) seconds)"
	return "$BP_RC_INVALID"
}

# bp_timeout <category> [override_env_name] — resolve the effective timeout (seconds)
# for a category. Precedence (first that is SET and VALID wins; an invalid override is
# rejected, not silently ignored — the function FAILS so a broken config is loud):
#   1. <override_env_name>                (scanner-specific override, e.g. per tool)
#   2. the category env (bp_category_env)
#   3. SENTINEL_SHIELD_PROCESS_TIMEOUT_SECONDS (global default override)
#   4. bp_default_for_category            (built-in default)
# Prints the resolved integer on success (return 0); on an invalid explicit override
# prints nothing and returns BP_RC_INVALID.
bp_timeout() {
	_bp_cat="$1"; _bp_over_env="${2:-}"
	# 1. explicit per-call override env (e.g. scanner-specific).
	if [ -n "$_bp_over_env" ]; then
		_bp_v=$(bp_env_get "$_bp_over_env")
		if [ -n "$_bp_v" ]; then
			if bp_is_valid_timeout "$_bp_v"; then printf '%s' "$_bp_v"; unset _bp_cat _bp_over_env _bp_v; return 0; fi
			log_error "bounded-process: $_bp_over_env='$_bp_v' is not a valid timeout (1..$(bp_max_timeout)s)"
			unset _bp_cat _bp_over_env _bp_v; return "$BP_RC_INVALID"
		fi
	fi
	# 2. category env.
	_bp_ce=$(bp_category_env "$_bp_cat")
	if [ -n "$_bp_ce" ]; then
		_bp_v=$(bp_env_get "$_bp_ce")
		if [ -n "$_bp_v" ]; then
			if bp_is_valid_timeout "$_bp_v"; then printf '%s' "$_bp_v"; unset _bp_cat _bp_over_env _bp_v _bp_ce; return 0; fi
			log_error "bounded-process: $_bp_ce='$_bp_v' is not a valid timeout (1..$(bp_max_timeout)s)"
			unset _bp_cat _bp_over_env _bp_v _bp_ce; return "$BP_RC_INVALID"
		fi
	fi
	# 3. global default override.
	_bp_v=$(bp_env_get SENTINEL_SHIELD_PROCESS_TIMEOUT_SECONDS)
	if [ -n "$_bp_v" ]; then
		if bp_is_valid_timeout "$_bp_v"; then printf '%s' "$_bp_v"; unset _bp_cat _bp_over_env _bp_v _bp_ce; return 0; fi
		log_error "bounded-process: SENTINEL_SHIELD_PROCESS_TIMEOUT_SECONDS='$_bp_v' is not a valid timeout (1..$(bp_max_timeout)s)"
		unset _bp_cat _bp_over_env _bp_v _bp_ce; return "$BP_RC_INVALID"
	fi
	# 4. built-in default.
	bp_default_for_category "$_bp_cat"
	unset _bp_cat _bp_over_env _bp_v _bp_ce
	return 0
}

# --- process-tree reaping ----------------------------------------------------
# bp_kill_tree <pid> <signal> — send <signal> to <pid> and every descendant, DEEPEST
# first (so a parent cannot re-parent/re-spawn a child before we reach it). Iterative
# (NO recursion — recursion with shared globals would clobber the caller's vars under
# `set -u`): it enumerates the tree breadth-first via pgrep, then signals in reverse so
# children die before their parents. Always best-effort (never fails the caller). This
# is how a bounded command that itself spawned children leaves NOTHING behind on timeout.
bp_kill_tree() {
	_bp_root="$1"; _bp_sig="$2"
	_bp_all="$_bp_root"
	_bp_frontier="$_bp_root"
	if command -v pgrep >/dev/null 2>&1; then
		while [ -n "$_bp_frontier" ]; do
			_bp_next=""
			for _bp_p in $_bp_frontier; do
				for _bp_c in $(pgrep -P "$_bp_p" 2>/dev/null); do
					_bp_all="$_bp_all $_bp_c"
					_bp_next="$_bp_next $_bp_c"
				done
			done
			_bp_frontier="$_bp_next"
		done
	fi
	# Reverse the breadth-first order -> deepest descendants first.
	_bp_rev=""
	for _bp_p in $_bp_all; do
		_bp_rev="$_bp_p $_bp_rev"
	done
	for _bp_p in $_bp_rev; do
		kill "-$_bp_sig" "$_bp_p" 2>/dev/null || true
	done
	unset _bp_root _bp_sig _bp_all _bp_frontier _bp_next _bp_p _bp_c _bp_rev
}

# --- execution engines -------------------------------------------------------
# Both engines set the shell globals _bp_rc (raw wait/timeout status) and write the
# literal token "timeout" to <flagfile> iff the run was terminated by OUR timeout.

# bp_uses_portable — return 0 when the portable watchdog should be used (no GNU
# timeout binary, or the caller forced it for deterministic testing).
bp_uses_portable() {
	[ "${SENTINEL_SHIELD_BP_FORCE_PORTABLE:-0}" = "1" ] && return 0
	if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

# _bp_portable_exec <timeout> <grace> <out> <err> <flag> -- <cmd...>
_bp_portable_exec() {
	_bp_to="$1"; _bp_grace="$2"; _bp_out="$3"; _bp_err="$4"; _bp_flag="$5"; shift 5
	[ "${1:-}" = "--" ] && shift
	: > "$_bp_flag"
	_bp_done="${_bp_flag}.done"
	rm -f "$_bp_done" 2>/dev/null || true

	"$@" >"$_bp_out" 2>"$_bp_err" &
	_bp_cmd_pid=$!

	# Watchdog: poll once per second up to <timeout>, then TERM the whole tree, wait a
	# bounded grace, then KILL. Runs in a subshell with errexit OFF so a benign kill
	# failure (the command already exited) can never abort it early. It also stands down
	# the instant the command completes (the parent touches <flag>.done), so it is never
	# killed by a signal — avoiding job-control "Terminated" noise on stderr.
	(
		set +e
		_wd_i=0
		while [ "$_wd_i" -lt "$_bp_to" ]; do
			[ -f "$_bp_done" ] && exit 0
			kill -0 "$_bp_cmd_pid" 2>/dev/null || exit 0
			sleep 1
			_wd_i=$((_wd_i + 1))
		done
		[ -f "$_bp_done" ] && exit 0
		kill -0 "$_bp_cmd_pid" 2>/dev/null || exit 0
		printf 'timeout' > "$_bp_flag"
		bp_kill_tree "$_bp_cmd_pid" TERM
		_wd_j=0
		while [ "$_wd_j" -lt "$_bp_grace" ]; do
			kill -0 "$_bp_cmd_pid" 2>/dev/null || exit 0
			sleep 1
			_wd_j=$((_wd_j + 1))
		done
		bp_kill_tree "$_bp_cmd_pid" KILL
	) &
	_bp_wd_pid=$!

	# The 2>/dev/null on wait swallows the shell's own job-control notice ("Killed: 9")
	# that some shells (bash-as-sh) emit for a signal-terminated job — the exit status is
	# still captured. The command's real stderr already went to "$_bp_err", not here.
	_bp_rc=0
	wait "$_bp_cmd_pid" 2>/dev/null || _bp_rc=$?

	# Signal the watchdog to stand down COOPERATIVELY (no kill -> no job-control noise),
	# then reap it. It notices the done-flag within its poll interval and exits 0.
	: > "$_bp_done"
	wait "$_bp_wd_pid" 2>/dev/null || true
	rm -f "$_bp_done" 2>/dev/null || true
	unset _bp_done
}

# _bp_gnu_exec <timeout> <grace> <out> <err> <flag> -- <cmd...>
_bp_gnu_exec() {
	_bp_to="$1"; _bp_grace="$2"; _bp_out="$3"; _bp_err="$4"; _bp_flag="$5"; shift 5
	[ "${1:-}" = "--" ] && shift
	: > "$_bp_flag"
	_bp_bin=timeout
	command -v timeout >/dev/null 2>&1 || _bp_bin=gtimeout
	_bp_rc=0
	"$_bp_bin" -k "${_bp_grace}s" -s TERM "${_bp_to}s" "$@" >"$_bp_out" 2>"$_bp_err" || _bp_rc=$?
	# GNU timeout signals 124 on the TERM-timeout. The classifier additionally treats a
	# signal-death (rc>128) whose wall-clock reached the limit as a timeout.
	if [ "$_bp_rc" -eq 124 ]; then printf 'timeout' > "$_bp_flag"; fi
	unset _bp_bin
}

# --- the entry point ---------------------------------------------------------
# bp_run <category> <timeout_seconds> <stdout_file> <stderr_file> [--] <cmd> [args...]
#
# Runs <cmd> under a bounded wall-clock timeout, capturing stdout/stderr to the given
# files. Sets the result globals and returns a distinct code:
#   BP_STATUS            success | failed | timed-out | unavailable | signalled
#   BP_EXIT_CODE         the preserved exit code (success/failed); empty otherwise
#   BP_SIGNAL            the signal number (signalled); empty otherwise
#   BP_TIMEOUT_SECONDS   the effective timeout applied
#   BP_DURATION_SECONDS  measured wall-clock seconds
#   BP_CATEGORY          the command category
#   BP_COMMAND           the executable BASENAME only (never args; safe to log)
#   BP_TIMED_OUT         1 iff timed out, else 0
# Return code: 0 (success) | preserved exit code (failed) | 128+signal (signalled) |
#   BP_RC_TIMEOUT (timed out) | BP_RC_UNAVAILABLE (executable missing) |
#   BP_RC_INVALID (invalid timeout).
bp_run() {
	[ "$#" -ge 5 ] || { log_error "bounded-process: bp_run needs <category> <timeout> <out> <err> [--] <cmd> [args...]"; return "$BP_RC_INVALID"; }
	_bp_category="$1"; _bp_to="$2"; _bp_out="$3"; _bp_err="$4"; shift 4
	[ "${1:-}" = "--" ] && shift
	[ "$#" -ge 1 ] || { log_error "bounded-process: bp_run has no command to run"; return "$BP_RC_INVALID"; }

	# Reset result globals so a caller never reads a stale value from a prior run.
	BP_CATEGORY="$_bp_category"; BP_TIMEOUT_SECONDS="$_bp_to"
	BP_STATUS=""; BP_EXIT_CODE=""; BP_SIGNAL=""; BP_DURATION_SECONDS="0"; BP_TIMED_OUT=0
	BP_COMMAND=$(basename -- "$1" 2>/dev/null) || BP_COMMAND="$1"

	# Validate the timeout FIRST (fail closed on zero/negative/nonnumeric/excessive).
	bp_validate_timeout "$_bp_to" || { BP_STATUS="invalid"; return "$BP_RC_INVALID"; }
	_bp_grace=$(bp_kill_grace)

	# Ensure capture files exist and are empty even on the earliest exit paths.
	: > "$_bp_out" 2>/dev/null || true
	: > "$_bp_err" 2>/dev/null || true

	# Availability: never launch a missing executable — report it distinctly.
	if ! command -v "$1" >/dev/null 2>&1; then
		BP_STATUS="unavailable"
		log_error "bounded-process: [$_bp_category] executable '$BP_COMMAND' not found on PATH (not launched)"
		return "$BP_RC_UNAVAILABLE"
	fi

	# Internal flag file marking an our-timeout termination. Always removed below.
	_bp_flag=$(mktemp 2>/dev/null || mktemp -t ssbp) || {
		log_error "bounded-process: cannot create a temp flag file"; BP_STATUS="invalid"; return "$BP_RC_INVALID"; }

	_bp_start=$(date +%s 2>/dev/null || echo 0)
	_bp_portable=0
	if bp_uses_portable; then
		_bp_portable=1
		_bp_portable_exec "$_bp_to" "$_bp_grace" "$_bp_out" "$_bp_err" "$_bp_flag" -- "$@"
	else
		_bp_gnu_exec "$_bp_to" "$_bp_grace" "$_bp_out" "$_bp_err" "$_bp_flag" -- "$@"
	fi
	_bp_end=$(date +%s 2>/dev/null || echo 0)
	BP_DURATION_SECONDS=$((_bp_end - _bp_start))
	[ "$BP_DURATION_SECONDS" -ge 0 ] 2>/dev/null || BP_DURATION_SECONDS=0

	# --- classify -------------------------------------------------------------
	_bp_timedout=0
	if [ -s "$_bp_flag" ]; then
		_bp_timedout=1
	elif [ "$_bp_portable" -eq 0 ] && [ "$_bp_rc" -gt 128 ] && [ "$BP_DURATION_SECONDS" -ge "$_bp_to" ]; then
		# GNU timeout that had to KILL (-k) reports a signal death at the deadline.
		_bp_timedout=1
	fi

	rm -f "$_bp_flag" 2>/dev/null || true

	if [ "$_bp_timedout" -eq 1 ]; then
		BP_STATUS="timed-out"; BP_TIMED_OUT=1; BP_EXIT_CODE=""; BP_SIGNAL=""
		log_warn "bounded-process: [$_bp_category] '$BP_COMMAND' exceeded ${_bp_to}s timeout — terminated (TERM->KILL)"
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout
		return "$BP_RC_TIMEOUT"
	fi
	if [ "$_bp_rc" -eq 0 ]; then
		BP_STATUS="success"; BP_EXIT_CODE=0; BP_SIGNAL=""
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout
		return 0
	fi
	if [ "$_bp_rc" -gt 128 ]; then
		BP_STATUS="signalled"; BP_SIGNAL=$((_bp_rc - 128)); BP_EXIT_CODE=""
		log_warn "bounded-process: [$_bp_category] '$BP_COMMAND' terminated by signal $BP_SIGNAL"
		_bp_ret="$_bp_rc"
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _bp_rc
		return "$_bp_ret"
	fi
	BP_STATUS="failed"; BP_EXIT_CODE="$_bp_rc"; BP_SIGNAL=""
	_bp_ret="$_bp_rc"
	unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _bp_rc
	return "$_bp_ret"
}

# --- machine-readable result -------------------------------------------------
# bp_result_json — emit ONE bounded-command-result object (schemas/bounded-command-result.schema.json)
# to STDOUT describing the LAST bp_run. Reads the BP_* globals. Requires jq for the
# rich object; without jq it emits a minimal but schema-conforming object. NEVER
# includes command arguments — only the executable basename (BP_COMMAND).
bp_result_json() {
	_bp_ec_json='null'
	case "$BP_STATUS" in
		success | failed) [ -n "${BP_EXIT_CODE:-}" ] && _bp_ec_json="$BP_EXIT_CODE" ;;
	esac
	_bp_sig_json='null'
	[ -n "${BP_SIGNAL:-}" ] && _bp_sig_json="$BP_SIGNAL"
	_bp_timedout_json=false
	[ "${BP_TIMED_OUT:-0}" = "1" ] && _bp_timedout_json=true

	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg command "${BP_COMMAND:-}" \
			--arg category "${BP_CATEGORY:-}" \
			--arg status "${BP_STATUS:-}" \
			--argjson exit_code "$_bp_ec_json" \
			--argjson signal "$_bp_sig_json" \
			--argjson timeout_seconds "${BP_TIMEOUT_SECONDS:-0}" \
			--argjson duration_seconds "${BP_DURATION_SECONDS:-0}" \
			--argjson timed_out "$_bp_timedout_json" \
			--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
			{
				schema: "bounded-command-result",
				command: $command,
				command_category: $category,
				status: $status,
				exit_code: $exit_code,
				signal: $signal,
				timeout_seconds: $timeout_seconds,
				duration_seconds: $duration_seconds,
				timed_out: $timed_out,
				timestamp: $timestamp
			}'
	else
		printf '{"schema":"bounded-command-result","command":"%s","command_category":"%s","status":"%s","exit_code":%s,"signal":%s,"timeout_seconds":%s,"duration_seconds":%s,"timed_out":%s,"timestamp":"%s"}\n' \
			"${BP_COMMAND:-}" "${BP_CATEGORY:-}" "${BP_STATUS:-}" "$_bp_ec_json" "$_bp_sig_json" \
			"${BP_TIMEOUT_SECONDS:-0}" "${BP_DURATION_SECONDS:-0}" "$_bp_timedout_json" \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	fi
	unset _bp_ec_json _bp_sig_json _bp_timedout_json
}

# bp_validate_result <path> — structural (jq-based) conformance check of a
# bounded-command-result JSON file against schemas/bounded-command-result.schema.json.
# Returns non-zero with a logged reason on any violation (fail closed). jq required.
bp_validate_result() {
	command_exists jq || { log_error "bp_validate_result: jq is required"; return 2; }
	[ -s "${1:-}" ] || { log_error "bp_validate_result: missing/empty file '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "bp_validate_result: invalid JSON in '$1'"; return 1; }
	jq -e '
		(.schema == "bounded-command-result") and
		(.command | type == "string") and
		(.command_category | type == "string" and (length > 0)) and
		(.status as $s | ["success","failed","timed-out","unavailable","signalled"] | index($s) != null) and
		(.timeout_seconds | type == "number" and (. > 0)) and
		(.duration_seconds | type == "number" and (. >= 0)) and
		(.timed_out | type == "boolean") and
		((.exit_code | type) as $et | ($et == "number" or $et == "null")) and
		((.signal | type) as $gt | ($gt == "number" or $gt == "null")) and
		(if .status == "timed-out"   then .exit_code == null and .timed_out == true else true end) and
		(if .status == "unavailable" then .exit_code == null else true end) and
		(if .status == "signalled"   then .exit_code == null and (.signal | type == "number") else true end) and
		(if .status == "success"     then .exit_code == 0 else true end)
	' "$1" >/dev/null 2>&1 || { log_error "bp_validate_result: '$1' does not conform to bounded-command-result.schema.json"; return 1; }
	return 0
}
