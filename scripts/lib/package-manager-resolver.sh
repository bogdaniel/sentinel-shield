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
# The chosen manager is then cross-checked against the present lockfile; any
# disagreement is a MANAGER_MISMATCH (the engine will not switch managers).
#
# pm_resolve emits ONE machine-readable TSV line and sets its exit status:
#   ok<TAB><manager><TAB><lockfile>              exit 0
#   error<TAB><REASON_CODE><TAB><message>        exit 2
# Stable REASON_CODEs (contract; asserted by tests/prod/201-node-consumers.sh):
#   MULTIPLE_AUTHORITATIVE_LOCKFILES  — >1 authoritative lockfile committed
#   MANAGER_MISMATCH                  — chosen manager != the present lockfile
#   MISSING_LOCKFILE                  — immutable mode, chosen manager has no lock
#   INVALID_MANAGER                   — override/declared value is not a known mgr

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_PM_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_PM_LOADED=1

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

# pm_authoritative_lockfiles <target> — print the managers (one per line) whose
# authoritative lockfile is present in <target>, in a stable order.
pm_authoritative_lockfiles() {
	[ -f "$1/pnpm-lock.yaml" ] && printf 'pnpm\n'
	[ -f "$1/yarn.lock" ] && printf 'yarn\n'
	[ -f "$1/package-lock.json" ] && printf 'npm\n'
	return 0
}

# pm_declared_manager <target> — print the manager named by package.json's
# "packageManager" field (the part before '@'), or empty. Requires jq; an invalid
# or absent value yields empty (npm's own tolerant behaviour).
pm_declared_manager() {
	_pm=""
	if [ -f "$1/package.json" ] && command_exists jq; then
		_pm=$(jq -r '(.packageManager // "") | split("@")[0]' "$1/package.json" 2>/dev/null || true)
	fi
	if pm_is_known_manager "$_pm"; then
		printf '%s' "$_pm"
	fi
	return 0
}

# pm_immutable_cmd <manager> <dir> — print the IMMUTABLE install command that
# reproduces the committed lockfile without altering it. These are the only
# install forms the engine will run in CI; it never falls back to a mutating
# install and never substitutes another manager.
pm_immutable_cmd() {
	case "$1" in
		npm) printf 'npm --prefix %s ci' "$2" ;;
		pnpm) printf 'pnpm --dir %s install --frozen-lockfile' "$2" ;;
		yarn) printf 'yarn --cwd %s install --immutable' "$2" ;;
		*) return 1 ;;
	esac
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

	_declared=$(pm_declared_manager "$_target")
	_sole=""
	[ "$_count" -eq 1 ] && _sole=$(printf '%s' "$_present" | tr -d '\n')

	# Precedence: override > declared > sole lockfile.
	_chosen=""
	if [ -n "$_override" ]; then
		_chosen="$_override"
	elif [ -n "$_declared" ]; then
		_chosen="$_declared"
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

	printf 'ok\t%s\t%s\n' "$_chosen" "$(pm_lockfile_for "$_chosen")"
	return 0
}
