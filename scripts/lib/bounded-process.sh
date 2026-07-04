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
#     groups natively — it launches the command in a NEW process group and signals the
#     whole group), UNLESS SENTINEL_SHIELD_BP_FORCE_PORTABLE=1.
#   * Otherwise a PORTABLE watchdog is used. PRIMARY containment is PROCESS-GROUP
#     isolation, NOT descendant enumeration: the command is launched under POSIX job
#     control (`set -m`), which makes it a process-group LEADER (pgid == pid). On
#     timeout the watchdog signals the COMPLETE process group (kill -TERM -PGID, then a
#     bounded grace, then kill -KILL -PGID). This reaps children that fork, double-fork,
#     reparent to init, or ignore individual TERMs — anything that stays in the group.
#     Descendant enumeration (pgrep -P) is used ONLY as SECONDARY, best-effort cleanup.
#     On EVERY completion path a final group sweep guarantees no member outlives the
#     bounded command (e.g. a child that keeps running after its parent exits).
#   * PLATFORM CLASSIFICATION: process-group isolation is available wherever POSIX job
#     control is honored by /bin/sh (Linux dash/bash, macOS bash-as-sh, BSD sh). Where
#     `set -m` is NOT honored (a stripped shell without job control), isolation is
#     UNAVAILABLE; the wrapper then reports isolation="none", NEVER claims no_orphans,
#     and — if SENTINEL_SHIELD_BP_REQUIRE_ISOLATION=1 (production-required operations) —
#     FAILS CLOSED rather than launch an uncontainable process.
#
# OUTPUT CONTRACT (bp_result_json, schemas/bounded-command-result.schema.json)
#   { schema, command, command_category, status, exit_code, signal,
#     timeout_seconds, duration_seconds, timed_out,
#     isolation, descendant_cleanup, timeout_status, no_orphans, timestamp }
#   status is one of: success | failed | timed-out | unavailable | signalled.
#   exit_code is null on timed-out / unavailable / signalled; signal is the number on
#   signalled (else null). `command` is the executable BASENAME only — never args.
#   isolation is "process-group" (complete group containment established) or "none".
#   descendant_cleanup describes the reaping guarantee (complete | process-group-only |
#   descendant-enumeration | none). timeout_status is "timed-out" | "within-timeout".
#   no_orphans is true ONLY when process-group containment was actually established.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_BOUNDED_PROCESS_LOADED:-}" = "1" ]; then
	# shellcheck disable=SC2317  # reachable only when this file is re-sourced
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

# bp_env_name_ok <NAME> — return 0 iff <NAME> is a SAFE environment-variable identifier:
#   (a) it matches the strict shell-identifier form ^[A-Z][A-Z0-9_]*$, AND
#   (b) it lives inside the module's own, code-owned SENTINEL_SHIELD_ namespace.
# (a) is a CHARACTER ALLOWLIST: a conforming name cannot contain a single shell
# metacharacter — no '$', '`', '(', ')', '{', '}', ';', '|', '&', '<', '>', quote,
# backslash, space, tab, or newline — so it can NEVER carry a command substitution
# $(...), a backtick, a redirection, a delimiter, or any other injectable syntax.
# (b) rejects caller-controlled names outside the module's namespace (PATH, HOME, IFS,
# an attacker-chosen variable), so an untrusted string can be neither injected NOR used
# to read an arbitrary process variable. FAIL CLOSED: anything else is rejected.
BP_ENV_NAMESPACE_PREFIX='SENTINEL_SHIELD_'
bp_env_name_ok() {
	case "${1:-}" in
		'' | [!A-Z]*)  return 1 ;;   # empty, or first char not an uppercase letter
		*[!A-Z0-9_]*)  return 1 ;;   # any subsequent char outside [A-Z0-9_]
	esac
	# Confine to the code-owned namespace (the prefix is a literal, not a glob).
	case "$1" in
		"$BP_ENV_NAMESPACE_PREFIX"*) return 0 ;;
		*)                           return 1 ;;
	esac
}

