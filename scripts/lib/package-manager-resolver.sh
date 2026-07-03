#!/bin/sh
# Sentinel Shield — Node package-manager authority resolver (POSIX sh library).
#
# Source this file; do not execute it. It INSPECTS a Node project and decides
# which package manager is AUTHORITATIVE for that project and which IMMUTABLE
# install command reproduces its committed lockfile. It NEVER mutates the project
# and NEVER switches the manager — resolution is read-only and deterministic.
#
# Requires the shared library to be sourced FIRST (for log_* / command_exists):
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/package-manager-resolver.sh"
# jq is used to read package.json's "packageManager" field when present.
#
# AUTHORITY MODEL (one manager, one lockfile):
#   pnpm-lock.yaml    => pnpm
#   yarn.lock         => yarn
#   package-lock.json => npm
# A consumer repo MUST commit exactly ONE authoritative lockfile. Two or more is
# ambiguous and REJECTED — the engine never guesses which is canonical.
#
# RESOLUTION PRECEDENCE for the chosen manager:
#   explicit override  >  package.json "packageManager"  >  the sole lockfile
# A PRESENT "packageManager" declaration is AUTHORITATIVE and VALIDATED: a malformed,
# unsupported, or out-of-policy declaration FAILS resolution — it is NEVER silently
# dropped so the sole lockfile can be selected against an explicit project intent.
# The chosen manager is then cross-checked against the present lockfile; any
# disagreement is a MANAGER_MISMATCH (the engine will not switch managers).
#
# pm_resolve emits ONE machine-readable TSV line and sets its exit status:
#   ok<TAB><manager><TAB><version><TAB><lockfile><TAB><immutable-command-id>   exit 0
#   error<TAB><REASON_CODE><TAB><message>                                      exit 2
# <version> is the declared version (e.g. 10.9.3) or '-' when none was declared.
# <immutable-command-id> is a FIXED identifier the caller maps to a fixed command
# TEMPLATE via pm_immutable_template — pm_resolve NEVER emits a shell command
# assembled from untrusted project content.
#
# Stable REASON_CODEs (contract; asserted by tests/prod/201-node-consumers.sh):
#   MULTIPLE_AUTHORITATIVE_LOCKFILES   — >1 authoritative lockfile committed
#   MANAGER_MISMATCH                   — chosen manager != the present lockfile,
#                                        or a CLI override conflicts with the declaration
#   MISSING_LOCKFILE                   — immutable mode, chosen manager has no lock
#   INVALID_MANAGER                    — CLI override value is not a known manager
#   MALFORMED_PACKAGE_JSON             — package.json exists but is not valid JSON
#   INVALID_PACKAGE_MANAGER_DECLARATION — packageManager present but not "name@version"
#   UNSUPPORTED_PACKAGE_MANAGER        — declared name is not npm|pnpm|yarn
#   INVALID_PACKAGE_MANAGER_VERSION    — declared version is not valid version syntax
#   UNSUPPORTED_PACKAGE_MANAGER_VERSION — version syntax valid but major out of policy

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_PM_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_PM_LOADED=1

# ============================================================================
# SUPPORTED-VERSION POLICY (machine-readable; documented in docs/node-react-validation.md)
# ============================================================================
# Accepted version syntax : MAJOR[.MINOR[.PATCH]] with an optional -prerelease tag; a
#                           Corepack integrity suffix (+sha…) is tolerated and ignored.
# Corepack requirement    : pnpm and modern yarn (>=2) are provisioned via Corepack (or a
#                           matching global install); npm ships with Node.
# Immutable install       : each manager maps to ONE fixed immutable command TEMPLATE, keyed
#                           by an <immutable-command-id> (see pm_immutable_template).
# Manager-specific policy : yarn CLASSIC (1.x) and yarn MODERN (>=2) are DISTINCT — classic
#                           reproduces a lockfile with `install --frozen-lockfile`, modern with
#                           `install --immutable`; they resolve to different command-ids.

# pm_supported_majors <manager> — print the SUPPORTED major versions (space-separated) for a
# manager, in ascending order. Returns 1 for an unknown manager.
pm_supported_majors() {
	case "$1" in
		npm) printf '8 9 10 11' ;;
		pnpm) printf '8 9 10' ;;
		yarn) printf '1 2 3 4' ;;
		*) return 1 ;;
	esac
}

