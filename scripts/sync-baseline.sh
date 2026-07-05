#!/bin/sh
# Sentinel Shield — profile-driven baseline sync (v0.1.11).
# POSIX sh. Updates a consuming project from a newer Sentinel Shield release WITHOUT
# destroying local decisions. SAFE BY DEFAULT: --dry-run unless --apply; --force only
# touches MANAGED files; NEVER overwrites accepted-risks.json, phpstan-baseline.neon,
# project-owned (create-if-missing) files, or project code.
#
# Usage:
#   sh scripts/sync-baseline.sh --target <dir>                       # dry-run drift report
#   sh scripts/sync-baseline.sh --target <dir> --apply --force       # update managed files
#   sh scripts/sync-baseline.sh --target <dir> --profile laravel --apply --force
#   sh scripts/sync-baseline.sh --target <dir> --recover             # roll back an interrupted run
#
# Categories reported: created | updated | up-to-date | manual-review-needed |
#                      project-local-preserved
#
# TRANSACTIONAL SAFETY (--apply only): a complete plan is emitted before any mutation;
# every managed file is snapshotted before it is overwritten; a transaction marker is left
# at .sentinel-shield/operation-lock.json; on failure/interruption the snapshots are
# restored automatically. A lock from an ungraceful kill is DETECTED on the next --apply and
# recovered with --recover. installation.json's last_successful_sync/updated_at are bumped
# ATOMICALLY (temp + mv) and never partially.
#
# Exit codes: 0 success; 2 invalid config/input; 4 execution error / interrupted prior
# operation (stale operation-lock; run --recover).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# Opt-in machine-readable envelope (a no-op unless `--output json` is passed).
# Sourced defensively: the envelope layer is an optional add-on, so the command
# still works if the lib is absent (e.g. a minimal copied tree in a test fixture).
if [ -f "$SCRIPT_DIR/lib/output-contract.sh" ]; then
  # shellcheck source=scripts/lib/output-contract.sh
  . "$SCRIPT_DIR/lib/output-contract.sh"
  oc_intercept "sync-baseline" "$0" "$@"
fi

TARGET=""; APPLY=0; FORCE=0; PROFILE="laravel-react-docker"; EMIT_PLAN=""; EMIT_INSTALL_PLAN=""; NONINTERACTIVE=0; RECOVER=0

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: sync-baseline.sh --target <dir> [--profile <name>] [--apply] [--force]
                        [--emit-plan <path>] [--non-interactive]
  --target <dir>     Consuming project directory (required).
  --profile <name>   Profile manifest (default: laravel-react-docker).
  --apply            Write changes (default: dry-run drift report).
  --force            Update MANAGED files (overwrite-if-force / sync-managed-block) only.
  --emit-plan <path> Write the read-only tool resolution plan (JSON) to <path> while syncing.
  --emit-install-plan <path> Write the DETERMINISTIC installation plan (JSON) to <path>
                     (schemas/installation-plan.schema.json): the per-file actions this sync would take.
  --non-interactive  Never prompt (accepted for CI parity; this sync does not prompt).
  --recover          Roll back an interrupted prior run (restore snapshots, clear the lock) and exit.
  -h, --help         Show help.
NEVER overwrites: accepted-risks.json, phpstan-baseline.neon, project-owned (create-if-missing)
files, or project code. Those are reported as project-local-preserved.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--force) FORCE=1; shift ;;
		--dry-run) APPLY=0; shift ;;
		--emit-plan) EMIT_PLAN="${2:?--emit-plan requires a value}"; shift 2 ;;
		--emit-install-plan) EMIT_INSTALL_PLAN="${2:?--emit-install-plan requires a value}"; shift 2 ;;
		--non-interactive) NONINTERACTIVE=1; shift ;;
		--recover) RECOVER=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { echo "error: --target is required" >&2; usage; exit 2; }
