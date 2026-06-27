# Sentinel Shield — isolated tool manager (POSIX sh library).
#
# Source this file; do not execute it. It defines helper functions only and does
# not enable `set -eu` itself (the caller decides). All functions are POSIX sh
# compatible: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
#
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/isolated-tools.sh"
#
# WHY THIS EXISTS
#   Some tools (deptrac, rector, psalm, php-cs-fixer) pull dependency graphs that
#   conflict with the consuming application's own composer requirements. Installing
#   them into the project's vendor/ can FORCE A FRAMEWORK DOWNGRADE (e.g. drag
#   laravel/framework or a shared library to an older version) just to satisfy the
#   tool — defeating the point of running the tool at all. The fix is isolation:
#   each such tool gets its OWN minimal composer project under tools/<tool>/ with
#   its OWN vendor/, resolved independently of the app. The app's dependency graph
#   is never touched, so no downgrade can happen.
#
# CONVENTION (see templates/tools/README.md)
#   tools/<tool>/composer.json   — minimal, committed; requires ONLY the tool.
#   tools/<tool>/composer.lock   — committed (pin/reproducible installs).
#   tools/<tool>/vendor/         — git-ignored (see .gitignore).
#   tools/<tool>/vendor/bin/<bin> — deterministic wrapper invocation path.
#
# This library NEVER runs composer. It scaffolds files (DRY-RUN unless --apply),
# reports the deterministic paths/commands, and reads the installed version from
# the lockfile. Running `composer install`/`update` is the caller's job.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_ISOLATED_TOOLS_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_ISOLATED_TOOLS_LOADED=1

# Root directory holding all isolated tool projects (relative to the project root).
ISOLATED_TOOLS_DIR="${ISOLATED_TOOLS_DIR:-tools}"

# --- key / path helpers ------------------------------------------------------
# isolated_tool_validate_key <tool> — die unless <tool> matches the shared toolKey
# pattern (^[a-z0-9][a-z0-9-]*$). Keeps tools/<tool> paths predictable and safe.
isolated_tool_validate_key() {
	[ -n "${1:-}" ] || die "isolated_tool: missing tool key"
	case "$1" in
		[a-z0-9]*) ;;
		*) die "isolated_tool: invalid tool key '$1' (must start with [a-z0-9])" ;;
	esac
	# Reject anything outside [a-z0-9-]; tr-strip and compare lengths via a glob.
	case "$1" in
		*[!a-z0-9-]*) die "isolated_tool: invalid tool key '$1' (allowed: a-z 0-9 '-')" ;;
	esac
}

# isolated_tool_root <tool> — echo the tool project directory, e.g. tools/psalm.
isolated_tool_root() {
	isolated_tool_validate_key "$1"
	printf '%s/%s' "$ISOLATED_TOOLS_DIR" "$1"
}

# isolated_tool_composer_path <tool> — echo tools/<tool>/composer.json.
isolated_tool_composer_path() { printf '%s/composer.json' "$(isolated_tool_root "$1")"; }

# isolated_tool_lock_path <tool> — echo tools/<tool>/composer.lock.
isolated_tool_lock_path() { printf '%s/composer.lock' "$(isolated_tool_root "$1")"; }

# isolated_tool_bin <tool> <bin> — echo the deterministic wrapper path,
# tools/<tool>/vendor/bin/<bin>. Callers invoke the tool through this path only.
isolated_tool_bin() {
	[ -n "${2:-}" ] || die "isolated_tool_bin: missing bin name (usage: isolated_tool_bin <tool> <bin>)"
	printf '%s/vendor/bin/%s' "$(isolated_tool_root "$1")" "$2"
}

# isolated_tool_available <tool> <bin> — true if the wrapper bin is executable
# (i.e. `composer install` has already been run inside tools/<tool>/).
isolated_tool_available() { [ -x "$(isolated_tool_bin "$1" "$2")" ]; }

# --- update / install command doc strings ------------------------------------
# These print the EXACT command an operator (or CI) should run. This library does
# not execute composer; it only documents the contract.
isolated_tool_install_command() {
	printf 'composer --working-dir=%s install' "$(isolated_tool_root "$1")"
}
isolated_tool_update_command() {
	printf 'composer --working-dir=%s update' "$(isolated_tool_root "$1")"
}