# pm_requires_corepack <manager> — return 0 when the manager is normally provisioned via
# Corepack (pnpm, modern yarn) rather than shipped with Node (npm). Advisory/documentation.
pm_requires_corepack() {
	case "$1" in
		pnpm | yarn) return 0 ;;
		*) return 1 ;;
	esac
}

# pm_policy — print the full supported-version policy as machine-readable TSV, one row per
# manager: <manager><TAB><supported-majors><TAB><corepack(yes|no)><TAB><default-command-id>.
pm_policy() {
	for _pp_m in npm pnpm yarn; do
		_pp_cp=no
		pm_requires_corepack "$_pp_m" && _pp_cp=yes
		printf '%s\t%s\t%s\t%s\n' "$_pp_m" "$(pm_supported_majors "$_pp_m")" "$_pp_cp" "$(pm_immutable_command_id "$_pp_m")"
	done
}

# pm_lockfile_for <manager> — print the authoritative lockfile name for a manager.
pm_lockfile_for() {
	case "$1" in
		npm) printf 'package-lock.json' ;;
		pnpm) printf 'pnpm-lock.yaml' ;;
		yarn) printf 'yarn.lock' ;;
		*) return 1 ;;
	esac
}

# pm_is_known_manager <value> — true when value is npm|pnpm|yarn.
pm_is_known_manager() {
	case "$1" in
		npm | pnpm | yarn) return 0 ;;
		*) return 1 ;;
	esac
}

# pm_version_syntax_ok <version-core> — true when the version (integrity suffix already
# stripped) is MAJOR[.MINOR[.PATCH]] with an optional -prerelease tag. Empty/garbage fails.
pm_version_syntax_ok() {
	case "${1:-}" in
		"") return 1 ;;
	esac
	printf '%s' "$1" | grep -qE '^[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.]+)?$'
}

# pm_major_supported <manager> <major> — true when <major> is in the manager's supported set.
pm_major_supported() {
	_ms_list=$(pm_supported_majors "$1") || return 1
	for _ms_x in $_ms_list; do
		[ "$_ms_x" = "$2" ] && return 0
	done
	return 1
}

# pm_immutable_command_id <manager> [major] — print the FIXED immutable-command identifier for
# a manager. yarn distinguishes CLASSIC (major 1 -> yarn-classic-frozen) from MODERN
# (>=2 or unknown -> yarn-immutable). Returns 1 for an unknown manager.
pm_immutable_command_id() {
	case "$1" in
		npm) printf 'npm-ci' ;;
		pnpm) printf 'pnpm-frozen-lockfile' ;;
		yarn)
			case "${2:-}" in
				1) printf 'yarn-classic-frozen' ;;
				*) printf 'yarn-immutable' ;;
			esac ;;
		*) return 1 ;;
	esac
}

# pm_immutable_template <command-id> <dir> — map a FIXED command-id to its immutable install
# command TEMPLATE for <dir>. This is the ONLY place a command string is assembled, and it is
# built from the trusted command-id + <dir> ONLY — never from project-declared content.
pm_immutable_template() {
	case "$1" in
		npm-ci) printf 'npm --prefix %s ci' "$2" ;;
		pnpm-frozen-lockfile) printf 'pnpm --dir %s install --frozen-lockfile' "$2" ;;
		yarn-immutable) printf 'yarn --cwd %s install --immutable' "$2" ;;
		yarn-classic-frozen) printf 'yarn --cwd %s install --frozen-lockfile' "$2" ;;
		*) return 1 ;;
	esac
}

# pm_immutable_cmd <manager> <dir> [major] — BACKWARD-COMPATIBLE convenience wrapper that prints
# the immutable install command for a manager, resolving yarn classic vs modern by [major]
# (defaults to modern when the major is unknown). Prefer the <immutable-command-id> from
# pm_resolve + pm_immutable_template for new callers.
pm_immutable_cmd() {
	_ic_id=$(pm_immutable_command_id "$1" "${3:-}") || return 1
	pm_immutable_template "$_ic_id" "$2"
}

# pm_authoritative_lockfiles <target> — print the managers (one per line) whose
# authoritative lockfile is present in <target>, in a stable order.
pm_authoritative_lockfiles() {
	[ -f "$1/pnpm-lock.yaml" ] && printf 'pnpm\n'
	[ -f "$1/yarn.lock" ] && printf 'yarn\n'
	[ -f "$1/package-lock.json" ] && printf 'npm\n'
	return 0
}

