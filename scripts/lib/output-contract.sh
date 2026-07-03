#!/bin/sh
# Sentinel Shield — machine-readable command-result envelope (output contract).
#
# Source this file; do NOT execute it. It defines oc_* helper functions only and
# does not enable `set -eu` itself (the caller decides). POSIX sh only: no Bash
# arrays, no `local`, no `[[ ]]`, no process substitution.
#
# WHAT THIS PROVIDES
#   A single, uniform command-result envelope emitted to STDOUT as ONE JSON object:
#     { command, version, status, exit_category, reason_codes[],
#       warnings[], artifacts[], next_actions[], timestamp }
#   conforming to schemas/command-result.schema.json.
#
# HOW IT IS WIRED (opt-in, non-breaking)
#   A command sources this lib and calls, right after its own libs are sourced:
#       oc_intercept "<command-name>" "$0" "$@"
#   * Without a `--output json` flag: oc_intercept returns immediately and the
#     command runs EXACTLY as before (identical human output + exit code).
#   * With `--output json`: oc_intercept re-executes the SAME script (with the
#     flag stripped and $__SS_OC_WRAP=1 set) so the real command runs unchanged,
#     captures its stdout/stderr/exit-code, forwards the human text to STDERR,
#     and emits the envelope as the ONLY thing on STDOUT. The exit code is the
#     underlying command's exit code — never remapped.
#
#   Because the underlying command runs untouched in a child process, human
#   output and exit codes are provably unchanged; the envelope is a thin,
#   read-only translation layer over the child's result.
#
# REDACTION
#   Everything placed into the envelope passes through oc_redact, which:
#     * relativizes $HOME  -> ~
#     * relativizes the run's --target root (if any) -> <target>
#     * masks common secret shapes (AWS keys, GitHub tokens, JWTs, bearer
#       tokens, and NAME=VALUE pairs whose NAME ends in _KEY/_TOKEN/_SECRET/
#       _PASSWORD/_PASSWD/_PWD).
#   The envelope therefore carries no absolute local paths and no secret values.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_OUTPUT_CONTRACT_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_OUTPUT_CONTRACT_LOADED=1

# oc_version — the engine version the envelope reports.
oc_version() { printf '%s' "${SENTINEL_SHIELD_VERSION:-2.0.0}"; }

# oc_redact — read STDIN, write STDIN with secrets + absolute local paths redacted.
# OC_TARGET_ROOT and OC_HOME (exported by oc_run_wrapped) drive path relativization.
oc_redact() {
	# Longest / most specific replacements first (TARGET before HOME so a target
	# nested under HOME is labelled <target>, not ~/...). Escape ERE metacharacters
	# and the '#' delimiter in the roots first: an unescaped root containing '.',
	# '+', '(' … or '#' could fail to match and leak the absolute path.
	_oc_home="${OC_HOME:-$HOME}"
	_oc_troot=$(printf '%s' "${OC_TARGET_ROOT:-}" | sed 's/[]#.^$*+?(){}|[]/\\&/g')
	_oc_home_e=$(printf '%s' "$_oc_home" | sed 's/[]#.^$*+?(){}|[]/\\&/g')
	sed -E \
		${OC_TARGET_ROOT:+-e "s#${_oc_troot}#<target>#g"} \
		${_oc_home:+-e "s#${_oc_home_e}#~#g"} \
		-e 's/(AKIA|ASIA)[0-9A-Z]{16}/***REDACTED-AWS-KEY***/g' \
		-e 's/gh[pousr]_[A-Za-z0-9]{20,}/***REDACTED-GH-TOKEN***/g' \
		-e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/***REDACTED-JWT***/g' \
		-e 's/([Bb]earer )[A-Za-z0-9._-]{12,}/\1***REDACTED***/g' \
		-e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD))[=:][[:space:]]*[^[:space:]"'\'']+/\1=***REDACTED***/g'
}

