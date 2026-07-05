#!/bin/sh
# Sentinel Shield — compatibility & support-policy library (POSIX sh).
#
# Source this file; do not execute it. It READS config/compatibility-policy.json
# (schemas/compatibility-policy.schema.json) and classifies a host environment
# against the supported/tested/unsupported matrix. It NEVER mutates anything and
# carries no secrets. It is the shared engine behind:
#   * scripts/health.sh  — fail-closed compatibility GATE (strict).
#   * scripts/doctor.sh   — supportability report (non-strict).
#
# Requires the shared library FIRST (for log_*/command_exists) and jq:
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/compatibility-policy.sh"
#
# CLASSIFICATION contract (stable tokens):
#   enum components (os/arch/shell):   supported | unsupported | unknown
#   version components (git/jq/docker/php/node/npm/pnpm/yarn/composer):
#                                      supported | below-minimum | unsupported | unknown
# Every FAIL diagnostic carries: status=<token>; reason=<policy expected_failure_reason>;
# suite=<policy validation_suite> — a stable diagnostic, never an incidental error.
#
# ENVIRONMENT SNAPSHOT (read by cp_evaluate; set by cp_detect_into_env or by a caller/test):
#   CP_ENV_OS CP_ENV_ARCH CP_ENV_SHELL
#   CP_ENV_GIT_VERSION CP_ENV_JQ_VERSION
#   CP_ENV_DOCKER_PRESENT(yes|no) CP_ENV_DOCKER_VERSION CP_ENV_DOCKER_PROFILE(optional|required)
#   CP_ENV_PHP_VERSION CP_ENV_NODE_VERSION
#   CP_ENV_NPM_VERSION CP_ENV_PNPM_VERSION CP_ENV_YARN_VERSION CP_ENV_COMPOSER_VERSION
#   CP_ENV_FS_CASE(sensitive|insensitive|unknown)
#   CP_ENV_NETWORK(online|offline|unknown) CP_ENV_ONLINE_ONLY(yes|no)
# Any SENTINEL_SHIELD_COMPAT_* override (see cp_detect_into_env) wins over live detection,
# which is how tests inject a deterministic environment without touching the host.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_COMPAT_POLICY_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_COMPAT_POLICY_LOADED=1

# Result accumulators (reset by cp_reset_counters / cp_evaluate).
CP_OK=0
CP_WARN=0
CP_FAIL=0
CP_PROBE_TIMEOUT=0

cp_reset_counters() { CP_OK=0; CP_WARN=0; CP_FAIL=0; }

# Emit helpers: a stable, greppable line format. ok lines honour CP_QUIET.
cp__ok()   { CP_OK=$((CP_OK + 1)); [ "${CP_QUIET:-0}" = 1 ] || printf '  ok    [compat:%s] %s\n' "$1" "$2"; }
cp__warn() { CP_WARN=$((CP_WARN + 1)); printf '  WARN  [compat:%s] %s\n' "$1" "$2"; }
cp__fail() { CP_FAIL=$((CP_FAIL + 1)); printf '  FAIL  [compat:%s] %s\n' "$1" "$2"; }

