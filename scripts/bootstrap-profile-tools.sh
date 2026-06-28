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
#       2 invalid invocation / missing jq / missing manifest / malformed control-waivers;
#       3 a REQUIRED tool (or one-of group fallback) is disabled in installation.json
#         with no valid control-waiver, or a required package manager is unavailable;
#       4 install partially succeeded then failed and the installed tree could not be
#         reconstructed during rollback.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"

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

# Consume the COMPOSED effective profile (Blocker 4) — NOT the raw manifest. For a
# combination profile (laravel-react-docker) this yields the full composed php+node
# tool set, identical to scripts/resolve-effective-profile.sh. The target enables
# one-of satisfaction detection (.one_of_groups[g].selected). All composition,
# override and one-of logic lives in the canonical resolver; we only read its
# .tools{} / .one_of_groups{}. The resolver exits 2 on unknown/invalid profiles.
EFFECTIVE=$(mktemp 2>/dev/null || mktemp -t ssbootstrap)
trap 'rm -f "$EFFECTIVE"' EXIT INT TERM
cr_effective_profile "$REPO_ROOT" "$PROFILE" "$TARGET" > "$EFFECTIVE"

# Tools disabled in this install are not "enabled" and so are never bootstrapped.
DISABLED=""
INSTALL_JSON="$TARGET/.sentinel-shield/installation.json"
[ -f "$INSTALL_JSON" ] && DISABLED=$(jq -r '(.disabled_tools // [])[]' "$INSTALL_JSON" 2>/dev/null || true)
is_disabled() { printf '%s\n' "$DISABLED" | grep -qx "$1"; }

# Control-waivers (A3): a REQUIRED tool/group disabled in installation.json may be
# temporarily allowed ONLY by a valid, unexpired control-waiver. Use the SHARED
# validator (do NOT parse waivers here): a malformed file fails closed (exit 2).
CONTROL_WAIVERS_FILE="$TARGET/.sentinel-shield/control-waivers.json"
cw_validate_file "$CONTROL_WAIVERS_FILE" || { log_error "bootstrap: control-waivers file invalid: $CONTROL_WAIVERS_FILE (see errors above)."; exit 2; }
WAIVED_KEYS=" "
for _wk in $(cw_valid_keys "$CONTROL_WAIVERS_FILE" 2>/dev/null); do WAIVED_KEYS="${WAIVED_KEYS}${_wk} "; done
is_waived() { case "$WAIVED_KEYS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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

# bpt_pkg_manager <target> — detect the Node package manager (Blocker 6).
# Lockfile wins: pnpm-lock.yaml=>pnpm, yarn.lock=>yarn, package-lock.json=>npm.
# Multiple distinct lockfiles => ambiguous: exit 2 UNLESS package.json's
# "packageManager" field names one (the explicit setting that resolves it). No
# lockfile => fall back to package.json "packageManager", else npm. NEVER switches
# managers; the caller uses the matching install/restore commands.
bpt_pkg_manager() {
	_t="$1"; _pm=""
	if [ -f "$_t/package.json" ]; then
		_pm=$(jq -r '(.packageManager // "") | split("@")[0]' "$_t/package.json" 2>/dev/null || true)
		case "$_pm" in npm | pnpm | yarn) ;; *) _pm="" ;; esac
	fi
	_found=""
	[ -f "$_t/pnpm-lock.yaml" ] && _found="$_found pnpm"
	[ -f "$_t/yarn.lock" ] && _found="$_found yarn"
	[ -f "$_t/package-lock.json" ] && _found="$_found npm"
	# shellcheck disable=SC2086
	set -- $_found
	if [ "$#" -gt 1 ]; then
		# Ambiguous: a declared packageManager resolves it ONLY when its OWN lockfile
		# is among those present (never switch to a manager whose lock is absent).
		if [ -n "$_pm" ]; then
			case " $* " in
				*" $_pm "*) printf '%s' "$_pm"; return 0 ;;
				*) log_error "bootstrap: package.json 'packageManager' ($_pm) does not match present lockfiles ($*) — refusing to switch managers."; exit 2 ;;
			esac
		fi
		log_error "bootstrap: multiple Node lockfiles present ($*) — ambiguous package manager; set package.json 'packageManager' to resolve."
		exit 2
	fi
	[ "$#" -eq 1 ] && { printf '%s' "$1"; return 0; }
	[ -n "$_pm" ] && { printf '%s' "$_pm"; return 0; }
	printf 'npm'
}

