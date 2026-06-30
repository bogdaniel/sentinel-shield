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

TARGET=""; APPLY=0; FORCE=0; PROFILE="laravel-react-docker"; EMIT_PLAN=""; NONINTERACTIVE=0; RECOVER=0

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
TARGET=$(CDPATH= cd -- "$TARGET" && pwd) || { echo "error: cannot resolve target '$TARGET'" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# --- transaction framework (operation-lock + snapshot/restore) ----------------
# Mutation is wrapped in a transaction: a marker is left at operation-lock.json, every
# overwritten/created file is snapshotted, and on failure the snapshots are restored.
SS_DIR="$TARGET/.sentinel-shield"
LOCK="$SS_DIR/operation-lock.json"
TX_ACTIVE=0; TX_SNAP=""; SUM=""
now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

tx_snapshot() { # <relpath>
	# Dedup (snapshot a path at most once, pre-write) + record newly-created paths in
	# 'created' so recovery distinguishes a MODIFIED file (snap MUST exist) from a
	# NEWLY-CREATED file (must be removed) and fails closed on a missing snapshot.
	[ -n "$TX_SNAP" ] || return 0
	grep -qxF "$1" "$TX_SNAP/touched" 2>/dev/null && return 0
	if [ -e "$TARGET/$1" ]; then
		mkdir -p "$TX_SNAP/snap/$(dirname -- "$1")"
		cp -p "$TARGET/$1" "$TX_SNAP/snap/$1"
	else
		printf '%s\n' "$1" >> "$TX_SNAP/created"
	fi
	printf '%s\n' "$1" >> "$TX_SNAP/touched"
}
# _tx_rel_safe <relpath> — accept only a project-relative path (no absolute root,
# no '..' traversal); rejects a tampered 'touched' entry escaping $TARGET.
_tx_rel_safe() {
	case "$1" in
		"" | /* | .. | ../* | */.. | */../*) return 1 ;;
		*) return 0 ;;
	esac
}
# _tx_snap_safe <dir> — snapshot dir must live in this target's .sentinel-shield
# .txn-* area with no traversal; rejects a tampered operation-lock snapshot_dir.
_tx_snap_safe() {
	case "$1" in "$SS_DIR"/.txn-*) ;; *) return 1 ;; esac
	case "$1" in *..*) return 1 ;; *) return 0 ;; esac
}
# _tx_lock_valid <lockfile> — jq-structural validation against
# schemas/operation-lock.schema.json (CONTRACT(2)); ajv may be absent so this is the
# authoritative check. Fails closed on any missing/ill-typed field.
_tx_lock_valid() {
	[ -s "$1" ] || return 1
	jq -e '
		(.schema_version == "1") and
		(.operation as $o | ["install","sync","migration","bootstrap"] | index($o) != null) and
		(.target | type == "string" and (length > 0)) and
		(.started_at | type == "string" and (length > 0)) and
		(.pid | type == "number") and
		(.snapshot_dir | type == "string" and (length > 0)) and
		(.state as $s | ["active","rollback-incomplete"] | index($s) != null)
	' "$1" >/dev/null 2>&1
}
tx_rollback() {
	[ -n "$TX_SNAP" ] && [ -f "$TX_SNAP/touched" ] || return 0
	_tx_snap_safe "$TX_SNAP" || { echo "[sentinel-shield][warn] tx: refusing rollback from an unexpected snapshot dir: $TX_SNAP" >&2; return 0; }
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_tx_rel_safe "$_rel" || { echo "[sentinel-shield][warn] tx: skipping unsafe rollback path: $_rel" >&2; continue; }
		if [ -e "$TX_SNAP/snap/$_rel" ]; then
			mkdir -p "$TARGET/$(dirname -- "$_rel")"
			cp -p "$TX_SNAP/snap/$_rel" "$TARGET/$_rel"
		else
			rm -f "$TARGET/$_rel"
		fi
	done < "$TX_SNAP/touched"
}
tx_begin() {
	mkdir -p "$SS_DIR"
	TX_SNAP="$SS_DIR/.txn-$$"
	mkdir -p "$TX_SNAP"
	: > "$TX_SNAP/touched"
	_lk="$LOCK.tmp.$$"
	jq -n --arg op "sync" --arg tgt "$TARGET" --arg at "$(now_utc)" --argjson pid "$$" --arg snap "$TX_SNAP" \
		'{schema_version:"1", operation:$op, target:$tgt, started_at:$at, pid:$pid, snapshot_dir:$snap, state:"active"}' > "$_lk" \
		&& mv -- "$_lk" "$LOCK"
	TX_ACTIVE=1
}
tx_commit() {
	TX_ACTIVE=0
	rm -f "$LOCK" 2>/dev/null || true
	[ -n "$TX_SNAP" ] && rm -rf "$TX_SNAP" 2>/dev/null || true
	TX_SNAP=""
}
tx_detect_stale() {
	[ -f "$LOCK" ] || return 0
	_op=$(jq -r '.operation // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	_at=$(jq -r '.started_at // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	echo "error: an interrupted Sentinel Shield operation was detected." >&2
	echo "       a previous '$_op' (started $_at) did not finish; $LOCK is present." >&2
	echo "       recover (roll back the partial run) with:" >&2
	echo "         sh scripts/sync-baseline.sh --target '$TARGET' --recover" >&2
	exit 4
}
# _tx_mark_incomplete — best-effort stamp state="rollback-incomplete" onto a parseable
# lock; never removes the lock, leaves the retained lock as-is on any error.
_tx_mark_incomplete() {
	[ -f "$LOCK" ] && jq -e . "$LOCK" >/dev/null 2>&1 || return 0
	_mi="$LOCK.tmp.$$"
	if jq '.state = "rollback-incomplete"' "$LOCK" > "$_mi" 2>/dev/null && mv -- "$_mi" "$LOCK"; then :; else
		rm -f "$_mi" 2>/dev/null || true
	fi
}
# _tx_recover_fail <path> <operation> <detail> — FAIL CLOSED: retain the lock AND every
# snapshot, print the exact failing path+operation and a manual recovery procedure, exit 4.
_tx_recover_fail() {
	_tx_mark_incomplete
	{
		echo "error: recovery FAILED — the interrupted operation was NOT rolled back (state retained)."
		echo "       failing path:      $1"
		echo "       failing operation: $2"
		echo "       detail:            $3"
		echo "       RETAINED for manual recovery (nothing was deleted):"
		echo "         lock:     $LOCK"
		[ -n "${_snap:-}" ] && echo "         snapshot: $_snap"
		echo "       MANUAL RECOVERY PROCEDURE:"
		echo "         1. Confirm no Sentinel Shield operation is running (see the lock's pid)."
		echo "         2. Resolve the blocking condition above (e.g. a read-only file/dir, a"
		echo "            missing snapshot file, or a tampered lock/manifest)."
		echo "         3. For each path in <snapshot_dir>/touched, restore"
		echo "            <snapshot_dir>/snap/<path> over <target>/<path> (or delete <target>/<path>"
		echo "            when no snapshot exists), then verify the target matches the snapshot."
		echo "         4. Re-run --recover; only once it reports success is $LOCK removed."
	} >&2
	exit 4
}
# _tx_recover_apply — validated rollback of TX_SNAP with post-rollback verification.
_tx_recover_apply() {
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_tx_rel_safe "$_rel" || _tx_recover_fail "$_rel" "validate-touched-path" "touched path is absolute or contains '..' (refusing to restore outside the target)"
	done < "$TX_SNAP/touched"
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		if [ -e "$TX_SNAP/snap/$_rel" ]; then
			mkdir -p "$TARGET/$(dirname -- "$_rel")" || _tx_recover_fail "$_rel" "restore-mkdir" "could not recreate the parent directory for the restored file"
			cp -p "$TX_SNAP/snap/$_rel" "$TARGET/$_rel" || _tx_recover_fail "$_rel" "restore-copy" "could not restore the prior file (read-only target or permission denied)"
		else
			rm -f "$TARGET/$_rel" 2>/dev/null || _tx_recover_fail "$_rel" "remove-created" "could not remove the newly-created file (read-only directory?)"
			[ -e "$TARGET/$_rel" ] && _tx_recover_fail "$_rel" "remove-created" "newly-created file is still present after removal"
		fi
	done < "$TX_SNAP/touched"
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		if [ -e "$TX_SNAP/snap/$_rel" ]; then
			cmp -s "$TX_SNAP/snap/$_rel" "$TARGET/$_rel" || _tx_recover_fail "$_rel" "post-verify" "restored file does not match its snapshot"
		else
			[ -e "$TARGET/$_rel" ] && _tx_recover_fail "$_rel" "post-verify" "newly-created file is still present after rollback"
		fi
	done < "$TX_SNAP/touched"
	return 0
}
# tx_recover — FAIL-CLOSED rollback: clears snapshot+lock and exits 0 ONLY when EVERY
# recovery-contract step holds; otherwise retains lock + snapshots and exits 4.
tx_recover() {
	if [ ! -f "$LOCK" ]; then echo "No interrupted operation found ($LOCK absent); nothing to recover."; exit 0; fi
	_tx_lock_valid "$LOCK" || _tx_recover_fail "$LOCK" "lock-schema-validation" "operation-lock is missing fields, mistyped, or not schema-conformant"
	_snap=$(jq -r '.snapshot_dir' "$LOCK" 2>/dev/null || true)
	_ltarget=$(jq -r '.target' "$LOCK" 2>/dev/null || true)
	[ "$_ltarget" = "$TARGET" ] || _tx_recover_fail "$LOCK" "target-mismatch" "lock target '$_ltarget' != current canonical target '$TARGET'"
	_tx_snap_safe "$_snap" || _tx_recover_fail "$_snap" "snapshot-dir-unsafe" "snapshot_dir is not canonically contained in $SS_DIR/.txn-*"
	[ -d "$_snap" ] || _tx_recover_fail "$_snap" "snapshot-dir-missing" "snapshot_dir does not exist"
	[ -f "$_snap/touched" ] && [ -r "$_snap/touched" ] || _tx_recover_fail "$_snap/touched" "touched-manifest-missing" "the touched manifest is absent or unreadable"
	TX_SNAP="$_snap"
	_tx_recover_apply || _tx_recover_fail "$_snap" "rollback" "rollback did not complete"
	rm -rf "$_snap" 2>/dev/null || true
	rm -f "$LOCK" 2>/dev/null || true
	echo "Recovery complete: rolled back the interrupted operation and cleared $LOCK."
	exit 0
}
ss_cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ "${TX_ACTIVE:-0}" = "1" ]; then
		echo "[sentinel-shield][warn] sync: operation failed/interrupted — rolling back snapshotted files." >&2
		tx_rollback
		rm -f "$LOCK" 2>/dev/null || true
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

SUM=$(mktemp); : > "$SUM"

sync_entry() { # <source> <target> <mode>
	_src="$ROOT/$1"; _tgt="$TARGET/$2"; _mode="$3"
	if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then
		echo "project-local-preserved (protected): $2"; echo preserved >> "$SUM"; return
	fi
	[ -e "$_src" ] || { echo "skip (missing in Sentinel Shield): $1"; echo skip >> "$SUM"; return; }
	if [ ! -e "$_tgt" ]; then
		if [ "$_mode" = "manual" ]; then echo "manual-review-needed (absent; copy if wanted): $2"; echo manual >> "$SUM"; return; fi
		if [ "$APPLY" -eq 1 ]; then tx_snapshot "$2"; mkdir -p "$(dirname "$_tgt")"; cp "$_src" "$_tgt"; echo "created (was missing): $2"; else echo "would create (missing): $2"; fi
		echo created >> "$SUM"; return
	fi
	if diff "$_src" "$_tgt" >/dev/null 2>&1; then echo "up-to-date: $2"; echo uptodate >> "$SUM"; return; fi
	# Differs:
	case "$_mode" in
		create-if-missing)
			echo "project-local-preserved (project owns it; NOT overwritten): $2"; echo preserved >> "$SUM" ;;
		overwrite-if-force|sync-managed-block)
			if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
				tx_snapshot "$2"; cp "$_src" "$_tgt"; echo "updated (managed): $2"; echo updated >> "$SUM"
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