# pm_classify_declaration <raw-value> — classify a RAW "packageManager" string value and print
# ONE TSV line: `ok<TAB>manager<TAB>version` for a supported declaration, or
# `error<TAB>REASON_CODE<TAB>message` for a present-but-invalid one. Always exits 0 (the caller
# reads the status field). A Corepack "name@version(+integrity)" is expected; anything with
# whitespace or shell/command-like characters is INVALID_PACKAGE_MANAGER_DECLARATION.
pm_classify_declaration() {
	_cd_raw=$1
	case "$_cd_raw" in
		"") printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager is empty\n'; return 0 ;;
	esac
	# Only a strict name@version(+integrity) alphabet is allowed; reject shell metacharacters,
	# whitespace, path separators, etc. outright.
	case "$_cd_raw" in
		*[!A-Za-z0-9@._+-]*)
			printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager contains illegal characters (expected name@version)\n'; return 0 ;;
	esac
	# Require exactly one '@', with a non-empty name and a non-empty version.
	case "$_cd_raw" in
		@*) printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager missing manager name (expected name@version)\n'; return 0 ;;
		*@*@*) printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager has multiple @ separators (expected name@version)\n'; return 0 ;;
		*@) printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager missing version (expected name@version)\n'; return 0 ;;
		*@*) ;;
		*) printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager must be name@version\n'; return 0 ;;
	esac
	_cd_name=${_cd_raw%%@*}
	_cd_ver=${_cd_raw#*@}
	_cd_ver_core=${_cd_ver%%+*} # strip an optional Corepack integrity suffix (+sha…)
	if ! pm_is_known_manager "$_cd_name"; then
		printf 'error\tUNSUPPORTED_PACKAGE_MANAGER\t%s is not one of npm|pnpm|yarn\n' "$_cd_name"; return 0
	fi
	if ! pm_version_syntax_ok "$_cd_ver_core"; then
		printf 'error\tINVALID_PACKAGE_MANAGER_VERSION\t%s@%s has invalid version syntax\n' "$_cd_name" "$_cd_ver"; return 0
	fi
	_cd_major=${_cd_ver_core%%.*}
	if ! pm_major_supported "$_cd_name" "$_cd_major"; then
		printf 'error\tUNSUPPORTED_PACKAGE_MANAGER_VERSION\t%s@%s major %s outside supported range (%s)\n' \
			"$_cd_name" "$_cd_ver" "$_cd_major" "$(pm_supported_majors "$_cd_name")"; return 0
	fi
	printf 'ok\t%s\t%s\n' "$_cd_name" "$_cd_ver"
	return 0
}

# pm_parse_declared <target> — read package.json's "packageManager" field and classify it.
# Prints ONE TSV line:
#   absent                                   — no package.json readable, no jq, or field absent
#   ok<TAB>manager<TAB>version               — present, supported
#   error<TAB>REASON_CODE<TAB>message        — present, invalid (stable reason code)
# A present-but-non-string value is INVALID_PACKAGE_MANAGER_DECLARATION; an unparseable
# package.json is MALFORMED_PACKAGE_JSON. Always exits 0 (status is in the printed line).
pm_parse_declared() {
	_pd_target="$1"
	# No package.json, or no jq to read it, means there is no declaration to honour.
	if [ ! -f "$_pd_target/package.json" ] || ! command_exists jq; then
		printf 'absent\n'; return 0
	fi
	# Distinguish "field absent" from "present but not a string" from "unparseable JSON".
	_pd_type=$(jq -r 'if has("packageManager") then (.packageManager | type) else "absent" end' \
		"$_pd_target/package.json" 2>/dev/null) || {
		printf 'error\tMALFORMED_PACKAGE_JSON\tpackage.json is not valid JSON\n'; return 0; }
	case "$_pd_type" in
		absent) printf 'absent\n'; return 0 ;;
		string) ;;
		*) printf 'error\tINVALID_PACKAGE_MANAGER_DECLARATION\tpackageManager must be a string (got %s)\n' "$_pd_type"; return 0 ;;
	esac
	_pd_raw=$(jq -r '.packageManager' "$_pd_target/package.json" 2>/dev/null || printf '')
	pm_classify_declaration "$_pd_raw"
}