# bp_env_get <NAME> — indirect read of an env var by name (POSIX, no bashisms).
# SECURITY: <NAME> is validated with bp_env_name_ok BEFORE it is ever placed in an eval.
# A name containing shell syntax (command substitution $(...), backticks, ';', '|', '&',
# whitespace, braces, quotes, or any delimiter) fails validation and is REJECTED — the
# function prints nothing and returns non-zero, and the injected content is NEVER
# executed. Because the accepted character set excludes every shell metacharacter, the
# subsequent eval of "${NAME:-}" is inert: it can only expand the named variable.
bp_env_get() {
	bp_env_name_ok "${1:-}" || return 1
	eval "printf '%s' \"\${$1:-}\""
}

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
	# 1. explicit per-call override env (e.g. scanner-specific). The override env NAME is
	#    caller-supplied, so it is validated as a safe, code-owned identifier BEFORE it is
	#    ever used for an indirect lookup. A malformed/hostile name (shell metacharacters,
	#    out-of-namespace) is REJECTED — FAIL CLOSED with BP_RC_INVALID, never silently
	#    ignored — so a broken/attacker-controlled config is loud and cannot inject.
	if [ -n "$_bp_over_env" ]; then
		if ! bp_env_name_ok "$_bp_over_env"; then
			log_error "bounded-process: override env name '$_bp_over_env' is not a valid ${BP_ENV_NAMESPACE_PREFIX}[A-Z0-9_]* identifier — rejected (fail closed)"
			unset _bp_cat _bp_over_env; return "$BP_RC_INVALID"
		fi
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

# --- process-group isolation -------------------------------------------------
# bp_have_ps — true if `ps` is available (used to VERIFY isolation, never trusted blindly).
bp_have_ps() { command -v ps >/dev/null 2>&1; }

# bp_pgid_of <pid> — print the process-group id of <pid> (empty on any failure). POSIX
# `ps -o pgid= -p <pid>`. Returns non-zero if ps is unavailable or the pid is gone.
bp_pgid_of() {
	bp_have_ps || return 1
	_bp_pg=$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' \t')
	[ -n "$_bp_pg" ] || { unset _bp_pg; return 1; }
	printf '%s' "$_bp_pg"
	unset _bp_pg
}

# bp_job_control_supported — return 0 iff POSIX job control (`set -m`) is honored by this
# shell, i.e. an async job would be placed in its OWN process group. Probed in a SUBSHELL
# so the caller's monitor-mode is never disturbed by the check itself.
bp_job_control_supported() {
	( set -m 2>/dev/null; case $- in *m*) exit 0 ;; *) exit 1 ;; esac )
}

# bp_isolation_available — 0 iff the portable path can establish process-group isolation:
# either perl is present (POSIX::setsid + exec runs the command in a NEW SESSION WITHOUT
# forking, so it stays a WAITABLE child with pgid == pid — works on dash/Linux AND macOS,
# unlike setsid(1) which detaches the process and unlike `set -m` which does not isolate
# under dash) or POSIX job control is honored (`set -m`, the fallback for shells with no
# perl). Used by the pre-launch fail-closed gate and by _bp_portable_exec.
bp_isolation_available() {
	command -v perl >/dev/null 2>&1 && return 0
	bp_job_control_supported
}

# bp_terminate <leader_pid> <isolated 0|1> <signal> — deliver <signal> to the command.
# PRIMARY: when isolation is established (<isolated>=1) signal the ENTIRE process group
# (kill -<sig> -<pgid>, pgid == leader_pid) so nothing in the group survives. SECONDARY:
# always sweep enumerated descendants (pgrep) as best-effort cleanup — and the ONLY
# mechanism when isolation was unavailable. Never signals a group when isolation is NOT
# established (that would risk striking the caller's own group). Always best-effort.
# bp_kill_pgroup_members <pgid> <signal> — signal EVERY process whose process-group id is
# <pgid>, addressed BY PID. `kill -<pgid>` alone is unreliable once the group LEADER has
# exited (observed on Linux: a group-directed signal no longer reaches surviving members of
# an orphaned group), so we enumerate members explicitly. Never signals this shell. Called
# only when isolation is established (the group is the command's own, never the caller's).
# Best-effort; `ps -Ao pid=,pgid=` is portable across procps (Linux) and BSD/macOS.
bp_kill_pgroup_members() {
	_bp_kg="$1"; _bp_ks="$2"
	bp_have_ps || { unset _bp_kg _bp_ks; return 0; }
	ps -Ao pid=,pgid= 2>/dev/null | while read -r _bp_kp _bp_kpg; do
		[ "$_bp_kpg" = "$_bp_kg" ] || continue
		[ "$_bp_kp" = "$$" ] && continue
		kill "-$_bp_ks" "$_bp_kp" 2>/dev/null || true
	done
	unset _bp_kg _bp_ks
}