# --- policy validation -------------------------------------------------------
# cp_validate_policy <path> — fail-closed structural conformance to
# schemas/compatibility-policy.schema.json (jq, not ajv — this repo has no JSON
# Schema validator). Missing / empty / malformed / non-conformant => non-zero.
cp_validate_policy() {
	command_exists jq || { log_error "cp_validate_policy: jq is required"; return 2; }
	[ -n "${1:-}" ] && [ -s "$1" ] || { log_error "cp_validate_policy: missing/empty policy '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "cp_validate_policy: invalid JSON in '$1'"; return 1; }
	jq -e '
		. as $d
		| (.schema_version == "1")
		and (.policy_version | type == "string" and (test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))
		and (.updated | type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))
		and (.components | type == "object")
		and (["os","arch","shell","git","jq","docker","php","node","npm","pnpm","yarn","composer"]
			| all(. as $k | ($d.components | has($k))))
		and (.components | to_entries | all(
			(.value.kind | . == "enum" or . == "version")
			and (.value.mandatory | type == "boolean")
			and (.value.expected_failure_reason | type == "string" and (length > 0))
			and (.value.validation_suite | type == "string" and (length > 0))
			and (if .value.kind == "enum"
				then (.value.supported | type == "array" and (length > 0)) and (.value.tested | type == "array")
				else (.value.minimum | type == "string") and (.value.tested | type == "array" and (length > 0)) end)
		))
		and (.filesystem.case_sensitivity.case_insensitive_action | . == "warn" or . == "fail")
		and (.filesystem.case_sensitivity.reason | type == "string" and (length > 0))
		and (.network.expected_failure_reason | type == "string" and (length > 0))
		and (.network.online_only_operations | type == "array" and (length > 0))
		and (.required_tools | type == "array" and (length > 0))
		and (.optional_tools | type == "array")
		and (.runner_images.supported | type == "array" and (length > 0))
		and (.runner_images.expected_failure_reason | type == "string" and (length > 0))
	' "$1" >/dev/null 2>&1 || { log_error "cp_validate_policy: '$1' does not conform to schemas/compatibility-policy.schema.json"; return 1; }
	return 0
}

# --- version helpers ---------------------------------------------------------
# cp_parse_version <raw> — extract the first dotted numeric version (MAJOR[.MINOR[.PATCH]])
# from a raw string (e.g. "git version 2.39.3", "jq-1.7.1", "v20.11.0"). Returns 1 if none.
cp_parse_version() {
	_cpv=$(printf '%s' "${1:-}" | grep -oE '[0-9]+(\.[0-9]+){0,2}' | head -n1)
	[ -n "$_cpv" ] || return 1
	printf '%s' "$_cpv"
}

# cp_ver_major <version> — first numeric field (0 if none).
cp_ver_major() {
	_m=$(printf '%s' "${1:-}" | cut -d. -f1)
	case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
	printf '%s' "$_m"
}

# cp_cmp_version <a> <b> — echo -1 (a<b), 0 (a==b) or 1 (a>b). Numeric per-field, up to 3.
cp_cmp_version() {
	_ca=$1; _cb=$2; _ci=1
	while [ "$_ci" -le 3 ]; do
		_af=$(printf '%s' "$_ca" | cut -d. -f"$_ci")
		_bf=$(printf '%s' "$_cb" | cut -d. -f"$_ci")
		case "$_af" in ''|*[!0-9]*) _af=0 ;; esac
		case "$_bf" in ''|*[!0-9]*) _bf=0 ;; esac
		if [ "$_af" -gt "$_bf" ]; then printf '1'; return 0; fi
		if [ "$_af" -lt "$_bf" ]; then printf -- '-1'; return 0; fi
		_ci=$((_ci + 1))
	done
	printf '0'
}

# cp__majors_contains <policy> <component> <field> <major> — true if the int array
# .components[component][field] contains <major>.
cp__majors_contains() {
	jq -e --arg c "$2" --arg f "$3" --arg m "$4" \
		'((.components[$c][$f]) // []) | map(tostring) | index($m) != null' "$1" >/dev/null 2>&1
}

