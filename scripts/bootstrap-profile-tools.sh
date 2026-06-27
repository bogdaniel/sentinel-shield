#!/bin/sh
# Sentinel Shield — provision a profile's required tools into a project.
#
# Reads profiles/<name>/profile.manifest.json (or profiles/combinations/<name>.manifest.json),
# inspects the target (PHP/Composer + Node/npm), and decides per REQUIRED+ENABLED tool
# whether its package is already-installed, install-compatible, a conflict, or has no
# package. SAFE BY DEFAULT: prints the exact install plan and DOES NOTHING unless --apply.
#
# With --apply it runs `composer require` / `npm install` for the install-compatible
# required tools, then validates the lockfile and (if a test script exists) runs the
# project's tests. If ANY install/validate/test step fails it ROLLS BACK
# composer.json/composer.lock and package.json/package-lock.json to their prior state.
# NEVER silently mutates dependency files — apply must be explicit.
#
# Usage: bootstrap-profile-tools.sh --profile <name> [--target <dir>] [--dry-run|--apply]
#   --profile <name>  Profile manifest (required). Also accepts a combinations/<name>.
#   --target <dir>    Project directory (default: current directory).
#   --dry-run         Print the plan only (DEFAULT).
#   --apply           Actually run composer require / npm install (explicit).
#   -h, --help        Show help.
# Exit: 0 plan printed / install succeeded; 1 install/validate/tests failed (rolled back);
#       2 invalid invocation / missing jq / missing manifest.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TAB=$(printf '\t')

usage() {
	cat <<'EOF'
Usage: bootstrap-profile-tools.sh --profile <name> [--target <dir>] [--dry-run|--apply]
  --profile <name>  Profile manifest (required). Also accepts a combinations/<name>.
  --target <dir>    Project directory (default: current directory).
  --dry-run         Print the install plan only (DEFAULT — nothing is mutated).
  --apply           Actually run composer require / npm install (explicit opt-in).
  -h, --help        Show help.
Apply runs require/install for required+enabled install-compatible tools, validates the
lockfile, runs the project's tests if a test script exists, and ROLLS BACK
composer.json/composer.lock + package.json/package-lock.json on any failure.
EOF
}

PROFILE=""; TARGET="."; APPLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--dry-run) APPLY=0; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$PROFILE" ] || { log_error "--profile is required"; usage >&2; exit 2; }
command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 2; }
if [ -d "$TARGET" ]; then
	TARGET=$(CDPATH= cd -- "$TARGET" && pwd)
else
	log_error "target directory not found: $TARGET"; exit 2
fi

# Resolve the manifest (named profile OR combinations/<name>).
MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$REPO_ROOT/$cand" ] && { MANIFEST="$REPO_ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { log_error "no manifest for profile '$PROFILE' (looked in profiles/$PROFILE/ and profiles/combinations/)"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "invalid JSON in manifest: $MANIFEST"; exit 2; }

# Tools disabled in this install are not "enabled" and so are never bootstrapped.
DISABLED=""
INSTALL_JSON="$TARGET/.sentinel-shield/installation.json"
[ -f "$INSTALL_JSON" ] && DISABLED=$(jq -r '(.disabled_tools // [])[]' "$INSTALL_JSON" 2>/dev/null || true)
is_disabled() { printf '%s\n' "$DISABLED" | grep -qx "$1"; }