# oc_lines_to_json — turn a newline-delimited (already-redacted) list on STDIN into
# a JSON array of strings. Empty/blank lines are dropped; order is preserved.
oc_lines_to_json() {
	if command -v jq >/dev/null 2>&1; then
		jq -R -s 'split("\n") | map(select(length > 0))'
	else
		# jq-less fallback: emit an empty array (envelope stays valid JSON).
		printf '[]'
	fi
}

# oc_map <command> <rc> — map a command exit code to
#   "<status>\t<exit_category>\t<primary_reason_code>".
# status is one of ok|warn|error; exit_category is one of
#   success|warnings|invalid_input|requirements_unmet|execution_error|not_ready|findings.
oc_map() {
	case "$1:$2" in
		doctor:0)                    printf 'ok\tsuccess\thealthy' ;;
		doctor:1)                    printf 'warn\twarnings\tdegraded_conditions' ;;
		doctor:2)                    printf 'error\tinvalid_input\tconfig_invalid' ;;
		doctor:3)                    printf 'error\trequirements_unmet\trequired_tool_missing' ;;
		doctor:4)                    printf 'error\texecution_error\tevidence_or_exec_problem' ;;

		install-baseline:0)          printf 'ok\tsuccess\tcompleted' ;;
		install-baseline:1)          printf 'error\tfindings\trequired_tool_absent' ;;
		install-baseline:2)          printf 'error\tinvalid_input\tconfig_invalid' ;;
		install-baseline:3)          printf 'error\trequirements_unmet\trequired_tool_unavailable' ;;
		install-baseline:4)          printf 'error\texecution_error\tinterrupted_operation' ;;

		sync-baseline:0)             printf 'ok\tsuccess\tcompleted' ;;
		sync-baseline:2)             printf 'error\tinvalid_input\tconfig_invalid' ;;
		sync-baseline:4)             printf 'error\texecution_error\tinterrupted_operation' ;;

		plan-upgrade:0)              printf 'ok\tsuccess\tplan_produced' ;;
		plan-upgrade:2)              printf 'error\tinvalid_input\tinvalid_invocation' ;;

		bootstrap-profile-tools:0)   printf 'ok\tsuccess\tplan_or_install_ok' ;;
		bootstrap-profile-tools:1)   printf 'error\tfindings\tinstall_failed_rolled_back' ;;
		bootstrap-profile-tools:2)   printf 'error\tinvalid_input\tconfig_invalid' ;;
		bootstrap-profile-tools:3)   printf 'error\trequirements_unmet\trequired_tool_disabled_or_pm_missing' ;;
		bootstrap-profile-tools:4)   printf 'error\texecution_error\trollback_incomplete' ;;

		run-local-pipeline:0)        printf 'ok\tsuccess\tgate_passed' ;;
		run-local-pipeline:1)        printf 'error\tfindings\tgate_failed' ;;
		run-local-pipeline:2)        printf 'error\tinvalid_input\tconfig_invalid' ;;
		run-local-pipeline:3)        printf 'error\trequirements_unmet\trequired_tool_unavailable' ;;
		run-local-pipeline:4)        printf 'error\texecution_error\texecution_error' ;;

		check-release-readiness:0)   printf 'ok\tsuccess\tready' ;;
		check-release-readiness:1)   printf 'error\tnot_ready\tgates_unmet' ;;
		check-release-readiness:2)   printf 'error\tinvalid_input\tinvalid_or_malformed' ;;

		*:0)                         printf 'ok\tsuccess\tcompleted' ;;
		*)                           printf 'error\texecution_error\tunexpected_exit_%s' "$2" ;;
	esac
}

# oc_extract_warnings <stdout-file> <stderr-file> — print each user-facing warning
# (one per line, NOT yet redacted). Recognizes the two stable markers used across
# the CLI: the log_warn stderr prefix `[sentinel-shield][warn]` and the aligned
# `  WARN  ` lines emitted by doctor / check-release-readiness.
oc_extract_warnings() {
	{ cat "$1" 2>/dev/null; cat "$2" 2>/dev/null; } \
		| grep -E '(\[sentinel-shield\]\[warn\]|^[[:space:]]*WARN[[:space:]])' 2>/dev/null \
		| sed -E 's/^\[sentinel-shield\]\[warn\] //; s/^[[:space:]]*WARN[[:space:]]+//' \
		| sed -E 's/[[:space:]]+$//'
}

