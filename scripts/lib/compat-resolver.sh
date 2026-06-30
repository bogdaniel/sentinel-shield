# Sentinel Shield — Composer package compatibility resolver (POSIX sh library).
#
# Source this file; do not execute it. It INSPECTS a project and a profile
# manifest and decides, per required/recommended tool, how the tool's Composer
# package(s) should be obtained. It NEVER mutates the project: no composer
# require/update, no writes, no network.
#
# Requires the shared library to be sourced FIRST (the CLI wrapper does this):
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/compat-resolver.sh"
# It uses command_exists/log_* from there, and jq for JSON parsing.
#
# Per-tool DECISIONS (printed as "<decision><TAB><reason>"):
#   already-installed   — an executable[] candidate is present in the project.
#   install-compatible  — not present; package(s) can be added safely. With
#                         compatibility:auto we let Composer pick the version
#                         (we never invent a pinned constraint).
#   conflict            — adding the tool would alter/downgrade a runtime (prod)
#                         dependency the app already requires. STOP — and the
#                         reason recommends an isolated install.
#   no-package          — the tool declares no Composer package (system/external
#                         binary such as gitleaks/semgrep); install out-of-band.
#
# ponytail: conflict is detected deterministically WITHOUT running Composer — the
# only honest read-only signal we have is "tool's explicit constraint differs
# from a constraint the app already pins in `require` (prod)". compatibility:auto
# defers to Composer's own resolver and so never trips this. Deep semver range
# intersection is intentionally out of scope (would need Composer/network).

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_COMPAT_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_COMPAT_LOADED=1

# --- environment probes ------------------------------------------------------

# cr_php_version — print the runtime PHP version (e.g. 8.2.10) or empty if absent.
cr_php_version() {
	command_exists php || return 0
	php -r 'echo PHP_VERSION;' 2>/dev/null || true
}

# cr_min_stability <target> — print composer minimum-stability (default "stable").
cr_min_stability() {
	if [ ! -f "$1/composer.json" ]; then
		printf 'stable'
		return 0
	fi
	_v=$(jq -r '."minimum-stability" // "stable"' "$1/composer.json" 2>/dev/null) || _v="stable"
	printf '%s' "${_v:-stable}"
}

# cr_framework <target> — print "<package> <version>" of the detected framework,
# or "none". Prefers composer.lock (resolved version), falls back to the
# composer.json constraint.
cr_framework() {
	_lock="$1/composer.lock"
	_cj="$1/composer.json"
	for _p in laravel/framework symfony/framework-bundle symfony/symfony; do
		if [ -f "$_lock" ]; then
			_v=$(jq -r --arg p "$_p" '([.packages[]?, .["packages-dev"][]?] | map(select(.name==$p)) | .[0].version) // empty' "$_lock" 2>/dev/null) || _v=""
			if [ -n "$_v" ]; then
				printf '%s %s' "$_p" "$_v"
				return 0
			fi
		fi
	done
	if [ -f "$_cj" ]; then
		for _p in laravel/framework symfony/framework-bundle symfony/symfony; do
			_v=$(jq -r --arg p "$_p" '((.require // {})[$p]) // ((."require-dev" // {})[$p]) // empty' "$_cj" 2>/dev/null) || _v=""
			if [ -n "$_v" ]; then
				printf '%s %s' "$_p" "$_v"
				return 0
			fi
		done
	fi
	printf 'none'
}

# --- manifest readers --------------------------------------------------------

# cr_manifest_path <repo_root> <profile> — print the manifest path, resolving BOTH
# standard profiles and combination manifests (matches the canonical resolver's
# ep__manifest_path) so names like node-react / laravel-react-docker work. Falls
# back to the standard path so a caller's "not found" message stays accurate.
cr_manifest_path() {
	if [ -f "$1/profiles/$2/profile.manifest.json" ]; then
		printf '%s/profiles/%s/profile.manifest.json' "$1" "$2"
	elif [ -f "$1/profiles/combinations/$2.manifest.json" ]; then
		printf '%s/profiles/combinations/%s.manifest.json' "$1" "$2"
	else
		printf '%s/profiles/%s/profile.manifest.json' "$1" "$2"
	fi
}

# cr_effective_profile <repo_root> <profile> [target] — emit the COMPOSED,
# override-aware effective profile JSON (the SINGLE source of the tool set) by
# delegating to the canonical resolver scripts/resolve-effective-profile.sh.
# NEVER merge profiles here. The resolver's .tools{} shape is identical to a raw
# manifest's, so the cr_tool_* readers below consume the emitted JSON unchanged.
# The resolver exits 2 on unknown/invalid/cyclic profiles; that propagates to the
# caller (which runs under set -e), keeping the shared exit contract intact.
cr_effective_profile() {
	if [ -n "${3:-}" ]; then
		sh "$1/scripts/resolve-effective-profile.sh" --profile "$2" --target "$3" --format json
	else
		sh "$1/scripts/resolve-effective-profile.sh" --profile "$2" --format json
	fi
}