[ -d "$TARGET/.sentinel-shield" ] || { echo "error: '$TARGET/.sentinel-shield' not found — run install-baseline.sh first." >&2; exit 2; }
# Canonicalise the target so the operation-lock 'target'/'snapshot_dir' are canonical
# (CONTRACT(2)) and recovery can compare them against the current canonical target.
TARGET=$(CDPATH= cd -P -- "$TARGET" && pwd -P) || { echo "error: cannot resolve target '$TARGET'" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# --- transaction framework (operation-lock + snapshot/restore) ----------------
# Mutation is wrapped in a transaction: a marker is left at operation-lock.json, every
# overwritten/created file is snapshotted, and on failure the snapshots are restored.
SS_DIR="$TARGET/.sentinel-shield"
LOCK="$SS_DIR/operation-lock.json"
TX_OP="sync"; TX_SELF="scripts/sync-baseline.sh"; TX_ACTIVE=0; TX_SNAP=""; SUM=""
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
# shellcheck source=scripts/lib/transaction.sh
. "$SCRIPT_DIR/lib/transaction.sh"

ss_cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ "${TX_ACTIVE:-0}" = "1" ]; then
		echo "[sentinel-shield][warn] sync: operation failed/interrupted — rolling back snapshotted files." >&2
		tx_rollback
		rm -f "$LOCK" 2>/dev/null || true
		_tx_rm "$(_tx_lockdir)"
		[ -n "${TX_SNAP:-}" ] && rm -rf "$TX_SNAP" 2>/dev/null || true
		TX_ACTIVE=0
		[ "$_rc" -eq 0 ] && _rc=4
	fi
	[ -n "${SUM:-}" ] && rm -f "$SUM" 2>/dev/null || true
	exit "$_rc"
}
trap ss_cleanup EXIT INT TERM

# --recover is a standalone mode: restore + clear the lock, then exit.
[ "$RECOVER" -eq 1 ] && tx_recover

MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { echo "error: no manifest for profile '$PROFILE'" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "error: manifest not valid JSON: $MANIFEST" >&2; exit 2; }

# --emit-plan: write the read-only resolver plan (JSON) via resolve-tool-plan.sh, which now
# resolves the COMPOSED effective profile (named OR combinations/<name>).
if [ -n "$EMIT_PLAN" ]; then
	if sh "$SCRIPT_DIR/resolve-tool-plan.sh" --profile "$PROFILE" --target "$TARGET" --format json > "$EMIT_PLAN" 2>/dev/null; then
		echo "Tool plan written: $EMIT_PLAN"
	else
		echo "warn: could not emit tool plan to '$EMIT_PLAN' (profile '$PROFILE' could not be resolved)." >&2
		rm -f "$EMIT_PLAN" 2>/dev/null || true
	fi
fi

[ "$APPLY" -eq 0 ] && echo "DRY-RUN drift report (no files written)." || echo "APPLY mode (managed files only; --force=$([ "$FORCE" -eq 1 ] && echo yes || echo no))."
echo "Profile: $PROFILE   Source: $ROOT   Target: $TARGET"
echo "------------------------------------------------------------"

PROTECT=" .sentinel-shield/accepted-risks.json phpstan-baseline.neon "
for p in $(jq -r '(.never_touch // [])[]' "$MANIFEST" 2>/dev/null); do PROTECT="$PROTECT$p "; done
is_protected() { case "$PROTECT" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# emit_install_plan <path> — write a DETERMINISTIC installation-plan JSON
# (schemas/installation-plan.schema.json): the read-only per-file (mode, action, source, target)
# decisions this sync WOULD make, sorted by target, plus the protected set. No timestamps, no
# secrets, fixed key order — deterministic for a given profile/flags/target.
emit_install_plan() {
	_eip_out="$1"; _eip_ops=$(mktemp)
	jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.mode)\t\(.source)\t\(.target)"' "$MANIFEST" \
	| while IFS="$(printf '\t')" read -r _m _s _t; do
		[ -n "$_s" ] || continue
		if is_protected "$_t" || [ "$(basename "$_t")" = "accepted-risks.json" ]; then
			_act="protected"
		else
			case "$_m" in
				manual) _act="manual" ;;
				create-if-missing) if [ -e "$TARGET/$_t" ]; then _act="skip-existing"; else _act="create"; fi ;;
				overwrite-if-force|sync-managed-block)
					if [ -e "$TARGET/$_t" ]; then
						if [ "$FORCE" -eq 1 ]; then _act="overwrite-managed"; else _act="skip-managed-no-force"; fi
					else _act="create"; fi ;;
				*) _act="manual" ;;
			esac
		fi
		jq -cn --arg mode "$_m" --arg action "$_act" --arg source "$_s" --arg target "$_t" \
			'{mode:$mode, action:$action, source:$source, target:$target}'
	done | jq -s 'sort_by(.target)' > "$_eip_ops"
	_eip_prot=$(printf '%s' "$PROTECT" | tr ' ' '\n' | sed '/^$/d' | sort -u | jq -R . | jq -s .)
	jq -n \
		--slurpfile ops "$_eip_ops" \
		--argjson protected "$_eip_prot" \
		--arg profile "$PROFILE" \
		--argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
		--argjson force "$([ "$FORCE" -eq 1 ] && echo true || echo false)" \
		'{schema_version:"1", generator:"sync-baseline", profile:$profile, mode:"", apply:$apply, force:$force, protected:$protected, operations:$ops[0]}' \
		> "$_eip_out" || { rm -f "$_eip_ops"; echo "error: could not write installation plan to '$_eip_out'" >&2; return 1; }
	rm -f "$_eip_ops"
	echo "Installation plan written: $_eip_out"
}
[ -n "$EMIT_INSTALL_PLAN" ] && emit_install_plan "$EMIT_INSTALL_PLAN"

