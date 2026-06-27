#!/bin/sh
# Sentinel Shield — profile composition / inheritance.
#
# POSIX sh library that can ALSO run as a CLI. Given a profile name, resolve its
# `extends` chain and merge the per-tool `tools{}` policy maps of every base
# profile (parents first, depth-first) then the child, emitting the merged
# `tools{}` map as JSON on stdout.
#
# Merge rule — a tool's STRONGEST policy across the whole chain wins:
#   required > one-of > recommended > optional > external > disabled
# This honours the documented ladder required > recommended > optional > disabled
# (see docs/profile-tool-policy.md), with `one-of` ranked just under `required`
# (it represents a satisfied requirement group) and `external` just above
# `disabled`. A `required` tool can therefore NEVER be downgraded to optional by
# another profile in the chain. On EQUAL policy the later (more specific / child)
# declaration wins, so the child's full tool object is kept. Explicit
# project-level disables are handled elsewhere (the tool-policy.yaml override
# resolver), not here.
#
# Usage (CLI):   profile-compose.sh <profile-name>
# Usage (lib):   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"   # first
#                . "$SCRIPT_DIR/lib/profile-compose.sh"
#                pc_compose_tools <name>
#
# stdout = merged tools{} JSON (machine-readable only). All logs go to stderr.
# Exit: 0 ok; 2 invalid invocation / missing jq / unknown profile / invalid JSON.
set -eu

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

# Policy precedence ranks (higher = stronger). See header for the rationale.
PC_RANK='{"required":5,"one-of":4,"recommended":3,"optional":2,"external":1,"disabled":0}'

# die_cfg <message...> — configuration/input error -> exit 2 (engine convention,
# matching resolve-gates.sh / build-security-summary.sh).
die_cfg() {
	log_error "$*"
	exit 2
}

# pc__repo_root — print the Sentinel Shield repo root (the dir holding profiles/).
# Honours an explicit PC_REPO_ROOT override, else derives from $0 / $PWD.
pc__repo_root() {
	if [ -n "${PC_REPO_ROOT:-}" ] && [ -d "$PC_REPO_ROOT/profiles" ]; then
		printf '%s\n' "$PC_REPO_ROOT"
		return 0
	fi
	_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	for _cand in "$_d/../.." "$_d/.." "$_d" "$PWD"; do
		if [ -d "$_cand/profiles" ]; then
			(CDPATH= cd -- "$_cand" && pwd)
			return 0
		fi
	done
	return 1
}

# pc_manifest_path <repo-root> <profile> — print the manifest path for a profile
# name, or return non-zero (looks in profiles/<name>/ then combinations/).
pc_manifest_path() {
	for _c in "$1/profiles/$2/profile.manifest.json" \
		"$1/profiles/combinations/$2.manifest.json"; do
		[ -f "$_c" ] && { printf '%s\n' "$_c"; return 0; }
	done
	return 1
}

# pc_collect_chain <repo-root> <profile> — append manifest paths (parents first,
# self last) to the global $PC_CHAIN, guarding against cycles/duplicates via
# $PC_VISITED. Deterministic depth-first order (extends resolved in order).
pc_collect_chain() {
	_root="$1"
	_p="$2"
	case " $PC_VISITED " in
		*" $_p "*) return 0 ;;
	esac
	PC_VISITED="$PC_VISITED $_p"
	_mf=$(pc_manifest_path "$_root" "$_p") || die_cfg "profile-compose: unknown profile '$_p' (no manifest in profiles/$_p/ or profiles/combinations/)."
	jq -e . "$_mf" >/dev/null 2>&1 || die_cfg "profile-compose: invalid JSON manifest: $_mf"
	for _parent in $(jq -r '.extends[]? // empty' "$_mf"); do
		pc_collect_chain "$_root" "$_parent"
	done
	PC_CHAIN="$PC_CHAIN $_mf"
}

# pc_compose_tools <profile> — print the merged tools{} JSON map on stdout.
pc_compose_tools() {
	command_exists jq || die_cfg "profile-compose: jq is required."
	[ -n "${1:-}" ] || die_cfg "pc_compose_tools: missing profile name."
	_root=$(pc__repo_root) || die_cfg "profile-compose: cannot locate repo root (no profiles/ dir); set PC_REPO_ROOT."
	PC_CHAIN=""
	PC_VISITED=""
	pc_collect_chain "$_root" "$1"
	# Merge each manifest's tools map in chain order; strongest policy wins and an
	# equal policy lets the later (child) object win. Keys sorted for determinism.
	# shellcheck disable=SC2086
	jq -n --argjson rank "$PC_RANK" '
		reduce inputs as $m ({};
			reduce (($m.tools // {}) | to_entries[]) as $e (.;
				($rank[$e.value.policy] // -1) as $nr
				| (if has($e.key) then ($rank[.[$e.key].policy] // -1) else -2 end) as $cr
				| if $nr >= $cr then .[$e.key] = $e.value else . end
			)
		)
		| to_entries | sort_by(.key) | from_entries
	' $PC_CHAIN
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