# --- classification ----------------------------------------------------------
# cp_classify_version <policy> <component> <raw-version>
#   -> supported | below-minimum | unsupported | unknown
cp_classify_version() {
	_v=$(cp_parse_version "$3") || { printf 'unknown'; return 0; }
	_maj=$(cp_ver_major "$_v")
	if cp__majors_contains "$1" "$2" unsupported_majors "$_maj"; then printf 'unsupported'; return 0; fi
	_supcount=$(jq -r --arg c "$2" '((.components[$c].supported_majors) // []) | length' "$1" 2>/dev/null)
	case "$_supcount" in ''|*[!0-9]*) _supcount=0 ;; esac
	if [ "$_supcount" -gt 0 ]; then
		if cp__majors_contains "$1" "$2" supported_majors "$_maj"; then
			# A supported MAJOR may still carry a minimum WITHIN that major (e.g. major 8
			# supported, minimum 8.1). Enforce it before passing, else 8.0 would slip through.
			_minv=$(jq -r --arg c "$2" '.components[$c].minimum // ""' "$1" 2>/dev/null)
			if [ -n "$_minv" ] && [ "$_minv" != "null" ] && [ "$(cp_cmp_version "$_v" "$_minv")" = "-1" ]; then
				printf 'below-minimum'; return 0
			fi
			printf 'supported'; return 0
		fi
		_minmaj=$(jq -r --arg c "$2" '((.components[$c].supported_majors) // []) | min' "$1" 2>/dev/null)
		case "$_minmaj" in ''|*[!0-9]*) _minmaj=0 ;; esac
		if [ "$_maj" -lt "$_minmaj" ]; then printf 'below-minimum'; else printf 'unsupported'; fi
		return 0
	fi
	_minv=$(jq -r --arg c "$2" '.components[$c].minimum // ""' "$1" 2>/dev/null)
	if [ -n "$_minv" ] && [ "$_minv" != "null" ]; then
		if [ "$(cp_cmp_version "$_v" "$_minv")" = "-1" ]; then printf 'below-minimum'; return 0; fi
	fi
	printf 'supported'
}

# cp_classify_enum <policy> <component> <value> -> supported | unsupported | unknown
cp_classify_enum() {
	if jq -e --arg c "$2" --arg v "$3" '((.components[$c].unsupported) // []) | index($v) != null' "$1" >/dev/null 2>&1; then
		printf 'unsupported'; return 0
	fi
	if jq -e --arg c "$2" --arg v "$3" '((.components[$c].supported) // []) | index($v) != null' "$1" >/dev/null 2>&1; then
		printf 'supported'; return 0
	fi
	printf 'unknown'
}

# cp_reason <policy> <component> — the component's stable expected_failure_reason.
cp_reason() { jq -r --arg c "$2" '.components[$c].expected_failure_reason // "UNSUPPORTED"' "$1" 2>/dev/null; }
# cp_suite <policy> <component> — the component's responsible validation_suite.
cp_suite() { jq -r --arg c "$2" '.components[$c].validation_suite // "ci-compatibility.yml"' "$1" 2>/dev/null; }

# --- per-component evaluation ------------------------------------------------
# cp__eval_enum <policy> <strict> <component> <value> <mandatory 0|1>
cp__eval_enum() {
	_cls=$(cp_classify_enum "$1" "$3" "${4:-}")
	case "$_cls" in
		supported) cp__ok "$3" "'${4:-}' supported" ;;
		unsupported) cp__fail "$3" "'${4:-}' is unsupported (status=unsupported; reason=$(cp_reason "$1" "$3"); suite=$(cp_suite "$1" "$3"))" ;;
		unknown)
			if [ "$5" = 1 ] && [ "$2" = 1 ]; then
				cp__fail "$3" "'${4:-}' is not in the supported set and cannot be verified (status=unknown; reason=$(cp_reason "$1" "$3"); suite=$(cp_suite "$1" "$3"))"
			else
				cp__warn "$3" "'${4:-}' is not in the supported set — treat as unverified"
			fi ;;
	esac
}

# cp__eval_version <policy> <strict> <component> <version> <mandatory 0|1>
cp__eval_version() {
	if [ -z "${4:-}" ]; then
		if [ "$5" = 1 ]; then
			if [ "$2" = 1 ]; then
				cp__fail "$3" "required but no version detected (status=absent; reason=$(cp_reason "$1" "$3"); suite=$(cp_suite "$1" "$3"))"
			else
				cp__warn "$3" "not detected on host (required for engine operation)"
			fi
		else
			cp__ok "$3" "not in use (optional; no version detected)"
		fi
		return 0
	fi
	_cls=$(cp_classify_version "$1" "$3" "$4")
	case "$_cls" in
		supported) cp__ok "$3" "$4 supported" ;;
		below-minimum) cp__fail "$3" "$4 is below the supported minimum (status=below-minimum; reason=$(cp_reason "$1" "$3"); suite=$(cp_suite "$1" "$3"))" ;;
		unsupported) cp__fail "$3" "$4 is unsupported (status=unsupported; reason=$(cp_reason "$1" "$3"); suite=$(cp_suite "$1" "$3"))" ;;
		unknown)
			if [ "$5" = 1 ] && [ "$2" = 1 ]; then
				cp__fail "$3" "version '$4' is unparseable and cannot be verified (status=unknown; reason=$(cp_reason "$1" "$3"))"
			else
				cp__warn "$3" "version '$4' is unparseable — cannot verify"
			fi ;;
	esac
}

