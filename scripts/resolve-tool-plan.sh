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
# Canonical identifier grammar + structural set primitives (#251).
# shellcheck source=scripts/lib/profile-schema.sh
. "$SCRIPT_DIR/lib/profile-schema.sh"

REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TAB=$(printf '\t')

# usage — print CLI usage/help to stdout.
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
# (#251) Validate the identifier BEFORE it is handed to a resolver that will turn
# it into a filesystem path.
ps_require_id "$PROFILE" "profile identifier" "resolve-tool-plan --profile"
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

# Consume the COMPOSED effective profile (Blocker 4) — NOT the raw named manifest.
# This makes combination profiles (e.g. laravel-react-docker) resolve their full
# php+node tool set, identical to scripts/resolve-effective-profile.sh. All
# composition/override/one-of logic lives in the canonical resolver; we only read
# the .tools{} it emits. The resolver exits 2 on unknown/invalid profiles.
EFFECTIVE=$(mktemp 2>/dev/null || mktemp -t sstoolplan)
trap 'rm -f "$EFFECTIVE"' EXIT INT TERM
cr_effective_profile "$REPO_ROOT" "$PROFILE" "$TARGET" > "$EFFECTIVE"

# Project-disabled tools (.sentinel-shield/installation.json) are EXCLUDED from the
# installable/missing plan — they are reported as 'disabled', never proposed for
# install. (A required control cannot be disabled without a control-waiver; that is
# enforced by the gate, not here — this only keeps the install plan honest.)
# (#251) A newline-delimited STRUCTURAL set of validated identifiers, tested with
# whole-line equality. It used to be a space-padded string built by `for dt in
# $(jq ...)`: one project-controlled entry containing a space became two disabled
# tools, one containing a glob character was expanded against the cwd, and the
# `*" $k "*` membership test matched a key across element boundaries.
DISABLED_SET=""
_im="$TARGET/.sentinel-shield/installation.json"
if [ -f "$_im" ] && jq -e . "$_im" >/dev/null 2>&1; then
	_dts=$(jq -r '(.disabled_tools // [])[]' "$_im" 2>/dev/null || true)
	while IFS= read -r _dt; do
		[ -n "$_dt" ] || continue
		ps_valid_id "$_dt" || { log_error "invalid tool identifier in $_im .disabled_tools: reason=$(ps_id_reject_reason "$_dt" || true) value=$(ps_id_render "$_dt") (must match $PS_ID_PATTERN)"; exit 2; }
		DISABLED_SET=$(ps_set_add "$_dt" "$DISABLED_SET")
	done <<RTP_DISABLED
$_dts
RTP_DISABLED
fi

# --- inspect the environment (read-only) ------------------------------------
PHPV=$(cr_php_version "$TARGET")
MINSTAB=$(cr_min_stability "$TARGET")
FW=$(cr_framework "$TARGET")

# --- classify every required/recommended/one-of tool ------------------------
KEYS=$(cr_tool_keys "$EFFECTIVE")
REQ=""
REC=""
ONE=""
DIS=""
ACC=""
# (#251) One key per LINE. The IFS-juggling `for k in $KEYS` this replaces still
# glob-expanded every element, and had to restore/re-set IFS at four different
# points inside the body — one missed branch and the loop split on spaces again.
while IFS= read -r k; do
	[ -n "$k" ] || continue
	ps_valid_id "$k" || { log_error "effective profile declares an invalid tool identifier: reason=$(ps_id_reject_reason "$k" || true) value=$(ps_id_render "$k") (must match $PS_ID_PATTERN)"; exit 2; }
	policy=$(cr_tool_policy "$EFFECTIVE" "$k")
	case "$policy" in
		required | recommended | one-of) ;;
		*) continue ;;
	esac
	if ps_set_has "$k" "$DISABLED_SET"; then
		decision="disabled"; reason="disabled via .sentinel-shield/installation.json"
	else
		res=$(cr_classify_tool "$TARGET" "$EFFECTIVE" "$k"); decision=${res%%"$TAB"*}; reason=${res#*"$TAB"}
	fi
	line=$(printf '  - %-20s %-18s %s' "$k" "$decision" "$reason")
	if [ "$decision" = "disabled" ]; then
		DIS="${DIS}${line}
"
	else
		case "$policy" in
			required) REQ="${REQ}${line}
" ;;
			recommended) REC="${REC}${line}
" ;;
			one-of) ONE="${ONE}${line}
" ;;
		esac
	fi
	ACC="${ACC}$(jq -nc --arg k "$k" --arg p "$policy" --arg d "$decision" --arg r "$reason" \
		'{key:$k, policy:$p, decision:$d, reason:$r}')
"
done <<RTP_KEYS
$KEYS
RTP_KEYS

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
if [ -n "$DIS" ]; then
	printf '\n'
	printf 'Disabled (installation.json; not installed):\n'
	printf '%s' "$DIS"
fi
exit 0