# --- composer.json rendering / scaffolding -----------------------------------
# isolated_tool_render_composer_json <tool> <package> [constraint]
# Print a minimal, isolated composer.json to STDOUT. It requires ONLY the tool
# package — never the framework — so resolution cannot downgrade the app. Defaults
# to the "*" constraint; the resulting composer.lock is what pins the real version.
# ponytail: hand-rolled JSON via printf + json_escape (no jq dependency for a
# fixed-shape 4-field document). json_escape lives in sentinel-shield-common.sh.
isolated_tool_render_composer_json() {
	isolated_tool_validate_key "$1"
	[ -n "${2:-}" ] || die "isolated_tool: missing package (usage: <tool> <package> [constraint])"
	# shellcheck disable=SC2039
	_it_pkg=$(json_escape "$2")
	_it_con=$(json_escape "${3:-*}")
	_it_name=$(json_escape "sentinel-shield/isolated-$1")
	printf '%s\n' "{"
	printf '    "name": "%s",\n' "$_it_name"
	printf '    "description": "Isolated install of %s, managed by Sentinel Shield. Do NOT add the application framework here; isolation prevents tool deps from downgrading the app.",\n' "$_it_pkg"
	printf '%s\n' '    "require": {'
	printf '        "%s": "%s"\n' "$_it_pkg" "$_it_con"
	printf '%s\n' '    },'
	printf '%s\n' '    "config": {'
	printf '%s\n' '        "sort-packages": true,'
	printf '%s\n' '        "optimize-autoloader": true'
	printf '%s\n' '    }'
	printf '%s\n' "}"
	unset _it_pkg _it_con _it_name
}

# isolated_tool_scaffold <tool> <package> [constraint] [--apply]
# DRY-RUN by default: render tools/<tool>/composer.json to STDOUT and log what
# WOULD be written. Only with --apply does it write the file (refusing to clobber
# an existing composer.json unless --force is also given). Never runs composer:
# afterwards the caller runs `isolated_tool_install_command <tool>`.
isolated_tool_scaffold() {
	_it_apply=false
	_it_force=false
	_it_tool=""; _it_pkg=""; _it_con="*"
	_it_pos=0
	# Separate flags from positionals with shift (no reliance on word-splitting).
	while [ $# -gt 0 ]; do
		case "$1" in
			--apply) _it_apply=true ;;
			--force) _it_force=true ;;
			-*) die "isolated_tool_scaffold: unknown flag '$1'" ;;
			*)
				_it_pos=$((_it_pos + 1))
				case "$_it_pos" in
					1) _it_tool="$1" ;;
					2) _it_pkg="$1" ;;
					3) _it_con="$1" ;;
					*) die "isolated_tool_scaffold: too many arguments ('$1')" ;;
				esac
				;;
		esac
		shift
	done
	[ -n "$_it_tool" ] && [ -n "$_it_pkg" ] \
		|| die "isolated_tool_scaffold: usage: <tool> <package> [constraint] [--apply] [--force]"
	_it_path=$(isolated_tool_composer_path "$_it_tool")

	if [ "$_it_apply" != "true" ]; then
		log_info "isolated_tool_scaffold: DRY-RUN for '$_it_tool' ($_it_pkg:$_it_con). Would write '$_it_path'. Pass --apply to write. Then run: $(isolated_tool_install_command "$_it_tool")"
		isolated_tool_render_composer_json "$_it_tool" "$_it_pkg" "$_it_con"
		unset _it_apply _it_force _it_pos _it_tool _it_pkg _it_con _it_path
		return 0
	fi

	if [ -f "$_it_path" ] && [ "$_it_force" != "true" ]; then
		die "isolated_tool_scaffold: '$_it_path' already exists; pass --force to overwrite."
	fi
	isolated_tool_render_composer_json "$_it_tool" "$_it_pkg" "$_it_con" | write_file "$_it_path"
	log_info "isolated_tool_scaffold: wrote '$_it_path'. Next: $(isolated_tool_install_command "$_it_tool") (commit composer.json + composer.lock; vendor/ stays git-ignored)."
	unset _it_apply _it_force _it_pos _it_tool _it_pkg _it_con _it_path
}

# --- installed version --------------------------------------------------------
# isolated_tool_version <tool> <package> — echo the locked version of <package>
# from tools/<tool>/composer.lock, or "unknown" if the lock/package/jq is absent.
# Reads the LOCK (the source of truth for what is/should be installed), not vendor.
isolated_tool_version() {
	isolated_tool_validate_key "$1"
	[ -n "${2:-}" ] || die "isolated_tool_version: missing package (usage: <tool> <package>)"
	_it_lock=$(isolated_tool_lock_path "$1")
	if [ ! -f "$_it_lock" ]; then
		log_warn "isolated_tool_version: '$_it_lock' absent; run '$(isolated_tool_install_command "$1")' first."
		printf 'unknown'; unset _it_lock; return 0
	fi
	if ! command_exists jq; then
		log_warn "isolated_tool_version: jq not found; cannot read '$_it_lock'."
		printf 'unknown'; unset _it_lock; return 0
	fi
	_it_ver=$(jq -r --arg p "$2" \
		'[(.packages // [])[], ((."packages-dev" // [])[])] | map(select(.name == $p)) | (.[0].version // "unknown")' \
		"$_it_lock" 2>/dev/null) || _it_ver="unknown"
	[ -n "$_it_ver" ] || _it_ver="unknown"
	printf '%s' "$_it_ver"
	unset _it_lock _it_ver
}