# cp__eval_docker <policy> <strict> — docker is optional unless CP_ENV_DOCKER_PROFILE=required.
cp__eval_docker() {
	_prof=${CP_ENV_DOCKER_PROFILE:-optional}
	_pres=${CP_ENV_DOCKER_PRESENT:-no}
	if [ "$_pres" != yes ]; then
		if [ "$_prof" = required ]; then
			_rr=$(jq -r '.components.docker.required_absent_reason // "DOCKER_REQUIRED_ABSENT"' "$1" 2>/dev/null)
			cp__fail docker "required by this operation/profile but Docker is not present (status=absent; reason=$_rr; suite=$(cp_suite "$1" docker))"
		else
			cp__ok docker "not present (optional profile — container-backed scanners are skipped)"
		fi
		return 0
	fi
	if [ -n "${CP_ENV_DOCKER_VERSION:-}" ]; then
		cp__eval_version "$1" "$2" docker "$CP_ENV_DOCKER_VERSION" 0
	elif [ "$_prof" = required ]; then
		# Required Docker whose version cannot be determined cannot prove the configured
		# minimum — fail closed rather than pass an unverifiable required component.
		cp__fail docker "required by this operation/profile but its version could not be determined — cannot prove the configured minimum (status=unverifiable; suite=$(cp_suite "$1" docker))"
	else
		cp__ok docker "present (version undetermined; optional profile)"
	fi
}

# cp__eval_fs <policy> — filesystem case-sensitivity assumption.
cp__eval_fs() {
	_case=${CP_ENV_FS_CASE:-unknown}
	_act=$(jq -r '.filesystem.case_sensitivity.case_insensitive_action // "warn"' "$1" 2>/dev/null)
	_rr=$(jq -r '.filesystem.case_sensitivity.reason // "CASE_INSENSITIVE_FS"' "$1" 2>/dev/null)
	case "$_case" in
		sensitive) cp__ok filesystem "case-sensitive filesystem" ;;
		insensitive)
			if [ "$_act" = fail ]; then
				cp__fail filesystem "case-insensitive filesystem (status=unsupported; reason=$_rr; suite=$(jq -r '.filesystem.validation_suite // "tests/prod/260-compatibility-policy.sh"' "$1" 2>/dev/null))"
			else
				cp__warn filesystem "case-insensitive filesystem — managed files use case-unique names (reason=$_rr)"
			fi ;;
		*) cp__ok filesystem "case-sensitivity not probed" ;;
	esac
}

# cp__eval_network <policy> — online-only operations require reachable network.
cp__eval_network() {
	_online_only=${CP_ENV_ONLINE_ONLY:-no}
	if [ "$_online_only" != yes ]; then
		cp__ok network "no online-only operation requested"
		return 0
	fi
	_net=${CP_ENV_NETWORK:-unknown}
	_rr=$(jq -r '.network.expected_failure_reason // "NETWORK_REQUIRED_OFFLINE"' "$1" 2>/dev/null)
	_su=$(jq -r '.network.validation_suite // "ci-compatibility.yml"' "$1" 2>/dev/null)
	case "$_net" in
		online) cp__ok network "network reachable for the online-only operation" ;;
		offline) cp__fail network "online-only operation requires network but the host is offline (status=unsupported; reason=$_rr; suite=$_su)" ;;
		*) cp__warn network "online-only operation requested but connectivity is unverified (reason=$_rr)" ;;
	esac
}