# bpt_node_restore_cmd <manager> <dir> — print the lock-consistent restore command
# (used by rollback and in the recovery hint). Matching, immutable installs only.
bpt_node_restore_cmd() {
	case "$1" in
		npm) printf 'npm --prefix %s ci' "$2" ;;
		pnpm) printf 'pnpm --dir %s install --frozen-lockfile' "$2" ;;
		yarn) printf 'yarn --cwd %s install --immutable' "$2" ;;
	esac
}

# bpt_node_add_cmd <manager> <dir> <scope: dev|prod> — print the add-dependency
# command PREFIX (package tokens are appended by the caller). Matching commands
# per manager; NEVER generates a package-lock.json in a pnpm/yarn repo.
bpt_node_add_cmd() {
	case "$1-$3" in
		npm-dev) printf 'npm --prefix %s install --save-dev' "$2" ;;
		npm-prod) printf 'npm --prefix %s install --save' "$2" ;;
		pnpm-dev) printf 'pnpm --dir %s add --save-dev' "$2" ;;
		pnpm-prod) printf 'pnpm --dir %s add --save-prod' "$2" ;;
		yarn-dev) printf 'yarn --cwd %s add --dev' "$2" ;;
		yarn-prod) printf 'yarn --cwd %s add' "$2" ;;
	esac
}

# bpt_node_restore <manager> <dir> — reconstruct node_modules/ from the (restored)
# lockfile. Returns non-zero if the manager/lockfile is unavailable so the caller
# can report rollback-incomplete.
bpt_node_restore() {
	case "$1" in
		npm) [ -f "$2/package-lock.json" ] && command_exists npm && npm --prefix "$2" ci >/dev/null 2>&1 ;;
		pnpm) [ -f "$2/pnpm-lock.yaml" ] && command_exists pnpm && pnpm --dir "$2" install --frozen-lockfile >/dev/null 2>&1 ;;
		yarn) [ -f "$2/yarn.lock" ] && command_exists yarn && yarn --cwd "$2" install --immutable >/dev/null 2>&1 ;;
		*) return 1 ;;
	esac
}

# bpt_accumulate <toolkey> — append the tool's package tokens to the right install
# bucket (COMPOSER_DEV/PROD, NPM_DEV/PROD globals). Shared by the required-tool
# loop and the one-of fallback so both buckets stay consistent.
bpt_accumulate() {
	_eco=$(bpt_ecosystem "$EFFECTIVE" "$1")
	_apkgs=$(cr_tool_packages "$EFFECTIVE" "$1")
	_aoifs=$IFS
	IFS='
'
	for _apl in $_apkgs; do
		IFS=$_aoifs
		_apn=$(printf '%s\n' "$_apl" | cut -f1)
		_aps=$(printf '%s\n' "$_apl" | cut -f2)
		_apc=$(printf '%s\n' "$_apl" | cut -f3)
		_atok=$(pkg_token "$_eco" "$_apn" "$_apc")
		case "$_eco-$_aps" in
			composer-prod) COMPOSER_PROD="$COMPOSER_PROD $_atok" ;;
			composer-*) COMPOSER_DEV="$COMPOSER_DEV $_atok" ;;
			npm-prod) NPM_PROD="$NPM_PROD $_atok" ;;
			npm-*) NPM_DEV="$NPM_DEV $_atok" ;;
		esac
		IFS='
'
	done
	IFS=$_aoifs
}

# --- inspect environment (read-only) ----------------------------------------
PHPV=$(cr_php_version "$TARGET")
FW=$(cr_framework "$TARGET")
NODEV=""; command_exists node && NODEV=$(node --version 2>/dev/null || true)
# Detect the Node package manager up-front (exits 2 if lockfiles are ambiguous).
NPM_PM=$(bpt_pkg_manager "$TARGET")

printf 'Sentinel Shield — tool bootstrap plan\n'
printf 'Profile:    %s\n' "$PROFILE"
printf 'Target:     %s\n' "$TARGET"
printf 'PHP:        %s\n' "${PHPV:-not detected}"
printf 'Node:       %s\n' "${NODEV:-not detected}"
printf 'Node PM:    %s\n' "$NPM_PM"
printf 'Framework:  %s\n' "$FW"
printf 'Mode:       %s\n' "$([ "$APPLY" -eq 1 ] && echo APPLY || echo 'dry-run (default)')"
printf '\n'
printf 'Required tools:\n'

