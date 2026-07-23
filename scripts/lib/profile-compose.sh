#!/bin/sh
# Sentinel Shield — profile composition / inheritance (DEPRECATED shim).
#
# DEPRECATION: this file no longer implements its own composition. The canonical
# composition / inheritance / override / applicability / one-of algorithm lives
# ONLY in scripts/lib/effective-profile.sh (ep_resolve). This shim is kept solely
# for back-compat of the public function name `pc_compose_tools`; it DELEGATES to
# the canonical resolver and emits the resolver's `.tools` map. New code MUST call
# scripts/resolve-effective-profile.sh / ep_resolve directly. (Significant fix 11.)
#
# Usage (CLI):   profile-compose.sh <profile-name>
# Usage (lib):   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"   # first
#                . "$SCRIPT_DIR/lib/profile-compose.sh"
#                pc_compose_tools <name>
# PC_REPO_ROOT (optional) overrides the repo root (mapped to EP_REPO_ROOT).
#
# stdout = merged tools{} JSON (machine-readable only). All logs go to stderr.
# Exit: 0 ok; 2 invalid invocation / missing jq / unknown profile / invalid JSON
#       (all delegated to the canonical resolver, which is fail-closed).
# `set -eu` ONLY when executed directly (dual-use file: sourced as a lib AND run as a CLI).
# Sourced, it must not mutate the caller's shell options; the CLI path still gets set -eu.
case "$0" in *profile-compose.sh) set -eu ;; esac

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_PROFILE_COMPOSE_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_PROFILE_COMPOSE_LOADED=1

# Source the shared library if the caller has not already done so. When run as a
# CLI, $0 points at this file (scripts/lib/); when sourced by a scripts/ wrapper,
# $0 points at that wrapper (scripts/), so check both lib/ shapes.
# ponytail: $0-based lookup is the only locator POSIX sh has when sourced.
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_pc_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_pc_d/sentinel-shield-common.sh" ]; then
		. "$_pc_d/sentinel-shield-common.sh"
	elif [ -f "$_pc_d/lib/sentinel-shield-common.sh" ]; then
		. "$_pc_d/lib/sentinel-shield-common.sh"
	else
		printf '%s\n' "[sentinel-shield][error] profile-compose: cannot locate sentinel-shield-common.sh; source it first." >&2
		exit 2
	fi
fi

# die_cfg <message...> — configuration/input error -> exit 2 (engine convention).
die_cfg() {
	log_error "$*"
	exit 2
}

# Source the canonical resolver (same dir as this file). Mirrors the $0-based
# locator used for the shared library above.
if [ "${__SENTINEL_SHIELD_EFFECTIVE_PROFILE_LOADED:-}" != "1" ]; then
	_pc_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_pc_d/effective-profile.sh" ]; then
		. "$_pc_d/effective-profile.sh"
	elif [ -f "$_pc_d/lib/effective-profile.sh" ]; then
		. "$_pc_d/lib/effective-profile.sh"
	else
		die_cfg "profile-compose: cannot locate effective-profile.sh (canonical resolver)."
	fi
fi

# pc_compose_tools <profile> — print the composed tools{} JSON map on stdout.
# DELEGATES to the canonical resolver; the merge/rank ladder is NOT reimplemented
# here. Honours PC_REPO_ROOT for back-compat by mapping it to EP_REPO_ROOT.
pc_compose_tools() {
	command_exists jq || die_cfg "profile-compose: jq is required."
	[ -n "${1:-}" ] || die_cfg "pc_compose_tools: missing profile name."
	# (B13) Do NOT mutate/export the caller's EP_REPO_ROOT. Run the resolver in a
	# scoped subshell where EP_REPO_ROOT is set only for that call; the caller's
	# environment is unchanged after pc_compose_tools returns.
	# Capture first so the resolver's fail-closed exit(2) propagates (a pipeline
	# would mask it behind jq's status).
	if [ -n "${PC_REPO_ROOT:-}" ]; then
		_pc_eff=$(EP_REPO_ROOT="$PC_REPO_ROOT" ep_resolve "$1") || return $?
	else
		_pc_eff=$(ep_resolve "$1") || return $?
	fi
	printf '%s\n' "$_pc_eff" | jq '.tools'
}

# --- CLI entrypoint (only when executed directly, not when sourced) ----------
case "$0" in
	*profile-compose.sh)
		case "${1:-}" in
			-h | --help) printf 'usage: profile-compose.sh <profile-name>\n'; exit 0 ;;
		esac
		[ $# -eq 1 ] || die_cfg "usage: profile-compose.sh <profile-name>"
		pc_compose_tools "$1"
		;;
esac