SUM=$(mktemp); : > "$SUM"

sync_entry() { # <source> <target> <mode>
	_src="$ROOT/$1"; _tgt="$TARGET/$2"; _mode="$3"
	if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then
		echo "project-local-preserved (protected): $2"; echo preserved >> "$SUM"; return
	fi
	[ -e "$_src" ] || { echo "skip (missing in Sentinel Shield): $1"; echo skip >> "$SUM"; return; }
	if [ ! -e "$_tgt" ]; then
		if [ "$_mode" = "manual" ]; then echo "manual-review-needed (absent; copy if wanted): $2"; echo manual >> "$SUM"; return; fi
		if [ "$APPLY" -eq 1 ]; then tx_install_file "$_src" "$2"; echo "created (was missing): $2"; else echo "would create (missing): $2"; fi
		echo created >> "$SUM"; return
	fi
	if diff "$_src" "$_tgt" >/dev/null 2>&1; then echo "up-to-date: $2"; echo uptodate >> "$SUM"; return; fi
	# Differs:
	case "$_mode" in
		create-if-missing)
			echo "project-local-preserved (project owns it; NOT overwritten): $2"; echo preserved >> "$SUM" ;;
		overwrite-if-force|sync-managed-block)
			if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
				tx_install_file "$_src" "$2"; echo "updated (managed): $2"; echo updated >> "$SUM"
			else
				echo "manual-review-needed (managed drift; --apply --force to update): $2"; echo manual >> "$SUM"
			fi ;;
		*) echo "manual-review-needed: $2"; echo manual >> "$SUM" ;;
	esac
}

# Emit the COMPLETE plan BEFORE any mutation, then open the transaction (apply only). A stale
# lock from a prior ungraceful kill is detected here and blocks until --recover.
echo "PLAN ($([ "$APPLY" -eq 1 ] && echo APPLY || echo dry-run)) — managed files updated only with --force; protected files never written:"
jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "  - [\(.mode)] \(.source) -> \(.target)"' "$MANIFEST"
echo "  protected (never written):$PROTECT"
echo "------------------------------------------------------------"
if [ "$APPLY" -eq 1 ]; then
	tx_detect_stale
	tx_begin
fi

ENTRIES=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.source)\t\(.target)\t\(.mode)"' "$MANIFEST")
printf '%s\n' "$ENTRIES" | while IFS="$(printf '\t')" read -r s t m; do [ -n "$s" ] || continue; sync_entry "$s" "$t" "$m"; done

# Record the successful sync in installation.json (ATOMIC temp + mv), then close the txn.
# Only bump an EXISTING record — sync never creates installation.json (that is install/migrate).
if [ "$APPLY" -eq 1 ]; then
	_inst="$SS_DIR/installation.json"
	if [ -f "$_inst" ] && jq -e . "$_inst" >/dev/null 2>&1; then
		tx_snapshot ".sentinel-shield/installation.json"
		_now=$(now_utc); _tmp="$_inst.tmp.$$"
		# FAIL CLOSED: a failed jq write or mv must trip the transaction-failure path
		# (rolls back + clears the lock) BEFORE tx_commit — never warn-and-continue.
		if jq --arg t "$_now" '.last_successful_sync=$t | .updated_at=$t' "$_inst" > "$_tmp" && mv -- "$_tmp" "$_inst"; then
			:
		else
			rm -f "$_tmp" 2>/dev/null || true
			echo "[sentinel-shield][error] sync: could not update installation.json metadata; rolling back." >&2
			exit 4
		fi
	fi
	tx_commit
fi

echo "------------------------------------------------------------"
echo "SUMMARY: created=$(grep -c '^created' "$SUM" 2>/dev/null || echo 0)  updated=$(grep -c '^updated' "$SUM" 2>/dev/null || echo 0)  up-to-date=$(grep -c '^uptodate' "$SUM" 2>/dev/null || echo 0)  manual-review-needed=$(grep -c '^manual' "$SUM" 2>/dev/null || echo 0)  project-local-preserved=$(grep -c '^preserved' "$SUM" 2>/dev/null || echo 0)  skipped=$(grep -c '^skip' "$SUM" 2>/dev/null || echo 0)"
if [ "$APPLY" -eq 0 ]; then
	echo "Dry-run. To update managed files after review: sh scripts/sync-baseline.sh --target '$TARGET' --apply --force"
fi
echo "accepted-risks.json / phpstan-baseline.neon / project-owned config were NOT modified."