# pm_resolve <target> <mode> [override] — resolve the authoritative manager.
#   mode: "immutable" (CI; a lockfile is REQUIRED) or "lenient" (advisory).
#   override: optional explicit manager (highest precedence).
# Prints one TSV line (see header) and returns 0 (ok) or 2 (error). Read-only.
pm_resolve() {
	_target="$1"
	_mode="$2"
	_override="${3:-}"

	# Reject an invalid explicit override up front (operator typo must fail loud).
	if [ -n "$_override" ] && ! pm_is_known_manager "$_override"; then
		printf 'error\tINVALID_MANAGER\toverride %s is not one of npm|pnpm|yarn\n' "$_override"
		return 2
	fi

	# Parse the package.json declaration FIRST. A PRESENT but invalid declaration is a HARD
	# failure — it is never silently ignored so a lockfile could be chosen against project intent.
	_decl=$(pm_parse_declared "$_target")
	_decl_status=$(printf '%s' "$_decl" | cut -f1)
	_declared=""
	_declared_ver=""
	case "$_decl_status" in
		error)
			printf '%s\n' "$_decl" # propagate the stable declaration reason code verbatim
			return 2 ;;
		ok)
			_declared=$(printf '%s' "$_decl" | cut -f2)
			_declared_ver=$(printf '%s' "$_decl" | cut -f3) ;;
		*) ;; # absent
	esac

	# A CLI override that contradicts a valid project declaration is a conflict — never silently
	# override an explicit declaration.
	if [ -n "$_override" ] && [ -n "$_declared" ] && [ "$_override" != "$_declared" ]; then
		printf 'error\tMANAGER_MISMATCH\tCLI override %s conflicts with package.json declaration %s\n' \
			"$_override" "$_declared"
		return 2
	fi

	# Collect present authoritative lockfiles.
	_present=$(pm_authoritative_lockfiles "$_target")
	_count=0
	if [ -n "$_present" ]; then
		_count=$(printf '%s\n' "$_present" | grep -c .)
	fi

	# More than one authoritative lockfile is ambiguous — never guess.
	if [ "$_count" -gt 1 ]; then
		_joined=$(printf '%s' "$_present" | tr '\n' ' ' | sed 's/ *$//')
		printf 'error\tMULTIPLE_AUTHORITATIVE_LOCKFILES\tpresent: %s — commit exactly one\n' "$_joined"
		return 2
	fi

	_sole=""
	[ "$_count" -eq 1 ] && _sole=$(printf '%s' "$_present" | tr -d '\n')

	# Precedence: override > declared > sole lockfile.
	_chosen=""
	_version="-"
	if [ -n "$_override" ]; then
		_chosen="$_override"
		# When the override matches the declaration, keep the declared version for the record.
		[ "$_override" = "$_declared" ] && _version="$_declared_ver"
	elif [ -n "$_declared" ]; then
		_chosen="$_declared"
		_version="$_declared_ver"
	elif [ -n "$_sole" ]; then
		_chosen="$_sole"
	fi

	# No signal at all.
	if [ -z "$_chosen" ]; then
		if [ "$_mode" = "immutable" ]; then
			printf 'error\tMISSING_LOCKFILE\tno lockfile and no packageManager to resolve authority\n'
			return 2
		fi
		_chosen="npm"
	fi

	# A present lockfile that disagrees with the chosen manager is a mismatch.
	if [ -n "$_sole" ] && [ "$_chosen" != "$_sole" ]; then
		printf 'error\tMANAGER_MISMATCH\tchosen %s but committed lockfile is %s(%s)\n' \
			"$_chosen" "$_sole" "$(pm_lockfile_for "$_sole")"
		return 2
	fi

	# Immutable mode requires the chosen manager's own lockfile to be present.
	if [ "$_mode" = "immutable" ] && [ -z "$_sole" ]; then
		printf 'error\tMISSING_LOCKFILE\t%s requires %s but it is not committed\n' \
			"$_chosen" "$(pm_lockfile_for "$_chosen")"
		return 2
	fi

	# Derive the immutable-command-id, using the declared major to pick yarn classic vs modern.
	_major=""
	if [ "$_version" != "-" ]; then
		_major=${_version%%+*}
		_major=${_major%%.*}
	fi
	printf 'ok\t%s\t%s\t%s\t%s\n' \
		"$_chosen" "$_version" "$(pm_lockfile_for "$_chosen")" "$(pm_immutable_command_id "$_chosen" "$_major")"
	return 0
}