bp_terminate() {
	_bp_tp="$1"; _bp_ti="$2"; _bp_tsig="$3"
	if [ "$_bp_ti" = 1 ]; then
		# PRIMARY: group-directed signal (works while the leader is alive). SECONDARY: kill
		# each group member by pid (robust when the leader has already exited — the final
		# containment sweep after a fast-exiting parent).
		kill "-$_bp_tsig" "-$_bp_tp" 2>/dev/null || true
		bp_kill_pgroup_members "$_bp_tp" "$_bp_tsig"
	fi
	bp_kill_tree "$_bp_tp" "$_bp_tsig"
	unset _bp_tp _bp_ti _bp_tsig
}

# --- execution engines -------------------------------------------------------
# Both engines set the shell globals _bp_rc (raw wait/timeout status) and write the
# literal token "timeout" to <flagfile> iff the run was terminated by OUR timeout.

# bp_uses_portable — return 0 when the portable watchdog should be used. Prefer it whenever
# perl is available: the perl-isolated path establishes a KNOWN process group and sweeps
# orphaned members on EVERY exit path (success or timeout), whereas GNU `timeout` group-kills
# ONLY on timeout — it leaks a child that outlives a fast-exiting parent (it never learns the
# command's pid/group). GNU timeout is the fallback only when perl is absent. Also selected
# when no timeout binary exists, or when the caller forces it for deterministic testing.
bp_uses_portable() {
	[ "${SENTINEL_SHIELD_BP_FORCE_PORTABLE:-0}" = "1" ] && return 0
	command -v perl >/dev/null 2>&1 && return 0
	if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
		return 1
	fi
	return 0
}