# oc_extract_artifacts <stdout-file> <stderr-file> — print the paths of files the
# command reported writing (one per line, NOT yet redacted). Recognizes the stable
# `wrote <path>` phrasing used by the reporters (log_info "wrote ..." / "wrote
# <fmt> report to <path>"): the path is the last whitespace field of such a line.
oc_extract_artifacts() {
	{ cat "$1" 2>/dev/null; cat "$2" 2>/dev/null; } \
		| grep -E '(^|[[:space:]])wrote[[:space:]]' 2>/dev/null \
		| sed -E 's/.*[[:space:]]([^[:space:]]+)[[:space:]]*$/\1/' \
		| sed -E 's/[.,;:]+$//'
}

# oc_extract_next_actions <stdout-file> <stderr-file> — print user-facing next-step
# guidance (one per line, NOT yet redacted). Recognizes doctor's `Next:` line and
# the imperative advisory lines emitted by the CLI (`To ...`, `Re-run with ...`).
oc_extract_next_actions() {
	{ cat "$1" 2>/dev/null; cat "$2" 2>/dev/null; } \
		| grep -E '(^Next:|^[[:space:]]*To [A-Za-z]|Re-run with)' 2>/dev/null \
		| sed -E 's/^Next:[[:space:]]*//; s/^[[:space:]]+//' \
		| sed -E 's/[[:space:]]+$//'
}

# oc_emit_envelope — build and print the envelope JSON to STDOUT (fd1).
# Args: <command> <status> <exit_category> <primary_reason>
#       <warnings-newline-list> <artifacts-newline-list> <next-actions-newline-list>
#       <has_failures:0|1>
oc_emit_envelope() {
	_oc_command="$1"; _oc_status="$2"; _oc_category="$3"; _oc_primary="$4"
	_oc_warns="$5"; _oc_arts="$6"; _oc_next="$7"; _oc_hasfail="$8"

	_oc_warns_json=$(printf '%s' "$_oc_warns" | oc_lines_to_json)
	_oc_arts_json=$(printf '%s' "$_oc_arts" | oc_lines_to_json)
	_oc_next_json=$(printf '%s' "$_oc_next" | oc_lines_to_json)

	# reason_codes: the primary code, plus derived signals.
	_oc_reasons="$_oc_primary"
	[ -n "$_oc_warns" ] && _oc_reasons="$_oc_reasons
has_warnings"
	[ "$_oc_hasfail" = 1 ] && _oc_reasons="$_oc_reasons
has_failures"
	_oc_reasons_json=$(printf '%s' "$_oc_reasons" | oc_lines_to_json)

	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg command "$_oc_command" \
			--arg version "$(oc_version)" \
			--arg status "$_oc_status" \
			--arg exit_category "$_oc_category" \
			--argjson reason_codes "$_oc_reasons_json" \
			--argjson warnings "$_oc_warns_json" \
			--argjson artifacts "$_oc_arts_json" \
			--argjson next_actions "$_oc_next_json" \
			--arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
			'{
				command: $command,
				version: $version,
				status: $status,
				exit_category: $exit_category,
				reason_codes: $reason_codes,
				warnings: $warnings,
				artifacts: $artifacts,
				next_actions: $next_actions,
				timestamp: $timestamp
			}'
	else
		# jq-less minimal envelope (scalar fields only; arrays empty). Still valid,
		# schema-conforming JSON so a machine consumer never sees a broken object.
		printf '{"command":"%s","version":"%s","status":"%s","exit_category":"%s","reason_codes":["%s"],"warnings":[],"artifacts":[],"next_actions":[],"timestamp":"%s"}\n' \
			"$_oc_command" "$(oc_version)" "$_oc_status" "$_oc_category" "$_oc_primary" \
			"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	fi
}