COMPOSER_DEV=""; COMPOSER_PROD=""; NPM_DEV=""; NPM_PROD=""
# A3 accumulators: required+disabled tools that are waived (reported) vs fatal (no waiver).
WAIVED_REPORT=""; FATAL_DISABLED=""
ANY_REQ=0
KEYS=$(cr_tool_keys "$EFFECTIVE")
_oifs=$IFS
IFS='
'
for k in $KEYS; do
	IFS=$_oifs
	[ -n "$k" ] || { IFS='
'; continue; }
	policy=$(cr_tool_policy "$EFFECTIVE" "$k")
	[ "$policy" = "required" ] || { IFS='
'; continue; }
	ANY_REQ=1
	if is_disabled "$k"; then
		if is_waived "$k"; then
			printf '  - %-20s %-18s %s\n' "$k" "waived" "required but disabled in installation.json; covered by control-waiver"
			WAIVED_REPORT="$WAIVED_REPORT $k"
		else
			printf '  - %-20s %-18s %s\n' "$k" "DISABLED-FAIL" "required tool disabled in installation.json with NO valid control-waiver"
			FATAL_DISABLED="$FATAL_DISABLED $k"
		fi
		IFS='
'; continue
	fi
	res=$(cr_classify_tool "$TARGET" "$EFFECTIVE" "$k")
	decision=${res%%"$TAB"*}
	reason=${res#*"$TAB"}
	printf '  - %-20s %-18s %s\n' "$k" "$decision" "$reason"
	[ "$decision" = "install-compatible" ] && bpt_accumulate "$k"
	IFS='
'
done
IFS=$_oifs
[ "$ANY_REQ" -eq 1 ] || printf '  (none)\n'

# --- one-of groups (Blocker 5): provision exactly ONE alternative per group -----
# Honor the resolver's selection: if a member is already present use it and install
# NOTHING; otherwise propose/install the first fallback (fallback_order[0]). The
# resolver guarantees the alternatives list, so we never install both.
printf '\n'
printf 'One-of groups (exactly one alternative each):\n'
ANY_GROUP=0
# NB: do NOT name this GROUPS — that is a read-only special variable in bash
# (which is /bin/sh on macOS), so assigning to it fails and trips set -e.
ONEOF_GROUPS=$(jq -r '(.one_of_groups // {}) | keys[]' "$EFFECTIVE" 2>/dev/null || true)
IFS='
'
for g in $ONEOF_GROUPS; do
	IFS=$_oifs
	[ -n "$g" ] || { IFS='
'; continue; }
	ANY_GROUP=1
	sel=$(jq -r --arg g "$g" '.one_of_groups[$g].selected // ""' "$EFFECTIVE")
	if [ -n "$sel" ] && [ "$sel" != "null" ]; then
		printf '  - %-20s %-18s %s\n' "$g" "satisfied" "using existing member '$sel'; nothing to install"
		IFS='
'; continue
	fi
	fb=$(jq -r --arg g "$g" '.one_of_groups[$g].fallback_order[0] // ""' "$EFFECTIVE")
	if [ -z "$fb" ]; then
		printf '  - %-20s %-18s %s\n' "$g" "no-fallback" "no member present and no fallback declared; skipped"
		IFS='
'; continue
	fi
	if is_disabled "$fb"; then
		if is_waived "$fb" || is_waived "$g"; then
			printf '  - %-20s %-18s %s\n' "$g" "waived" "required group; fallback '$fb' disabled but covered by control-waiver"
			WAIVED_REPORT="$WAIVED_REPORT $fb"
		else
			printf '  - %-20s %-18s %s\n' "$g" "DISABLED-FAIL" "required group fallback '$fb' disabled with NO valid control-waiver"
			FATAL_DISABLED="$FATAL_DISABLED $fb"
		fi
		IFS='
'; continue
	fi
	gres=$(cr_classify_tool "$TARGET" "$EFFECTIVE" "$fb")
	gdec=${gres%%"$TAB"*}
	greason=${gres#*"$TAB"}
	printf '  - %-20s %-18s %s\n' "$g" "install-fallback" "none present; fallback '$fb' ($gdec): $greason"
	[ "$gdec" = "install-compatible" ] && bpt_accumulate "$fb"
	IFS='
'
done
IFS=$_oifs
[ "$ANY_GROUP" -eq 1 ] || printf '  (none)\n'

# --- A3: required+disabled gate (fail closed BEFORE any mutation) ------------
# A REQUIRED tool/group disabled in installation.json without a valid control-
# waiver must NOT be silently skipped. Report waived ones prominently; refuse to
# proceed (exit 3) if any required tool is disabled with no valid waiver. This
# runs before the dry-run exit AND before any dependency mutation.
if [ -n "$WAIVED_REPORT" ]; then
	printf '\n'
	printf 'Waived (required but disabled in installation.json; covered by control-waiver):\n'
	for _w in $WAIVED_REPORT; do
		printf '  - %s (waiver: %s)\n' "$_w" "$CONTROL_WAIVERS_FILE"
	done
fi
if [ -n "$FATAL_DISABLED" ]; then
	printf '\n'
	log_error "bootstrap: required tool(s) disabled in installation.json with NO valid control-waiver:$FATAL_DISABLED"
	log_error "bootstrap: enable the tool(s), or add an unexpired control-waiver in $CONTROL_WAIVERS_FILE. Refusing to proceed; no dependency files were modified."
	exit 3
fi

# --- render the exact commands ----------------------------------------------
printf '\n'
printf 'Install commands (required + enabled, install-compatible only):\n'
HAVE_CMD=0
[ -n "$COMPOSER_DEV" ]  && { printf '  composer --working-dir=%s require --dev%s\n' "$TARGET" "$COMPOSER_DEV"; HAVE_CMD=1; }
[ -n "$COMPOSER_PROD" ] && { printf '  composer --working-dir=%s require%s\n' "$TARGET" "$COMPOSER_PROD"; HAVE_CMD=1; }
[ -n "$NPM_DEV" ]       && { printf '  %s%s\n' "$(bpt_node_add_cmd "$NPM_PM" "$TARGET" dev)" "$NPM_DEV"; HAVE_CMD=1; }
[ -n "$NPM_PROD" ]      && { printf '  %s%s\n' "$(bpt_node_add_cmd "$NPM_PM" "$TARGET" prod)" "$NPM_PROD"; HAVE_CMD=1; }
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
if [ -n "$NPM_DEV$NPM_PROD" ] && ! command_exists "$NPM_PM"; then
	log_error "bootstrap: $NPM_PM required to install Node tools but not found on PATH."; exit 3
fi

# Snapshot the dependency-declaration + lock files for EVERY supported manager, and
# record whether the installed trees (vendor/, node_modules/) existed beforehand so
# rollback can restore a lock-consistent installed state (Blocker 8).
BACKUP=$(mktemp -d)
trap 'rm -rf "$BACKUP" "$EFFECTIVE"' EXIT INT TERM
SNAP_FILES="composer.json composer.lock package.json package-lock.json pnpm-lock.yaml yarn.lock"
for f in $SNAP_FILES; do
	[ -f "$TARGET/$f" ] && cp "$TARGET/$f" "$BACKUP/$f"
done
HAD_VENDOR=0; [ -d "$TARGET/vendor" ] && HAD_VENDOR=1
HAD_NODE_MODULES=0; [ -d "$TARGET/node_modules" ] && HAD_NODE_MODULES=1
TOUCHED_COMPOSER=0; TOUCHED_NPM=0; ROLLBACK_INCOMPLETE=0

rollback() {
	log_warn "bootstrap: restoring dependency-declaration + lock files to their prior state."
	for _f in $SNAP_FILES; do
		if [ -f "$BACKUP/$_f" ]; then
			cp "$BACKUP/$_f" "$TARGET/$_f"
		elif [ -f "$TARGET/$_f" ]; then
			rm -f "$TARGET/$_f"
		fi
	done
	# Reconstruct a lock-consistent installed tree wherever one existed before.
	if [ "$TOUCHED_COMPOSER" -eq 1 ] && [ "$HAD_VENDOR" -eq 1 ]; then
		if command_exists composer && [ -f "$TARGET/composer.lock" ] \
			&& composer --working-dir="$TARGET" install --no-interaction --prefer-dist >/dev/null 2>&1; then
			:
		else
			ROLLBACK_INCOMPLETE=1
		fi
	fi
	if [ "$TOUCHED_NPM" -eq 1 ] && [ "$HAD_NODE_MODULES" -eq 1 ]; then
		bpt_node_restore "$NPM_PM" "$TARGET" || ROLLBACK_INCOMPLETE=1
	fi
	if [ "$ROLLBACK_INCOMPLETE" -eq 1 ]; then
		log_error "bootstrap: ROLLBACK-INCOMPLETE — dependency files were restored but the installed tree could NOT be reconstructed."
		log_error "bootstrap: run the exact recovery command(s) below to finish recovery:"
		[ "$TOUCHED_COMPOSER" -eq 1 ] && [ "$HAD_VENDOR" -eq 1 ] \
			&& log_error "  composer --working-dir=$TARGET install --no-interaction --prefer-dist"
		[ "$TOUCHED_NPM" -eq 1 ] && [ "$HAD_NODE_MODULES" -eq 1 ] \
			&& log_error "  $(bpt_node_restore_cmd "$NPM_PM" "$TARGET")"
	else
		log_warn "bootstrap: rolled back — dependency files and installed state restored to their prior state."
	fi
}

# fail_rollback — roll back, then exit per the shared contract: 4 when the installed
# tree could not be reconstructed (execution failure), else 1 (install failed).
fail_rollback() {
	rollback
	if [ "$ROLLBACK_INCOMPLETE" -eq 1 ]; then exit 4; else exit 1; fi
}

run_or_rollback() { # run "$@"; on non-zero: roll back + exit (1 or 4)
	log_info "bootstrap: running: $*"
	if ! "$@"; then
		log_error "bootstrap: command failed: $*"
		fail_rollback
	fi
}

# Set the TOUCHED_* flag BEFORE running each mutating command (B3): a partial
# failure inside run_or_rollback exits via fail_rollback, so the flag must already
# be set for rollback to reconstruct the installed tree.
# shellcheck disable=SC2086
[ -n "$COMPOSER_DEV" ]  && { TOUCHED_COMPOSER=1; run_or_rollback composer --working-dir="$TARGET" require --dev $COMPOSER_DEV; }
# shellcheck disable=SC2086
[ -n "$COMPOSER_PROD" ] && { TOUCHED_COMPOSER=1; run_or_rollback composer --working-dir="$TARGET" require $COMPOSER_PROD; }
case "$NPM_PM" in
	npm)
		# shellcheck disable=SC2086
		[ -n "$NPM_DEV" ]  && { TOUCHED_NPM=1; run_or_rollback npm --prefix "$TARGET" install --save-dev $NPM_DEV; }
		# shellcheck disable=SC2086
		[ -n "$NPM_PROD" ] && { TOUCHED_NPM=1; run_or_rollback npm --prefix "$TARGET" install --save $NPM_PROD; } ;;
	pnpm)
		# shellcheck disable=SC2086
		[ -n "$NPM_DEV" ]  && { TOUCHED_NPM=1; run_or_rollback pnpm --dir "$TARGET" add --save-dev $NPM_DEV; }
		# shellcheck disable=SC2086
		[ -n "$NPM_PROD" ] && { TOUCHED_NPM=1; run_or_rollback pnpm --dir "$TARGET" add --save-prod $NPM_PROD; } ;;
	yarn)
		# shellcheck disable=SC2086
		[ -n "$NPM_DEV" ]  && { TOUCHED_NPM=1; run_or_rollback yarn --cwd "$TARGET" add --dev $NPM_DEV; }
		# shellcheck disable=SC2086
		[ -n "$NPM_PROD" ] && { TOUCHED_NPM=1; run_or_rollback yarn --cwd "$TARGET" add $NPM_PROD; } ;;
esac

# Validate lockfiles, then run the project's tests if configured. Failure -> rollback.
if [ "$TOUCHED_COMPOSER" -eq 1 ]; then
	if ! composer --working-dir="$TARGET" validate --no-check-publish --no-check-all >/dev/null 2>&1; then
		log_error "bootstrap: 'composer validate' failed after require."
		fail_rollback
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
		fail_rollback
	fi
	if jq -e '(.scripts.test) // empty' "$TARGET/package.json" >/dev/null 2>&1; then
		case "$NPM_PM" in
			npm)  run_or_rollback npm --prefix "$TARGET" test ;;
			pnpm) run_or_rollback pnpm --dir "$TARGET" test ;;
			yarn) run_or_rollback yarn --cwd "$TARGET" test ;;
		esac
	else
		log_info "bootstrap: no package.json 'scripts.test' configured; skipping Node tests."
	fi
fi

log_info "bootstrap: install complete; lockfiles validated; dependency files committed by you next."
exit 0
