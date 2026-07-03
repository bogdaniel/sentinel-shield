#!/bin/sh
# Sentinel Shield — v1 consumer migration to the installation-metadata era.
#
# Brings an EXISTING v1 consumer (one that has .sentinel-shield/profile.yaml but no
# .sentinel-shield/installation.json) up to the current contract by recording an
# installation record, WITHOUT destroying any local decision:
#   - detect the existing .sentinel-shield/profile.yaml (the v1 marker)
#   - detect the managed workflow + LOCAL modifications to managed files (drift)
#   - detect installed tools (executables present in the project)
#   - CREATE .sentinel-shield/installation.json per schemas/installation.schema.json
#   - PRESERVE accepted-risks.json and project-local configs (NEVER overwritten)
#   - emit a CONFLICT REPORT for managed files that were modified locally
#
# SAFE BY DEFAULT: dry-run unless --apply. A modified managed file is NEVER overwritten
# (this tool does not write managed files at all — it only records metadata and warns).
# An existing installation.json is left in place unless --force is given.
#
# Usage:
#   sh scripts/migrate-v1.sh --target <dir>                      # dry-run report
#   sh scripts/migrate-v1.sh --target <dir> --apply              # write installation.json
#   sh scripts/migrate-v1.sh --target <dir> --profile laravel --apply
#   sh scripts/migrate-v1.sh --target <dir> --tool-mode require-existing --apply
#
# TRANSACTIONAL SAFETY (--apply only): installation.json is snapshotted before the write and a
# transaction marker is left at .sentinel-shield/operation-lock.json; the record is written
# ATOMICALLY (temp + mv) and stamped to schema_version "2"; on failure the prior record is
# restored. A lock from an ungraceful kill is DETECTED on the next --apply and recovered with
# --recover.
#
# Exit: 0 ok (report, write, or recovery); 1 write failure; 2 invalid invocation / missing jq /
#       not a v1 consumer; 4 execution error / interrupted prior operation (stale lock; --recover).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"
# shellcheck source=scripts/lib/profile-compose.sh
. "$SCRIPT_DIR/lib/profile-compose.sh"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$SCRIPT_DIR/lib/installation-metadata.sh"

TARGET=""; APPLY=0; FORCE=0; PROFILE=""; TOOL_MODE="require-existing"; RECOVER=0
VERSION="${SENTINEL_SHIELD_VERSION:-1.9.1}"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: migrate-v1.sh --target <dir> [--profile <name>] [--tool-mode <mode>] [--apply] [--force] [--version <v>]
  --target <dir>     Existing v1 consumer directory (required; must hold .sentinel-shield/profile.yaml).
  --profile <name>   Profile to record (default: first entry of profile.yaml 'profiles:', else laravel-react-docker).
  --tool-mode <m>    Provisioning mode recorded in installation.json: config-only | require-existing | bootstrap-tools (default: require-existing).
  --apply            Write .sentinel-shield/installation.json. Default: dry-run (report only).
  --force            Overwrite an EXISTING installation.json (default: leave it untouched).
  --version <v>      Sentinel Shield version to record (default: $SENTINEL_SHIELD_VERSION or 1.9.1).
  --recover          Roll back an interrupted prior run (restore the snapshot, clear the lock) and exit.
  -h, --help         Show help.
NEVER overwrites accepted-risks.json, phpstan-baseline.neon, project-owned configs, or managed files.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--tool-mode) TOOL_MODE="${2:?--tool-mode requires a value}"; shift 2 ;;
		--version) VERSION="${2:?--version requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--force) FORCE=1; shift ;;
		--dry-run) APPLY=0; shift ;;
		--recover) RECOVER=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) log_error "unknown argument '$1'"; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { log_error "--target is required"; usage; exit 2; }
[ -d "$TARGET" ] || { log_error "target '$TARGET' is not a directory"; exit 2; }
TARGET=$(CDPATH= cd -P -- "$TARGET" && pwd -P)
command_exists jq || { log_error "jq is required."; exit 2; }
case "$TOOL_MODE" in config-only|require-existing|bootstrap-tools) ;; *) log_error "invalid --tool-mode '$TOOL_MODE' (config-only|require-existing|bootstrap-tools)"; exit 2 ;; esac

