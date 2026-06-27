#!/bin/sh
# Sentinel Shield — print a read-only Composer installation PLAN for a profile.
#
# Reads profiles/<name>/profile.manifest.json, inspects the target project
# (installed PHP, composer.json/lock, framework), and decides per
# required/recommended/one-of tool whether its Composer package is
# already-installed, install-compatible, a conflict, or has no Composer package.
# INSPECTS only — never installs, never mutates, never hits the network.
#
# Usage: resolve-tool-plan.sh --profile <name> [--target <dir>] [--format text|json]
# Exit:  0 on success (the plan is the output); 2 for invalid invocation / missing jq.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TAB=$(printf '\t')

usage() {
	printf 'Usage: resolve-tool-plan.sh --profile <name> [--target <dir>] [--format text|json]\n'
}

PROFILE=""
TARGET="."
FORMAT="text"
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$PROFILE" ] || { log_error "--profile is required"; usage >&2; exit 2; }
case "$FORMAT" in
	text | json) ;;
	*) log_error "--format must be 'text' or 'json'"; exit 2 ;;
esac
command_exists jq || { log_error "jq is required for JSON parsing but was not found. Install jq."; exit 2; }

if [ -d "$TARGET" ]; then
	TARGET=$(CDPATH= cd -- "$TARGET" && pwd)
else
	log_error "target directory not found: $TARGET"
	exit 2
fi

MANIFEST=$(cr_manifest_path "$REPO_ROOT" "$PROFILE")
[ -f "$MANIFEST" ] || { log_error "profile manifest not found: $MANIFEST"; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "invalid JSON in manifest: $MANIFEST"; exit 2; }

# --- inspect the environment (read-only) ------------------------------------
PHPV=$(cr_php_version "$TARGET")
MINSTAB=$(cr_min_stability "$TARGET")
FW=$(cr_framework "$TARGET")

# --- classify every required/recommended/one-of tool ------------------------
KEYS=$(cr_tool_keys "$MANIFEST")
REQ=""
REC=""
ONE=""
ACC=""
_oifs=$IFS
IFS='
'
for k in $KEYS; do
	IFS=$_oifs
	[ -n "$k" ] || { IFS='
'; continue; }
	policy=$(cr_tool_policy "$MANIFEST" "$k")
	case "$policy" in
		required | recommended | one-of) ;;
		*) IFS='
'; continue ;;
	esac
	res=$(cr_classify_tool "$TARGET" "$MANIFEST" "$k")
	decision=${res%%"$TAB"*}
	reason=${res#*"$TAB"}
	line=$(printf '  - %-20s %-18s %s' "$k" "$decision" "$reason")
	case "$policy" in
		required) REQ="${REQ}${line}
" ;;
		recommended) REC="${REC}${line}
" ;;
		one-of) ONE="${ONE}${line}
" ;;
	esac
	ACC="${ACC}$(jq -nc --arg k "$k" --arg p "$policy" --arg d "$decision" --arg r "$reason" \
		'{key:$k, policy:$p, decision:$d, reason:$r}')
"
	IFS='
'
done
IFS=$_oifs

# --- render ------------------------------------------------------------------
if [ "$FORMAT" = "json" ]; then
	printf '%s' "$ACC" | jq -s \
		--arg profile "$PROFILE" \
		--arg target "$TARGET" \
		--arg php "$PHPV" \
		--arg fw "$FW" \
		--arg stab "$MINSTAB" '
		{
			profile: $profile,
			target: $target,
			php_version: (if $php == "" then null else $php end),
			framework: $fw,
			minimum_stability: $stab,
			tools: (map({ (.key): { policy: .policy, decision: .decision, reason: .reason } }) | add // {})
		}'
	exit 0
fi

printf 'Sentinel Shield — installation plan\n'
printf 'Profile:    %s\n' "$PROFILE"
printf 'Target:     %s\n' "$TARGET"
printf 'PHP:        %s\n' "${PHPV:-not detected}"
printf 'Framework:  %s\n' "$FW"
printf 'Stability:  %s\n' "$MINSTAB"
printf '\n'
printf 'Required:\n'
if [ -n "$REQ" ]; then printf '%s' "$REQ"; else printf '  (none)\n'; fi
printf '\n'
printf 'One-of (choose one):\n'
if [ -n "$ONE" ]; then printf '%s' "$ONE"; else printf '  (none)\n'; fi
printf '\n'
printf 'Recommended:\n'
if [ -n "$REC" ]; then printf '%s' "$REC"; else printf '  (none)\n'; fi
exit 0