# _bp_portable_exec <timeout> <grace> <out> <err> <flag> -- <cmd...>
# Sets, in addition to _bp_rc: _BP_ISO_ESTABLISHED (1 iff process-group containment was
# established for this run, else 0) — bp_run maps it to the isolation/no_orphans fields.
_bp_portable_exec() {
	_bp_to="$1"; _bp_grace="$2"; _bp_out="$3"; _bp_err="$4"; _bp_flag="$5"; shift 5
	[ "${1:-}" = "--" ] && shift
	: > "$_bp_flag"
	_bp_done="${_bp_flag}.done"
	rm -f "$_bp_done" 2>/dev/null || true

	# PRIMARY containment = PROCESS-GROUP ISOLATION. Enable POSIX job control so the
	# command becomes a process-group LEADER (pgid == its own pid); a single group-
	# directed signal then reaps the COMPLETE tree. We probe support first, remember the
	# caller's monitor-mode, and restore it once both jobs are placed so the caller's
	# shell state is left exactly as we found it.
	# PRIMARY containment = PROCESS-GROUP ISOLATION. Prefer perl: POSIX::setsid() makes the
	# process a NEW SESSION LEADER (new process group, pgid == pid), then exec REPLACES perl
	# with the command in place — same pid, still a DIRECT CHILD we can wait(). Because the
	# backgrounded perl is not a process-group leader, setsid() never forks, so $! tracks the
	# command exactly. This works on dash (Linux CI /bin/sh), where `set -m` does NOT place
	# background jobs in their own group, AND on macOS — without setsid(1)'s detach (which
	# would make the process unwaitable). Fall back to POSIX job control (`set -m`) only when
	# perl is absent (bash-as-sh honors it non-interactively).
	_bp_jc=0
	_bp_pgrp=0
	_bp_wasm=1
	if command -v perl >/dev/null 2>&1; then
		_bp_pgrp=1
	else
		bp_job_control_supported && _bp_jc=1
		case $- in *m*) _bp_wasm=1 ;; *) _bp_wasm=0 ;; esac
		if [ "$_bp_jc" = 1 ]; then set -m 2>/dev/null || _bp_jc=0; fi
	fi

	if [ "$_bp_pgrp" = 1 ]; then
		perl -e 'use POSIX (); POSIX::setsid(); exec @ARGV or exit 127' "$@" >"$_bp_out" 2>"$_bp_err" &
		_bp_cmd_pid=$!
	else
		"$@" >"$_bp_out" 2>"$_bp_err" &
		_bp_cmd_pid=$!
	fi

	# CONFIRM the isolation actually took. The two mechanisms need different handling:
	#   * perl POSIX::setsid() places the command in its OWN new session/group BEFORE exec,
	#     deterministically (verified: the timeout path group-kills the whole tree). A ps
	#     LIVENESS probe here is unreliable — a fast-exiting leader is a ZOMBIE until we
	#     wait() it, and on Linux ps shows a zombie no pgid while kill -0 still succeeds, so
	#     a probe cannot tell "isolated but already exited" from "never isolated". Trust it.
	#   * `set -m` may or may not place the child in its own group, so CONFIRM (once — set -m
	#     isolates at fork, no race) that the child is a group leader NOT sharing ours before
	#     enabling any group-directed kill; otherwise fall back to descendant enumeration.
	_bp_iso=0
	if [ "$_bp_pgrp" = 1 ]; then
		_bp_iso=1
	elif [ "$_bp_jc" = 1 ]; then
		_bp_iso=1
		if bp_have_ps; then
			_bp_cpg=$(bp_pgid_of "$_bp_cmd_pid" 2>/dev/null) || _bp_cpg=""
			_bp_spg=$(bp_pgid_of "$$" 2>/dev/null) || _bp_spg=""
			if [ -n "$_bp_cpg" ] && [ -n "$_bp_spg" ] && [ "$_bp_cpg" = "$_bp_spg" ]; then
				_bp_iso=0
			fi
		fi
	fi
	_BP_ISO_ESTABLISHED="$_bp_iso"

	# Watchdog: poll once per second up to <timeout>, then terminate the WHOLE process
	# group (primary) plus any enumerated descendants (secondary), escalating TERM ->
	# (bounded grace) -> KILL. Runs in a subshell with errexit OFF so a benign kill
	# failure (the command already exited) can never abort it early. It stands down the
	# instant the command completes (the parent touches <flag>.done), so it is never
	# killed by a signal — avoiding job-control "Terminated" noise on stderr. Because the
	# command is in its OWN process group, a group-kill can never strike the watchdog or
	# the caller (both live in different groups).
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
		bp_terminate "$_bp_cmd_pid" "$_bp_iso" TERM
		_wd_j=0
		while [ "$_wd_j" -lt "$_bp_grace" ]; do
			kill -0 "$_bp_cmd_pid" 2>/dev/null || break
			sleep 1
			_wd_j=$((_wd_j + 1))
		done
		bp_terminate "$_bp_cmd_pid" "$_bp_iso" KILL
	) &
	_bp_wd_pid=$!

	# Restore the caller's monitor-mode now that both async jobs are placed.
	if [ "$_bp_wasm" = 0 ]; then set +m 2>/dev/null || true; fi

	# The 2>/dev/null on wait swallows the shell's own job-control notice ("Killed: 9")
	# that some shells (bash-as-sh) emit for a signal-terminated job — the exit status is
	# still captured. The command's real stderr already went to "$_bp_err", not here.
	_bp_rc=0
	wait "$_bp_cmd_pid" 2>/dev/null || _bp_rc=$?

	# Signal the watchdog to stand down COOPERATIVELY (no kill -> no job-control noise),
	# then reap it. It notices the done-flag within its poll interval and exits 0.
	: > "$_bp_done"
	wait "$_bp_wd_pid" 2>/dev/null || true

	# FINAL CONTAINMENT SWEEP (completeness guarantee): the direct child has been reaped,
	# but a member it spawned may still be alive in the group (a child that keeps running
	# after its parent exited, a daemonized helper, a TERM-ignorer). When isolation is
	# established, empty the whole group unconditionally (TERM then KILL) so NOTHING
	# outlives the bounded command. Enumerated descendants are swept as secondary cleanup.
	if [ "$_bp_iso" = 1 ]; then
		bp_terminate "$_bp_cmd_pid" 1 TERM
		bp_terminate "$_bp_cmd_pid" 1 KILL
	else
		bp_kill_tree "$_bp_cmd_pid" KILL
	fi

	rm -f "$_bp_done" 2>/dev/null || true
	unset _bp_done _bp_jc _bp_pgrp _bp_wasm _bp_iso _bp_cpg _bp_spg
}