# --- transaction framework (operation-lock + snapshot/restore) ----------------
# migrate only writes installation.json, but it does so under the same transaction contract:
# snapshot the prior record, leave a lock, write+stamp atomically, restore on failure.
SS_DIR="$TARGET/.sentinel-shield"
LOCK="$SS_DIR/operation-lock.json"
TX_OP="migration"; TX_SELF="scripts/migrate-v1.sh"; TX_ACTIVE=0; TX_SNAP=""; TOOLS_MANIFEST=""; PREVIEW_DIR=""
# shellcheck source=scripts/lib/transaction.sh
. "$SCRIPT_DIR/lib/transaction.sh"

ss_cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ "${TX_ACTIVE:-0}" = "1" ]; then
		log_warn "migrate: operation failed/interrupted — rolling back the installation record."
		tx_rollback
		rm -f "$LOCK" 2>/dev/null || true
		[ -n "${TX_SNAP:-}" ] && rm -rf "$TX_SNAP" 2>/dev/null || true
		TX_ACTIVE=0
		[ "$_rc" -eq 0 ] && _rc=4
	fi
	[ -n "${TOOLS_MANIFEST:-}" ] && rm -f "$TOOLS_MANIFEST" 2>/dev/null || true
	[ -n "${PREVIEW_DIR:-}" ] && rm -rf "$PREVIEW_DIR" 2>/dev/null || true
	exit "$_rc"
}
trap ss_cleanup EXIT INT TERM

# --recover is a standalone mode: restore + clear the lock, then exit.
[ "$RECOVER" -eq 1 ] && tx_recover

PROFILE_YAML="$TARGET/.sentinel-shield/profile.yaml"
[ -f "$PROFILE_YAML" ] || { log_error "not a v1 consumer: '$PROFILE_YAML' not found. Use install-baseline.sh for a fresh install."; exit 2; }