# cp_evaluate <policy> <strict 0|1> — evaluate the whole CP_ENV_* snapshot, printing
# one line per component and accumulating CP_OK/CP_WARN/CP_FAIL. Returns 0 (read counters).
# strict=1 (health): unknown mandatory components FAIL. strict=0 (doctor): they WARN.
cp_evaluate() {
	cp_reset_counters
	cp__eval_enum "$1" "$2" os "${CP_ENV_OS:-}" 1
	cp__eval_enum "$1" "$2" arch "${CP_ENV_ARCH:-}" 1
	cp__eval_enum "$1" "$2" shell "${CP_ENV_SHELL:-}" 1
	cp__eval_version "$1" "$2" git "${CP_ENV_GIT_VERSION:-}" 1
	cp__eval_version "$1" "$2" jq "${CP_ENV_JQ_VERSION:-}" 1
	cp__eval_docker "$1" "$2"
	cp__eval_version "$1" "$2" php "${CP_ENV_PHP_VERSION:-}" 0
	cp__eval_version "$1" "$2" node "${CP_ENV_NODE_VERSION:-}" 0
	cp__eval_version "$1" "$2" npm "${CP_ENV_NPM_VERSION:-}" 0
	cp__eval_version "$1" "$2" pnpm "${CP_ENV_PNPM_VERSION:-}" 0
	cp__eval_version "$1" "$2" yarn "${CP_ENV_YARN_VERSION:-}" 0
	cp__eval_version "$1" "$2" composer "${CP_ENV_COMPOSER_VERSION:-}" 0
	cp__eval_fs "$1"
	cp__eval_network "$1"
	return 0
}

# --- detection ---------------------------------------------------------------
# cp_bounded <seconds> <cmd...> — run a probe under a bounded timeout when a timeout
# tool is available; sets CP_PROBE_TIMEOUT=1 and returns 124 on timeout. Without a
# timeout tool it runs the command directly (version probes do not contact a daemon).
cp_bounded() {
	_lim=$1; shift
	if command_exists timeout; then
		timeout "$_lim" "$@"; _rc=$?
	elif command_exists gtimeout; then
		gtimeout "$_lim" "$@"; _rc=$?
	else
		"$@"; _rc=$?
	fi
	# CP_PROBE_TIMEOUT is read by the caller (scripts/health.sh) to distinguish an
	# unverifiable probe from a clean result; shellcheck cannot see that cross-file read.
	# shellcheck disable=SC2034
	[ "$_rc" = 124 ] && CP_PROBE_TIMEOUT=1
	return "$_rc"
}

cp_detect_os() {
	_os_u=$(uname -s 2>/dev/null) || _os_u=""
	case "$_os_u" in
		Linux) printf 'linux' ;;
		Darwin) printf 'macos' ;;
		MINGW*|MSYS*|CYGWIN*|Windows_NT) printf 'windows' ;;
		*) printf '%s' "$_os_u" | tr '[:upper:]' '[:lower:]' ;;
	esac
}

cp_detect_arch() {
	_arch_u=$(uname -m 2>/dev/null) || _arch_u=""
	case "$_arch_u" in
		x86_64|amd64) printf 'x86_64' ;;
		arm64|aarch64) printf 'arm64' ;;
		*) printf '%s' "$_arch_u" | tr '[:upper:]' '[:lower:]' ;;
	esac
}

cp_detect_shell() {
	if [ -n "${ZSH_VERSION:-}" ]; then printf 'zsh'
	elif [ -n "${BASH_VERSION:-}" ]; then printf 'bash'
	else printf 'sh'; fi
}

# cp_detect_tool_version <tool> — print the parsed version of <tool> --version, or
# nothing if the tool is absent / errors / the output has no version. Bounded.
cp_detect_tool_version() {
	command_exists "$1" || return 0
	# cp_bounded runs inside $(), a SUBSHELL — any CP_PROBE_TIMEOUT it sets there is lost. Its
	# EXIT CODE does propagate through $(), so detect the timeout (124) here and raise the flag
	# in THIS shell, otherwise a wedged probe would never surface as the caller's exit 4.
	_out=$(cp_bounded 5 "$1" --version 2>/dev/null); _brc=$?
	if [ "$_brc" = 124 ]; then
		# shellcheck disable=SC2034
		CP_PROBE_TIMEOUT=1
		return 0
	fi
	[ "$_brc" -eq 0 ] || return 0
	_pv=$(cp_parse_version "$_out") || return 0
	printf '%s' "$_pv"
}