# cr_tool_keys <manifest> — list tool keys, one per line, in manifest order.
cr_tool_keys() { jq -r '(.tools // {}) | keys_unsorted[]' "$1" 2>/dev/null || true; }

# cr_tool_policy <manifest> <toolkey> — print the tool's policy ("" if unset).
cr_tool_policy() { jq -r --arg k "$2" '(.tools[$k].policy) // ""' "$1" 2>/dev/null || true; }

# cr_tool_executables <manifest> <toolkey> — list candidate executables.
cr_tool_executables() { jq -r --arg k "$2" '(.tools[$k].executable // [])[]' "$1" 2>/dev/null || true; }

# cr_tool_packages <manifest> <toolkey> — one "name<TAB>scope<TAB>compatibility"
# per package; scope defaults to dev and compatibility to auto.
cr_tool_packages() {
	jq -r --arg k "$2" '
		(.tools[$k].packages // [])[]
		| [ .name, (.scope // "dev"), (.compatibility // "auto") ] | @tsv
	' "$1" 2>/dev/null || true
}

# --- detection ---------------------------------------------------------------

# cr_executable_present <target> <executable> — true if the candidate exists:
# a path-bearing candidate (vendor/bin/x) is checked under <target>; a bare name
# is looked up on PATH.
cr_executable_present() {
	case "$2" in
		*/*) [ -x "$1/$2" ] ;;
		*) command_exists "$2" ;;
	esac
}

# cr_tool_detected <target> <manifest> <toolkey> — true if ANY executable[] is
# present (first-match-wins semantics; here we only need existence).
cr_tool_detected() {
	_exes=$(cr_tool_executables "$2" "$3")
	[ -n "$_exes" ] || return 1
	_oifs=$IFS
	IFS='
'
	for _e in $_exes; do
		IFS=$_oifs
		[ -n "$_e" ] || { IFS='
'; continue; }
		if cr_executable_present "$1" "$_e"; then
			return 0
		fi
		IFS='
'
	done
	IFS=$_oifs
	return 1
}

# --- classification ----------------------------------------------------------

# cr_classify_tool <target> <manifest> <toolkey>
# Print "<decision><TAB><reason>" (see decisions documented at the top).
cr_classify_tool() {
	if cr_tool_detected "$1" "$2" "$3"; then
		printf 'already-installed\texecutable present in project'
		return 0
	fi

	_pkgs=$(cr_tool_packages "$2" "$3")
	if [ -z "$_pkgs" ]; then
		printf 'no-package\tno Composer package declared (system/external tool); install out-of-band'
		return 0
	fi

	_cj="$1/composer.json"
	_conflict=0
	_reason=""
	_oifs=$IFS
	IFS='
'
	for _line in $_pkgs; do
		IFS=$_oifs
		_name=$(printf '%s\n' "$_line" | cut -f1)
		_compat=$(printf '%s\n' "$_line" | cut -f3)
		_prod=""
		_dev=""
		if [ -f "$_cj" ]; then
			_prod=$(jq -r --arg p "$_name" '((.require // {})[$p]) // ""' "$_cj" 2>/dev/null) || _prod=""
			_dev=$(jq -r --arg p "$_name" '((."require-dev" // {})[$p]) // ""' "$_cj" 2>/dev/null) || _dev=""
		fi
		if [ -n "$_prod" ]; then
			if [ "$_compat" != "auto" ] && [ "$_compat" != "$_prod" ]; then
				_conflict=1
				_reason="${_reason}${_reason:+; }$_name: tool wants '$_compat' but app requires '$_prod' (prod) — would alter/downgrade a runtime dependency"
			else
				_reason="${_reason}${_reason:+; }$_name already a prod dependency ($_prod)"
			fi
		elif [ -n "$_dev" ]; then
			_reason="${_reason}${_reason:+; }$_name already in require-dev ($_dev)"
		elif [ "$_compat" = "auto" ]; then
			_reason="${_reason}${_reason:+; }$_name (Composer picks a compatible version)"
		else
			_reason="${_reason}${_reason:+; }$_name@$_compat"
		fi
		IFS='
'
	done
	IFS=$_oifs

	if [ "$_conflict" = "1" ]; then
		printf 'conflict\t%s — recommend an isolated install (separate tools/ composer or phive)' "$_reason"
	else
		printf 'install-compatible\t%s' "$_reason"
	fi
}