# Resolve the profile name: explicit --profile, else first 'profiles:' list item, else default.
if [ -z "$PROFILE" ]; then
	PROFILE=$(awk '
		/^profiles:/{f=1; next}
		f && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/,""); sub(/[[:space:]]+#.*$/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); print; exit }
		f && /^[^[:space:]#]/ { exit }
	' "$PROFILE_YAML" 2>/dev/null || true)
fi
[ -n "$PROFILE" ] || PROFILE="laravel-react-docker"

# Resolve the manifest (named profile OR combinations/<name>) in this Sentinel Shield repo.
MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { log_error "no manifest for profile '$PROFILE' (looked in profiles/$PROFILE/ and profiles/combinations/). Pass --profile."; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { log_error "manifest is not valid JSON: $MANIFEST"; exit 2; }

# profile_schema = the profile's tool_policy_version (0 if absent).
PROFILE_SCHEMA=$(jq -r '.tool_policy_version // 0' "$MANIFEST" 2>/dev/null || echo 0)

# Compose the merged tools map (resolves `extends`, so combination profiles work too).
# Write it to a temp manifest-shaped file so the compat-resolver readers can use it.
COMPOSED_TOOLS=$(PC_REPO_ROOT="$ROOT" pc_compose_tools "$PROFILE") \
	|| { log_error "could not compose tools for profile '$PROFILE'."; exit 2; }
TOOLS_MANIFEST=$(mktemp)
printf '%s' "$COMPOSED_TOOLS" | jq '{tools: .}' > "$TOOLS_MANIFEST"

echo "------------------------------------------------------------"
echo "Sentinel Shield — v1 consumer migration"
echo "Target:    $TARGET"
echo "Profile:   $PROFILE   ($MANIFEST)"
echo "Version:   $VERSION    profile_schema=$PROFILE_SCHEMA   tool_mode=$TOOL_MODE"
echo "Mode:      $([ "$APPLY" -eq 1 ] && echo APPLY || echo 'dry-run (default; re-run with --apply)')"
echo "------------------------------------------------------------"

# --- classify managed vs project-owned files (from the resolved manifest) ----
# managed: Sentinel Shield owns/overwrites on sync (overwrite-if-force, sync-managed-block).
# project-owned: created-once / never overwritten (create-if-missing) + hard-protected files.
MANAGED_FILES=""; PROJECT_FILES=""; CONFLICTS=""; CONFLICT_N=0
ENTRIES=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.source)\t\(.target)\t\(.mode)"' "$MANIFEST")
_oifs=$IFS
IFS='
'
for _row in $ENTRIES; do
	IFS=$_oifs
	[ -n "$_row" ] || { IFS='
'; continue; }
	_src=${_row%%"$(printf '\t')"*}
	_rest=${_row#*"$(printf '\t')"}
	_tgt=${_rest%%"$(printf '\t')"*}
	_mode=${_rest#*"$(printf '\t')"}
	case "$_mode" in
		overwrite-if-force|sync-managed-block)
			MANAGED_FILES="$MANAGED_FILES $_tgt"
			# Conflict detection: a managed file that exists locally but differs from the
			# Sentinel Shield source has been modified by the consumer.
			if [ -f "$TARGET/$_tgt" ] && [ -f "$ROOT/$_src" ]; then
				if ! diff "$ROOT/$_src" "$TARGET/$_tgt" >/dev/null 2>&1; then
					CONFLICTS="$CONFLICTS $_tgt"
					CONFLICT_N=$((CONFLICT_N + 1))
				fi
			fi
			;;
		create-if-missing)
			[ -e "$TARGET/$_tgt" ] && PROJECT_FILES="$PROJECT_FILES $_tgt"
			;;
		*) : ;;  # manual / unknown: not recorded as managed or project-owned
	esac
	IFS='
'
done
IFS=$_oifs

# Hard-protected, project-local files are always project-owned when present.
for _pl in .sentinel-shield/accepted-risks.json phpstan-baseline.neon .sentinel-shield/profile.yaml; do
	[ -e "$TARGET/$_pl" ] && PROJECT_FILES="$PROJECT_FILES $_pl"
done

# --- detect installed tools --------------------------------------------------
# enabled: declared (non-disabled) tools that are present — an executable[] candidate is
# detected, OR the tool declares no local executable (external/CI scanner). disabled:
# tools the composed policy marks policy=disabled.
ENABLED=""; DISABLED=""
KEYS=$(cr_tool_keys "$TOOLS_MANIFEST")
IFS='
'
for _k in $KEYS; do
	IFS=$_oifs
	[ -n "$_k" ] || { IFS='
'; continue; }
	_pol=$(cr_tool_policy "$TOOLS_MANIFEST" "$_k")
	if [ "$_pol" = "disabled" ]; then
		DISABLED="$DISABLED $_k"
		IFS='
'; continue
	fi
	_exes=$(cr_tool_executables "$TOOLS_MANIFEST" "$_k")
	if [ -z "$_exes" ] || cr_tool_detected "$TARGET" "$TOOLS_MANIFEST" "$_k"; then
		ENABLED="$ENABLED $_k"
	fi
	IFS='
'
done
IFS=$_oifs

# nl_uniq <space-separated tokens> — newline-separated, sorted-unique (im_write input shape).
nl_uniq() {
	[ -n "$(printf '%s' "$1" | tr -d ' ')" ] || { printf ''; return 0; }
	# shellcheck disable=SC2086
	printf '%s\n' $1 | sort -u
}
# disp <newline list> — render a JSON array (for the human "Detected" summary).
disp() { printf '%s\n' "$1" | jq -R . | jq -s 'map(select(length>0))'; }

MANAGED_NL=$(nl_uniq "$MANAGED_FILES")
PROJECT_NL=$(nl_uniq "$PROJECT_FILES")
ENABLED_NL=$(nl_uniq "$ENABLED")
DISABLED_NL=$(nl_uniq "$DISABLED")

INSTALL_JSON="$TARGET/.sentinel-shield/installation.json"

# --- conflict report ---------------------------------------------------------
echo "Detected:"
echo "  enabled tools:    $(disp "$ENABLED_NL" | jq -r 'join(", ") | if .=="" then "(none)" else . end')"
echo "  disabled tools:   $(disp "$DISABLED_NL" | jq -r 'join(", ") | if .=="" then "(none)" else . end')"
echo "  managed files:    $(disp "$MANAGED_NL" | jq -r 'length') tracked"
echo "  project-owned:    $(disp "$PROJECT_NL" | jq -r 'length') preserved (never overwritten)"
echo "------------------------------------------------------------"
if [ "$CONFLICT_N" -gt 0 ]; then
	log_warn "CONFLICT: $CONFLICT_N managed file(s) modified locally (they will NOT be overwritten by this migration):"
	for _c in $CONFLICTS; do
		echo "  ! $_c  (local edits differ from Sentinel Shield source; reconcile via 'sync-baseline.sh --apply --force' after review)" >&2
	done
else
	echo "No managed-file conflicts detected (managed files match Sentinel Shield, or are absent)."
fi
echo "------------------------------------------------------------"

# ss_stamp_v2 <installation.json> — ATOMICALLY stamp schema_version "2" + updated_at onto the
# record im_write produced, so the migrated record matches schemas/installation.schema.json.
ss_stamp_v2() {
	_f="$1"; _now=$(timestamp_utc); _tmp="$_f.tmp.$$"
	jq --arg up "$_now" '. + {schema_version: "2", updated_at: $up}' "$_f" > "$_tmp" \
		&& mv -- "$_tmp" "$_f" || { rm -f "$_tmp" 2>/dev/null || true; return 1; }
}

# --- write (or preview) the installation record ------------------------------
if [ -f "$INSTALL_JSON" ] && [ "$FORCE" -eq 0 ]; then
	log_warn "installation.json already exists: $INSTALL_JSON (left untouched; pass --force to overwrite)."
	echo "Existing installation record preserved. Nothing else to do."
	exit 0
fi

if [ "$APPLY" -eq 0 ]; then
	# Build the exact record (via the shared writer + validator) into a throwaway dir
	# so the preview is byte-identical to what --apply would write.
	PREVIEW_DIR=$(mktemp -d)
	if im_write "$PREVIEW_DIR" "$VERSION" "$PROFILE" "$PROFILE_SCHEMA" "$TOOL_MODE" "" \
		"$MANAGED_NL" "$PROJECT_NL" "$ENABLED_NL" "$DISABLED_NL" >/dev/null 2>&1 \
		&& ss_stamp_v2 "$PREVIEW_DIR/.sentinel-shield/installation.json"; then
		echo "DRY-RUN: would write $INSTALL_JSON:"
		cat "$PREVIEW_DIR/.sentinel-shield/installation.json"
	else
		log_error "internal: could not build a conforming installation record."
		rm -rf "$PREVIEW_DIR"; PREVIEW_DIR=""; exit 2
	fi
	rm -rf "$PREVIEW_DIR"; PREVIEW_DIR=""
	echo "------------------------------------------------------------"
	echo "Re-run with --apply to write it. accepted-risks.json / profile.yaml / project configs are never touched."
	exit 0
fi

# APPLY: transactional write — detect a stale lock, snapshot the prior record, write+stamp.
tx_detect_stale
tx_begin
tx_snapshot ".sentinel-shield/installation.json"
im_write "$TARGET" "$VERSION" "$PROFILE" "$PROFILE_SCHEMA" "$TOOL_MODE" "" \
	"$MANAGED_NL" "$PROJECT_NL" "$ENABLED_NL" "$DISABLED_NL" \
	|| { log_error "failed to write installation record."; exit 1; }
ss_stamp_v2 "$INSTALL_JSON" || { log_error "failed to stamp installation record to schema_version 2."; exit 1; }
tx_commit
echo "Migration complete. Wrote installation record (schema_version 2); preserved all project-local files."
echo "Next: review managed-file conflicts (if any) and run 'sync-baseline.sh --target $TARGET' for drift."