# _bp_gnu_exec <timeout> <grace> <out> <err> <flag> -- <cmd...>
_bp_gnu_exec() {
	_bp_to="$1"; _bp_grace="$2"; _bp_out="$3"; _bp_err="$4"; _bp_flag="$5"; shift 5
	[ "${1:-}" = "--" ] && shift
	: > "$_bp_flag"
	_bp_bin=timeout
	command -v timeout >/dev/null 2>&1 || _bp_bin=gtimeout
	_bp_rc=0
	# GNU timeout WITHOUT --foreground launches the command in a NEW process group and
	# signals the WHOLE group on timeout — so process-group containment is established.
	_BP_ISO_ESTABLISHED=1
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
#   BP_ISOLATION         "process-group" (complete group containment established) | "none"
#   BP_DESCENDANT_CLEANUP  complete | process-group-only | descendant-enumeration | none
#   BP_TIMEOUT_STATUS    "timed-out" | "within-timeout"
#   BP_NO_ORPHANS        1 ONLY when process-group containment was actually established
# Return code: 0 (success) | preserved exit code (failed) | 128+signal (signalled) |
#   BP_RC_TIMEOUT (timed out) | BP_RC_UNAVAILABLE (executable missing) |
#   BP_RC_INVALID (invalid timeout, or SENTINEL_SHIELD_BP_REQUIRE_ISOLATION=1 and
#   process-group isolation is unavailable — FAIL CLOSED, command NOT launched).
bp_run() {
	[ "$#" -ge 5 ] || { log_error "bounded-process: bp_run needs <category> <timeout> <out> <err> [--] <cmd> [args...]"; return "$BP_RC_INVALID"; }
	_bp_category="$1"; _bp_to="$2"; _bp_out="$3"; _bp_err="$4"; shift 4
	[ "${1:-}" = "--" ] && shift
	[ "$#" -ge 1 ] || { log_error "bounded-process: bp_run has no command to run"; return "$BP_RC_INVALID"; }

	# Reset result globals so a caller never reads a stale value from a prior run.
	BP_CATEGORY="$_bp_category"; BP_TIMEOUT_SECONDS="$_bp_to"
	BP_STATUS=""; BP_EXIT_CODE=""; BP_SIGNAL=""; BP_DURATION_SECONDS="0"; BP_TIMED_OUT=0
	BP_ISOLATION="none"; BP_DESCENDANT_CLEANUP="none"; BP_TIMEOUT_STATUS="within-timeout"; BP_NO_ORPHANS=0
	BP_COMMAND=$(basename -- "$1" 2>/dev/null) || BP_COMMAND="$1"
	_BP_ISO_ESTABLISHED=0

	# Validate the timeout FIRST (fail closed on zero/negative/nonnumeric/excessive).
	bp_validate_timeout "$_bp_to" || { BP_STATUS="invalid"; return "$BP_RC_INVALID"; }
	_bp_grace=$(bp_kill_grace)

	# Production-required operations may DEMAND complete process-group containment. When
	# SENTINEL_SHIELD_BP_REQUIRE_ISOLATION=1 and the portable path cannot establish it
	# (this shell does not honor POSIX job control), FAIL CLOSED — refuse to launch an
	# uncontainable process rather than risk leaking orphans. The GNU-timeout path always
	# provides process-group containment, so it is never blocked here.
	if [ "${SENTINEL_SHIELD_BP_REQUIRE_ISOLATION:-0}" = "1" ] && bp_uses_portable && ! bp_isolation_available; then
		BP_STATUS="isolation-unavailable"; BP_ISOLATION="none"; BP_NO_ORPHANS=0
		log_error "bounded-process: [$_bp_category] process-group isolation unavailable (no perl, no job control) and SENTINEL_SHIELD_BP_REQUIRE_ISOLATION=1 — refusing to launch (fail closed)"
		unset _bp_category _bp_to _bp_out _bp_err _bp_grace
		return "$BP_RC_INVALID"
	fi

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

	# --- containment reporting ------------------------------------------------
	# Report what containment was ACTUALLY established (never over-claim). Primary is
	# process-group isolation; descendant enumeration (pgrep) is only secondary cleanup.
	# no_orphans is asserted ONLY when process-group containment was established.
	if [ "${_BP_ISO_ESTABLISHED:-0}" = "1" ]; then
		BP_ISOLATION="process-group"; BP_NO_ORPHANS=1
		if command -v pgrep >/dev/null 2>&1; then
			BP_DESCENDANT_CLEANUP="complete"
		else
			BP_DESCENDANT_CLEANUP="process-group-only"
		fi
	else
		BP_ISOLATION="none"; BP_NO_ORPHANS=0
		if command -v pgrep >/dev/null 2>&1; then
			BP_DESCENDANT_CLEANUP="descendant-enumeration"
		else
			BP_DESCENDANT_CLEANUP="none"
		fi
	fi

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
		BP_STATUS="timed-out"; BP_TIMED_OUT=1; BP_TIMEOUT_STATUS="timed-out"; BP_EXIT_CODE=""; BP_SIGNAL=""
		log_warn "bounded-process: [$_bp_category] '$BP_COMMAND' exceeded ${_bp_to}s timeout — terminated (TERM->KILL), isolation=$BP_ISOLATION"
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _BP_ISO_ESTABLISHED
		return "$BP_RC_TIMEOUT"
	fi
	if [ "$_bp_rc" -eq 0 ]; then
		BP_STATUS="success"; BP_EXIT_CODE=0; BP_SIGNAL=""
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _BP_ISO_ESTABLISHED
		return 0
	fi
	if [ "$_bp_rc" -gt 128 ]; then
		BP_STATUS="signalled"; BP_SIGNAL=$((_bp_rc - 128)); BP_EXIT_CODE=""
		log_warn "bounded-process: [$_bp_category] '$BP_COMMAND' terminated by signal $BP_SIGNAL"
		_bp_ret="$_bp_rc"
		unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _bp_rc _BP_ISO_ESTABLISHED
		return "$_bp_ret"
	fi
	BP_STATUS="failed"; BP_EXIT_CODE="$_bp_rc"; BP_SIGNAL=""
	_bp_ret="$_bp_rc"
	unset _bp_category _bp_to _bp_grace _bp_flag _bp_start _bp_end _bp_portable _bp_timedout _bp_rc _BP_ISO_ESTABLISHED
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
	_bp_noorphans_json=false
	[ "${BP_NO_ORPHANS:-0}" = "1" ] && _bp_noorphans_json=true

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
			--arg isolation "${BP_ISOLATION:-none}" \
			--arg descendant_cleanup "${BP_DESCENDANT_CLEANUP:-none}" \
			--arg timeout_status "${BP_TIMEOUT_STATUS:-within-timeout}" \
			--argjson no_orphans "$_bp_noorphans_json" \
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
				isolation: $isolation,
				descendant_cleanup: $descendant_cleanup,
				timeout_status: $timeout_status,
				no_orphans: $no_orphans,
				timestamp: $timestamp
			}'
	else
		printf '{"schema":"bounded-command-result","command":"%s","command_category":"%s","status":"%s","exit_code":%s,"signal":%s,"timeout_seconds":%s,"duration_seconds":%s,"timed_out":%s,"isolation":"%s","descendant_cleanup":"%s","timeout_status":"%s","no_orphans":%s,"timestamp":"%s"}\n' \
			"${BP_COMMAND:-}" "${BP_CATEGORY:-}" "${BP_STATUS:-}" "$_bp_ec_json" "$_bp_sig_json" \
			"${BP_TIMEOUT_SECONDS:-0}" "${BP_DURATION_SECONDS:-0}" "$_bp_timedout_json" \
			"${BP_ISOLATION:-none}" "${BP_DESCENDANT_CLEANUP:-none}" "${BP_TIMEOUT_STATUS:-within-timeout}" \
			"$_bp_noorphans_json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	fi
	unset _bp_ec_json _bp_sig_json _bp_timedout_json _bp_noorphans_json
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
		(if .status == "success"     then .exit_code == 0 else true end) and
		(if has("isolation")          then (.isolation as $i | ["process-group","none"] | index($i) != null) else true end) and
		(if has("descendant_cleanup") then (.descendant_cleanup as $d | ["complete","process-group-only","descendant-enumeration","none"] | index($d) != null) else true end) and
		(if has("timeout_status")     then (.timeout_status as $t | ["timed-out","within-timeout"] | index($t) != null) else true end) and
		(if has("no_orphans")         then (.no_orphans | type == "boolean") else true end) and
		(if (has("timeout_status") and has("timed_out")) then ((.timeout_status == "timed-out") == .timed_out) else true end) and
		(if (.no_orphans == true) then (.isolation == "process-group") else true end)
	' "$1" >/dev/null 2>&1 || { log_error "bp_validate_result: '$1' does not conform to bounded-command-result.schema.json"; return 1; }
	return 0
}