# oc_run_wrapped <command> <self> <target> <argv...> — run the underlying command
# in a child (with the envelope flag already stripped), capture its result, emit
# the envelope on STDOUT, forward the human output to STDERR, return the child rc.
oc_run_wrapped() {
	_oc_command="$1"; _oc_self="$2"; _oc_target="$3"; shift 3

	# Relativization roots for redaction.
	OC_HOME="$HOME"
	if [ -n "$_oc_target" ] && [ -d "$_oc_target" ]; then
		OC_TARGET_ROOT=$(CDPATH= cd -- "$_oc_target" 2>/dev/null && pwd) || OC_TARGET_ROOT="$_oc_target"
	else
		OC_TARGET_ROOT="$_oc_target"
	fi
	export OC_HOME OC_TARGET_ROOT

	_oc_out=$(mktemp 2>/dev/null || mktemp -t ssoc_out)
	_oc_err=$(mktemp 2>/dev/null || mktemp -t ssoc_err)

	_oc_rc=0
	__SS_OC_WRAP=1 sh "$_oc_self" "$@" >"$_oc_out" 2>"$_oc_err" || _oc_rc=$?

	# Forward the untouched human output to the real STDERR so the operator still
	# sees it; STDOUT is reserved exclusively for the envelope.
	cat "$_oc_out" >&2 2>/dev/null || true
	cat "$_oc_err" >&2 2>/dev/null || true

	# Derive envelope fields.
	_oc_triplet=$(oc_map "$_oc_command" "$_oc_rc")
	_oc_status=$(printf '%s' "$_oc_triplet" | cut -f1)
	_oc_category=$(printf '%s' "$_oc_triplet" | cut -f2)
	_oc_primary=$(printf '%s' "$_oc_triplet" | cut -f3)

	_oc_warns=$(oc_extract_warnings "$_oc_out" "$_oc_err" | oc_redact)
	_oc_arts=$(oc_extract_artifacts "$_oc_out" "$_oc_err" | oc_redact)
	_oc_next=$(oc_extract_next_actions "$_oc_out" "$_oc_err" | oc_redact)
	_oc_hasfail=0
	if { cat "$_oc_out" "$_oc_err" 2>/dev/null; } | grep -Eq '(^[[:space:]]*FAIL[[:space:]]|\[sentinel-shield\]\[error\])'; then
		_oc_hasfail=1
	fi

	oc_emit_envelope "$_oc_command" "$_oc_status" "$_oc_category" "$_oc_primary" \
		"$_oc_warns" "$_oc_arts" "$_oc_next" "$_oc_hasfail"

	rm -f "$_oc_out" "$_oc_err" 2>/dev/null || true
	return "$_oc_rc"
}

# oc_intercept <command-name> <self:$0> <argv...> — the single entry point a command
# calls. A no-op unless `--output json` is present (and we are not already the inner
# wrapped run). See the header for the full contract.
oc_intercept() {
	[ "${__SS_OC_WRAP:-}" = "1" ] && return 0
	_oc_cmd="$1"; _oc_self="$2"; shift 2

	# Detect an adjacent `--output json` pair.
	_oc_found=0; _oc_prev=""
	for _oc_a in "$@"; do
		if [ "$_oc_prev" = "--output" ] && [ "$_oc_a" = "json" ]; then _oc_found=1; break; fi
		_oc_prev="$_oc_a"
	done
	[ "$_oc_found" = 1 ] || return 0

	# Rebuild the argv WITHOUT the `--output json` pair, capturing --target for
	# redaction. Exactly one shift per original arg; kept args rotate to the back.
	_oc_target=""
	_oc_count=$#; _oc_i=0; _oc_skip=0
	while [ "$_oc_i" -lt "$_oc_count" ]; do
		_oc_i=$((_oc_i + 1))
		_oc_arg="$1"; shift
		if [ "$_oc_skip" = 1 ]; then _oc_skip=0; continue; fi
		if [ "$_oc_arg" = "--output" ] && [ "${1:-}" = "json" ]; then _oc_skip=1; continue; fi
		if [ "$_oc_arg" = "--target" ]; then _oc_target="${1:-}"; fi
		set -- "$@" "$_oc_arg"
	done

	oc_run_wrapped "$_oc_cmd" "$_oc_self" "$_oc_target" "$@"
	exit $?
}