# bpt_ecosystem <manifest> <toolkey> -> composer | npm
# ponytail: ecosystem is inferred from the executable path (vendor/ vs node_modules/),
# falling back to the package name shape. The manifest has no explicit ecosystem field.
bpt_ecosystem() {
	_exes=$(cr_tool_executables "$1" "$2")
	case "$_exes" in
		*node_modules*) printf 'npm'; return 0 ;;
		*vendor/*) printf 'composer'; return 0 ;;
	esac
	_name=$(cr_tool_packages "$1" "$2" | head -n1 | cut -f1)
	case "$_name" in
		@*/*) printf 'npm' ;;
		*/*) printf 'composer' ;;
		*) printf 'npm' ;;
	esac
}

# pkg_token <ecosystem> <name> <compat> — render a require/install argument.
pkg_token() {
	if [ "$3" = "auto" ] || [ -z "$3" ]; then printf '%s' "$2"; return 0; fi
	case "$1" in
		composer) printf '%s:%s' "$2" "$3" ;;
		npm) printf '%s@%s' "$2" "$3" ;;
	esac
}

# --- inspect environment (read-only) ----------------------------------------
PHPV=$(cr_php_version "$TARGET")
FW=$(cr_framework "$TARGET")
NODEV=""; command_exists node && NODEV=$(node --version 2>/dev/null || true)

printf 'Sentinel Shield — tool bootstrap plan\n'
printf 'Profile:    %s\n' "$PROFILE"
printf 'Target:     %s\n' "$TARGET"
printf 'PHP:        %s\n' "${PHPV:-not detected}"
printf 'Node:       %s\n' "${NODEV:-not detected}"
printf 'Framework:  %s\n' "$FW"
printf 'Mode:       %s\n' "$([ "$APPLY" -eq 1 ] && echo APPLY || echo 'dry-run (default)')"
printf '\n'
printf 'Required tools:\n'

COMPOSER_DEV=""; COMPOSER_PROD=""; NPM_DEV=""; NPM_PROD=""
ANY_REQ=0
KEYS=$(cr_tool_keys "$MANIFEST")
_oifs=$IFS
IFS='
'
for k in $KEYS; do
	IFS=$_oifs
	[ -n "$k" ] || { IFS='
'; continue; }
	policy=$(cr_tool_policy "$MANIFEST" "$k")
	[ "$policy" = "required" ] || { IFS='
'; continue; }
	ANY_REQ=1
	if is_disabled "$k"; then
		printf '  - %-20s %-18s %s\n' "$k" "disabled" "disabled in installation.json; skipped"
		IFS='
'; continue
	fi
	res=$(cr_classify_tool "$TARGET" "$MANIFEST" "$k")
	decision=${res%%"$TAB"*}
	reason=${res#*"$TAB"}
	printf '  - %-20s %-18s %s\n' "$k" "$decision" "$reason"
	if [ "$decision" = "install-compatible" ]; then
		eco=$(bpt_ecosystem "$MANIFEST" "$k")
		_pkgs=$(cr_tool_packages "$MANIFEST" "$k")
		_poifs=$IFS
		IFS='
'
		for _pl in $_pkgs; do
			IFS=$_poifs
			_pn=$(printf '%s\n' "$_pl" | cut -f1)
			_ps=$(printf '%s\n' "$_pl" | cut -f2)
			_pc=$(printf '%s\n' "$_pl" | cut -f3)
			_tok=$(pkg_token "$eco" "$_pn" "$_pc")
			case "$eco-$_ps" in
				composer-prod) COMPOSER_PROD="$COMPOSER_PROD $_tok" ;;
				composer-*) COMPOSER_DEV="$COMPOSER_DEV $_tok" ;;
				npm-prod) NPM_PROD="$NPM_PROD $_tok" ;;
				npm-*) NPM_DEV="$NPM_DEV $_tok" ;;
			esac
			IFS='
'
		done
		IFS=$_poifs
	fi
	IFS='
'
done
IFS=$_oifs
[ "$ANY_REQ" -eq 1 ] || printf '  (none)\n'

# --- render the exact commands ----------------------------------------------
printf '\n'
printf 'Install commands (required + enabled, install-compatible only):\n'
HAVE_CMD=0
[ -n "$COMPOSER_DEV" ]  && { printf '  composer --working-dir=%s require --dev%s\n' "$TARGET" "$COMPOSER_DEV"; HAVE_CMD=1; }
[ -n "$COMPOSER_PROD" ] && { printf '  composer --working-dir=%s require%s\n' "$TARGET" "$COMPOSER_PROD"; HAVE_CMD=1; }
[ -n "$NPM_DEV" ]       && { printf '  npm --prefix %s install --save-dev%s\n' "$TARGET" "$NPM_DEV"; HAVE_CMD=1; }
[ -n "$NPM_PROD" ]      && { printf '  npm --prefix %s install --save%s\n' "$TARGET" "$NPM_PROD"; HAVE_CMD=1; }
[ "$HAVE_CMD" -eq 1 ] || printf '  (nothing to install — required tools are already present or external)\n'

if [ "$APPLY" -eq 0 ]; then
	printf '\n'
	printf 'DRY-RUN: no dependency files were modified. Re-run with --apply to install.\n'
	exit 0
fi

# --- apply (explicit) -------------------------------------------------------
if [ "$HAVE_CMD" -eq 0 ]; then
	log_info "bootstrap: nothing to install; dependency files unchanged."
	exit 0
fi
if [ -n "$COMPOSER_DEV$COMPOSER_PROD" ] && ! command_exists composer; then
	log_error "bootstrap: composer required to install PHP tools but not found on PATH."; exit 1
fi
if [ -n "$NPM_DEV$NPM_PROD" ] && ! command_exists npm; then
	log_error "bootstrap: npm required to install Node tools but not found on PATH."; exit 1
fi

# Snapshot dependency files so we can roll back on any failure.
BACKUP=$(mktemp -d)
trap 'rm -rf "$BACKUP"' EXIT INT TERM
for f in composer.json composer.lock package.json package-lock.json; do
	[ -f "$TARGET/$f" ] && cp "$TARGET/$f" "$BACKUP/$f"
done

rollback() {
	log_warn "bootstrap: rolling back dependency files to their prior state."
	for _f in composer.json composer.lock package.json package-lock.json; do
		if [ -f "$BACKUP/$_f" ]; then
			cp "$BACKUP/$_f" "$TARGET/$_f"
		elif [ -f "$TARGET/$_f" ]; then
			rm -f "$TARGET/$_f"
		fi
	done
}

run_or_rollback() { # run "$@"; on non-zero: rollback + exit 1
	log_info "bootstrap: running: $*"
	if ! "$@"; then
		log_error "bootstrap: command failed: $*"
		rollback
		exit 1
	fi
}

TOUCHED_COMPOSER=0; TOUCHED_NPM=0
# shellcheck disable=SC2086
[ -n "$COMPOSER_DEV" ]  && { run_or_rollback composer --working-dir="$TARGET" require --dev $COMPOSER_DEV; TOUCHED_COMPOSER=1; }
# shellcheck disable=SC2086
[ -n "$COMPOSER_PROD" ] && { run_or_rollback composer --working-dir="$TARGET" require $COMPOSER_PROD; TOUCHED_COMPOSER=1; }
# shellcheck disable=SC2086
[ -n "$NPM_DEV" ]       && { run_or_rollback npm --prefix "$TARGET" install --save-dev $NPM_DEV; TOUCHED_NPM=1; }
# shellcheck disable=SC2086
[ -n "$NPM_PROD" ]      && { run_or_rollback npm --prefix "$TARGET" install --save $NPM_PROD; TOUCHED_NPM=1; }

# Validate lockfiles, then run the project's tests if configured. Failure -> rollback.
if [ "$TOUCHED_COMPOSER" -eq 1 ]; then
	if ! composer --working-dir="$TARGET" validate --no-check-publish --no-check-all >/dev/null 2>&1; then
		log_error "bootstrap: 'composer validate' failed after require."
		rollback; exit 1
	fi
	if jq -e '(.scripts.test) // empty' "$TARGET/composer.json" >/dev/null 2>&1; then
		run_or_rollback composer --working-dir="$TARGET" run-script test
	else
		log_info "bootstrap: no composer 'scripts.test' configured; skipping PHP tests."
	fi
fi
if [ "$TOUCHED_NPM" -eq 1 ]; then
	if [ -f "$TARGET/package-lock.json" ] && ! jq -e . "$TARGET/package-lock.json" >/dev/null 2>&1; then
		log_error "bootstrap: package-lock.json is not valid JSON after install."
		rollback; exit 1
	fi
	if jq -e '(.scripts.test) // empty' "$TARGET/package.json" >/dev/null 2>&1; then
		run_or_rollback npm --prefix "$TARGET" test
	else
		log_info "bootstrap: no package.json 'scripts.test' configured; skipping Node tests."
	fi
fi

log_info "bootstrap: install complete; lockfiles validated; dependency files committed by you next."
exit 0