# cp_detect_fs_case — print sensitive|insensitive|unknown by probing TMPDIR.
cp_detect_fs_case() {
	_d=${TMPDIR:-/tmp}
	_probe=$(mktemp -d "${_d%/}/ss-fscase.XXXXXX" 2>/dev/null) || { printf 'unknown'; return 0; }
	_res=unknown
	if : > "$_probe/casefile" 2>/dev/null; then
		if [ -e "$_probe/CASEFILE" ]; then _res=insensitive; else _res=sensitive; fi
	fi
	rm -rf "$_probe" 2>/dev/null
	printf '%s' "$_res"
}

# cp_detect_into_env — populate the CP_ENV_* snapshot from live detection, letting
# any SENTINEL_SHIELD_COMPAT_* override win. CP_ENV_DOCKER_PROFILE / CP_ENV_ONLINE_ONLY
# may be pre-set by the caller (e.g. health.sh --docker required / --require-network);
# those are preserved.
cp_detect_into_env() {
	CP_ENV_OS=${SENTINEL_SHIELD_COMPAT_OS:-$(cp_detect_os)}
	CP_ENV_ARCH=${SENTINEL_SHIELD_COMPAT_ARCH:-$(cp_detect_arch)}
	CP_ENV_SHELL=${SENTINEL_SHIELD_COMPAT_SHELL:-$(cp_detect_shell)}
	CP_ENV_GIT_VERSION=${SENTINEL_SHIELD_COMPAT_GIT_VERSION:-$(cp_detect_tool_version git)}
	CP_ENV_JQ_VERSION=${SENTINEL_SHIELD_COMPAT_JQ_VERSION:-$(cp_detect_tool_version jq)}
	CP_ENV_PHP_VERSION=${SENTINEL_SHIELD_COMPAT_PHP_VERSION:-$(cp_detect_tool_version php)}
	CP_ENV_NODE_VERSION=${SENTINEL_SHIELD_COMPAT_NODE_VERSION:-$(cp_detect_tool_version node)}
	CP_ENV_NPM_VERSION=${SENTINEL_SHIELD_COMPAT_NPM_VERSION:-$(cp_detect_tool_version npm)}
	CP_ENV_PNPM_VERSION=${SENTINEL_SHIELD_COMPAT_PNPM_VERSION:-$(cp_detect_tool_version pnpm)}
	CP_ENV_YARN_VERSION=${SENTINEL_SHIELD_COMPAT_YARN_VERSION:-$(cp_detect_tool_version yarn)}
	CP_ENV_COMPOSER_VERSION=${SENTINEL_SHIELD_COMPAT_COMPOSER_VERSION:-$(cp_detect_tool_version composer)}
	if [ -n "${SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT:-}" ]; then
		CP_ENV_DOCKER_PRESENT=$SENTINEL_SHIELD_COMPAT_DOCKER_PRESENT
	elif command_exists docker; then
		CP_ENV_DOCKER_PRESENT=yes
	else
		CP_ENV_DOCKER_PRESENT=no
	fi
	CP_ENV_DOCKER_VERSION=${SENTINEL_SHIELD_COMPAT_DOCKER_VERSION:-$(cp_detect_tool_version docker)}
	CP_ENV_DOCKER_PROFILE=${CP_ENV_DOCKER_PROFILE:-${SENTINEL_SHIELD_COMPAT_DOCKER_PROFILE:-optional}}
	CP_ENV_FS_CASE=${SENTINEL_SHIELD_COMPAT_FS_CASE:-$(cp_detect_fs_case)}
	CP_ENV_NETWORK=${SENTINEL_SHIELD_COMPAT_NETWORK:-unknown}
	CP_ENV_ONLINE_ONLY=${CP_ENV_ONLINE_ONLY:-${SENTINEL_SHIELD_COMPAT_ONLINE_ONLY:-no}}
}
