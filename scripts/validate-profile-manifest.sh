#!/bin/sh
# Sentinel Shield — profile-manifest validator CLI (#248).
#
# The command-line face of scripts/lib/profile-schema.sh, so tests, release
# packaging, generated manifests and ad-hoc inspection all run the SAME validator
# the resolver runs. There is no second implementation to drift.
#
# Usage:
#   validate-profile-manifest.sh [--role policy|install] <manifest>...
#   validate-profile-manifest.sh [--role install] --all
#
#   --role policy   (default) the composition surface: identity, tool-policy
#                   version, extends, tools.
#   --role install  additionally requires the install/sync surface (`files`).
#   --all           validate every shipped manifest (profiles/*/profile.manifest.json
#                   and profiles/combinations/*.manifest.json) with role=install.
#   --quiet         emit nothing on success.
#
# Exit codes (shared v2 contract — docs/workflow-execution-model.md#exit-codes):
#   0  every manifest is valid
#   2  invalid invocation, unreadable/unparseable manifest, or a schema/semantic
#      violation (fail-closed: there is no warn-and-continue path)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/profile-schema.sh
. "$SCRIPT_DIR/lib/profile-schema.sh"

usage() {
	printf 'Usage: validate-profile-manifest.sh [--role policy|install] [--quiet] (<manifest>... | --all)\n'
}

ROLE="policy"
ALL=0
QUIET=0
FILES=""
while [ $# -gt 0 ]; do
	case "$1" in
		--role) ROLE="${2:?--role requires a value}"; shift 2 ;;
		--all) ALL=1; ROLE="install"; shift ;;
		--quiet) QUIET=1; shift ;;
		-h | --help) usage; exit 0 ;;
		--) shift; while [ $# -gt 0 ]; do FILES="$FILES$1
"; shift; done ;;
		-*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
		*) FILES="$FILES$1
"; shift ;;
	esac
done

case "$ROLE" in policy | install) ;; *) log_error "--role must be policy or install"; exit 2 ;; esac
command_exists jq || { log_error "jq is required"; exit 2; }

if [ "$ALL" = 1 ]; then
	[ -z "$FILES" ] || { log_error "--all takes no manifest arguments"; exit 2; }
	ROOT=$(ps_repo_root) || { log_error "cannot locate the repo root (no profiles/); set PS_REPO_ROOT"; exit 2; }
	for _m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
		[ -f "$_m" ] && FILES="$FILES$_m
"
	done
	[ -n "$FILES" ] || { log_error "--all found no shipped manifests under $ROOT/profiles/"; exit 2; }
fi

[ -n "$FILES" ] || { log_error "no manifest given"; usage >&2; exit 2; }

RC=0
COUNT=0
# Split ONLY on newline and disable globbing: a manifest path is data, not a
# pattern, and must not be word-split on spaces or expanded by the shell.
OLDIFS=$IFS
IFS='
'
set -f
# shellcheck disable=SC2086
for _f in $FILES; do
	[ -n "$_f" ] || continue
	COUNT=$((COUNT + 1))
	if _errs=$(ps_manifest_errors "$_f" "$ROLE"); then
		[ "$QUIET" = 1 ] || printf 'OK   %s (role=%s)\n' "$_f" "$ROLE"
	else
		RC=2
		printf 'FAIL %s (role=%s)\n' "$_f" "$ROLE"
		printf '%s\n' "$_errs" | while IFS= read -r _l; do
			[ -n "$_l" ] && printf '     %s\n' "$_l"
		done
	fi
done
set +f
IFS=$OLDIFS

[ "$COUNT" -gt 0 ] || { log_error "no manifest was validated"; exit 2; }
exit "$RC"
