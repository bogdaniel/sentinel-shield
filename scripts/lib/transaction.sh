#!/bin/sh
# Sentinel Shield — shared installer/upgrade/recovery TRANSACTION library (POSIX sh).
#
# Source this file; do NOT execute it. It defines the tx_* machinery that install-baseline.sh,
# sync-baseline.sh and migrate-v1.sh share: the operation-lock marker, per-file snapshot/restore,
# stale-lock detection, and the FAIL-CLOSED recovery contract (schemas/operation-lock.schema.json).
# It was extracted VERBATIM from the three (formerly triplicated) inline copies so behaviour is
# preserved exactly; the only parameterisation is via caller-set globals (below).
#
# All functions are POSIX sh: no Bash arrays, no `local`, no `[[ ]]`, no process substitution.
# This library does NOT enable `set -eu` (the executable caller decides). Logs go to STDERR only.
#
# CALLER CONTRACT — before invoking any tx_* function the sourcing script MUST define:
#   TARGET     canonical absolute path of the consuming project being mutated (cd -P/pwd -P).
#   SS_DIR     "$TARGET/.sentinel-shield"
#   LOCK       "$SS_DIR/operation-lock.json"
#   TX_OP      operation name recorded in the lock: install | sync | migration | bootstrap
#   TX_SELF    this script's repo-relative invocation, used in the --recover hint
#              (e.g. "scripts/install-baseline.sh").
#   TX_ACTIVE  transaction-active flag, initialised to 0.
#   TX_SNAP    snapshot-dir path, initialised to "".
# The caller keeps ownership of its own EXIT/INT/TERM handler (ss_cleanup): it calls tx_rollback
# from there. This library never installs a trap.
#
# Requires: jq; and scripts/lib/sentinel-shield-common.sh (log_*, timestamp_utc, ensure_dir),
# which this file sources with an include guard so double-sourcing is safe.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_TRANSACTION_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_TRANSACTION_LOADED=1

# Pull in log_*, timestamp_utc, ensure_dir. __ss_tx_dir resolves THIS library's directory so
# common resolves regardless of the caller's SCRIPT_DIR.
__ss_tx_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	# Prefer the caller's SCRIPT_DIR/lib, else this file's own directory.
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/sentinel-shield-common.sh" ]; then
		. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
	elif [ -f "$__ss_tx_dir/sentinel-shield-common.sh" ]; then
		. "$__ss_tx_dir/sentinel-shield-common.sh"
	fi
fi

# --- append-only transaction JOURNAL -----------------------------------------
# Every transaction appends structured, chained entries to
# <target>/.sentinel-shield/transaction-journal.jsonl (one JSON object per line,
# schemas/transaction-journal.schema.json). Journaling is a best-effort AUDIT trail: a
# journal-write failure is logged (visible, never hidden) but never aborts a real
# install/sync/migrate/rollback. It records NO secrets and NO file contents — only paths and
# short phase details. Integrity: each entry carries prev=(previous entry's hash) and
# hash=H(entry-without-hash); truncation and in-place tampering of any prefix break the chain
# and are rejected by recover-operation.sh --inspect (a keyless chain is NOT tamper-PROOF).

# _tx_hash — read stdin, print a lowercase hex digest. Prefers sha256; falls back to a POSIX
# cksum CRC (weaker, but always present) tagged so the integrity method is auditable.
_tx_hash() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | awk '{print $1}'
	else
		printf 'cksum:'; cksum | awk '{print $1}'
	fi
}

# tx_journal <phase> <path-or-empty> <detail> — append one chained journal entry. No-op unless
# SS_DIR is set. Always returns 0; failures degrade to a visible warning.
tx_journal() {
	[ -n "${SS_DIR:-}" ] || return 0
	_tj_file="$SS_DIR/transaction-journal.jsonl"
	_tj_phase="$1"; _tj_path="${2:-}"; _tj_detail="${3:-}"
	ensure_dir "$SS_DIR" 2>/dev/null || { log_warn "journal: cannot ensure $SS_DIR"; return 0; }
	# prev hash + seq are derived from the on-disk journal so the chain survives process restarts.
	_tj_prev=""; _tj_seq=1
	if [ -s "$_tj_file" ]; then
		_tj_last=$(tail -n 1 "$_tj_file" 2>/dev/null || true)
		_tj_prev=$(printf '%s' "$_tj_last" | jq -r '.hash // ""' 2>/dev/null || true)
		_tj_n=$(wc -l < "$_tj_file" 2>/dev/null | tr -d ' ' || echo 0)
		[ -n "$_tj_n" ] || _tj_n=0
		_tj_seq=$((_tj_n + 1))
	fi
	_tj_body=$(jq -cn \
		--arg sv "1" --argjson seq "$_tj_seq" --arg ts "$(timestamp_utc)" \
		--arg op "${TX_OP:-unknown}" --argjson pid "$$" \
		--arg phase "$_tj_phase" --arg path "$_tj_path" --arg detail "$_tj_detail" \
		--arg prev "$_tj_prev" \
		'{schema_version:$sv, seq:$seq, ts:$ts, operation:$op, pid:$pid, phase:$phase, path:$path, detail:$detail, prev:$prev}' \
		2>/dev/null || true)
	[ -n "$_tj_body" ] || { log_warn "journal: could not build a '$_tj_phase' entry"; return 0; }
	_tj_hash=$(printf '%s' "$_tj_body" | _tx_hash 2>/dev/null || true)
	[ -n "$_tj_hash" ] || { log_warn "journal: no digest tool available for '$_tj_phase'"; return 0; }
	printf '%s' "$_tj_body" | jq -c --arg h "$_tj_hash" '. + {hash:$h}' >> "$_tj_file" 2>/dev/null \
		|| log_warn "journal: could not append a '$_tj_phase' entry to $_tj_file"
	return 0
}

# tx_snapshot <relpath> — record a file about to be written so it can be restored.
# Dedup: each path is snapshotted AT MOST ONCE (its first, pre-write state) so a second
# write never overwrites the snapshot. A path that did NOT pre-exist is recorded in
# 'created' (no snap copy) so recovery can tell a MODIFIED file (snap MUST exist) from a
# NEWLY-CREATED file (must be removed) — a missing snapshot for a modified file is then a
# detectable, fail-closed corruption rather than silent data loss.
tx_snapshot() {
	[ -n "$TX_SNAP" ] || return 0
	grep -qxF "$1" "$TX_SNAP/touched" 2>/dev/null && return 0
	if [ -e "$TARGET/$1" ]; then
		ensure_dir "$TX_SNAP/snap/$(dirname -- "$1")"
		cp -p "$TARGET/$1" "$TX_SNAP/snap/$1"
		tx_journal "snapshot" "$1" "modified: pre-write copy saved"
	else
		printf '%s\n' "$1" >> "$TX_SNAP/created"
		tx_journal "snapshot" "$1" "created: newly written (no prior state)"
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

# tx_rollback — restore every snapshotted file (or remove files that were newly created).
tx_rollback() {
	[ -n "$TX_SNAP" ] && [ -f "$TX_SNAP/touched" ] || return 0
	_tx_snap_safe "$TX_SNAP" || { log_warn "tx: refusing rollback from an unexpected snapshot dir: $TX_SNAP"; return 0; }
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_tx_rel_safe "$_rel" || { log_warn "tx: skipping unsafe rollback path: $_rel"; continue; }
		if [ -e "$TX_SNAP/snap/$_rel" ]; then
			ensure_dir "$TARGET/$(dirname -- "$_rel")"
			cp -p "$TX_SNAP/snap/$_rel" "$TARGET/$_rel"
			tx_journal "rollback-step" "$_rel" "restored pre-write copy"
		else
			rm -f "$TARGET/$_rel"
			tx_journal "rollback-step" "$_rel" "removed newly-created file"
		fi
	done < "$TX_SNAP/touched"
}

# tx_begin — open the transaction (snapshot dir + atomic lock marker).
tx_begin() {
	ensure_dir "$SS_DIR"
	TX_SNAP="$SS_DIR/.txn-$$"
	ensure_dir "$TX_SNAP"
	: > "$TX_SNAP/touched"
	_lk="$LOCK.tmp.$$"
	jq -n --arg op "$TX_OP" --arg tgt "$TARGET" --arg at "$(timestamp_utc)" --argjson pid "$$" --arg snap "$TX_SNAP" \
		'{schema_version:"1", operation:$op, target:$tgt, started_at:$at, pid:$pid, snapshot_dir:$snap, state:"active"}' > "$_lk" \
		&& mv -- "$_lk" "$LOCK"
	TX_ACTIVE=1
	tx_journal "start" "" "operation=$TX_OP target=$TARGET"
	tx_journal "precondition" "" "no stale lock; acquired operation-lock; snapshot dir ready"
}

# tx_commit — close the transaction successfully (drop lock + snapshots).
tx_commit() {
	TX_ACTIVE=0
	tx_journal "completion" "" "committed: operation succeeded; lock + snapshot cleared"
	rm -f "$LOCK" 2>/dev/null || true
	[ -n "$TX_SNAP" ] && rm -rf "$TX_SNAP" 2>/dev/null || true
	TX_SNAP=""
}

# tx_detect_stale — refuse to mutate when a prior operation-lock is present.
tx_detect_stale() {
	[ -f "$LOCK" ] || return 0
	_op=$(jq -r '.operation // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	_at=$(jq -r '.started_at // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	echo "error: an interrupted Sentinel Shield operation was detected." >&2
	echo "       a previous '$_op' (started $_at) did not finish; $LOCK is present." >&2
	echo "       recover (roll back the partial run) with:" >&2
	echo "         sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover" >&2
	exit 4
}

# _tx_mark_incomplete — best-effort stamp state="rollback-incomplete" onto a parseable
# lock so doctor/readers see a failed recovery. Never removes the lock; on any error the
# original (retained) lock is left exactly as-is.
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
	tx_journal "rollback-step" "$1" "FAILED ($2): $3 — state retained for manual recovery"
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
# Returns 0 only when every touched path is safe, every prior file restores, every
# created file is removed, and post-verify confirms the restored state. On the first
# failure it calls _tx_recover_fail (which exits 4) — it never returns non-zero quietly.
_tx_recover_apply() {
	_created="$TX_SNAP/created"
	# (5) validate EVERY touched path before mutating anything.
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_tx_rel_safe "$_rel" || _tx_recover_fail "$_rel" "validate-touched-path" "touched path is absolute or contains '..' (refusing to restore outside the target)"
	done < "$TX_SNAP/touched"
	# (6)/(7) restore MODIFIED files from their snapshot; remove NEWLY-CREATED files.
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		if grep -qxF "$_rel" "$_created" 2>/dev/null; then
			rm -f "$TARGET/$_rel" 2>/dev/null || _tx_recover_fail "$_rel" "remove-created" "could not remove the newly-created file (read-only directory?)"
			[ -e "$TARGET/$_rel" ] && _tx_recover_fail "$_rel" "remove-created" "newly-created file is still present after removal"
			tx_journal "rollback-step" "$_rel" "removed newly-created file"
		else
			# A modified file's pre-write snapshot MUST exist; a missing one means a
			# corrupt/incomplete snapshot — refuse rather than delete the live file.
			[ -e "$TX_SNAP/snap/$_rel" ] || _tx_recover_fail "$_rel" "missing-expected-snapshot" "no snapshot for a modified file (snapshot corrupt/incomplete) — refusing to touch the live file"
			ensure_dir "$TARGET/$(dirname -- "$_rel")" || _tx_recover_fail "$_rel" "restore-mkdir" "could not recreate the parent directory for the restored file"
			cp -p "$TX_SNAP/snap/$_rel" "$TARGET/$_rel" || _tx_recover_fail "$_rel" "restore-copy" "could not restore the prior file (read-only target or permission denied)"
			tx_journal "rollback-step" "$_rel" "restored pre-write copy"
		fi
	done < "$TX_SNAP/touched"
	# (9) post-rollback verification: created paths absent; modified paths match the snapshot.
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		if grep -qxF "$_rel" "$_created" 2>/dev/null; then
			[ -e "$TARGET/$_rel" ] && _tx_recover_fail "$_rel" "post-verify" "newly-created file is still present after rollback"
		else
			cmp -s "$TX_SNAP/snap/$_rel" "$TARGET/$_rel" || _tx_recover_fail "$_rel" "post-verify" "restored file does not match its snapshot"
		fi
	done < "$TX_SNAP/touched"
	return 0
}

# tx_recover — FAIL-CLOSED rollback of the interrupted run recorded in the lock. Deletes
# the snapshot + lock and exits 0 ONLY when EVERY step of the recovery contract holds;
# otherwise retains the lock + all snapshots and exits 4 (see _tx_recover_fail).
tx_recover() {
	if [ ! -f "$LOCK" ]; then echo "No interrupted operation found ($LOCK absent); nothing to recover."; exit 0; fi
	# (1) lock parses & is schema-valid (CONTRACT(2)).
	_tx_lock_valid "$LOCK" || _tx_recover_fail "$LOCK" "lock-schema-validation" "operation-lock is missing fields, mistyped, or not schema-conformant"
	_snap=$(jq -r '.snapshot_dir' "$LOCK" 2>/dev/null || true)
	_ltarget=$(jq -r '.target' "$LOCK" 2>/dev/null || true)
	# (2) lock.target must equal the current canonical target.
	[ "$_ltarget" = "$TARGET" ] || _tx_recover_fail "$LOCK" "target-mismatch" "lock target '$_ltarget' != current canonical target '$TARGET'"
	# (3) re-validate snapshot_dir containment (UNTRUSTED) and existence.
	_tx_snap_safe "$_snap" || _tx_recover_fail "$_snap" "snapshot-dir-unsafe" "snapshot_dir is not canonically contained in $SS_DIR/.txn-*"
	[ -d "$_snap" ] || _tx_recover_fail "$_snap" "snapshot-dir-missing" "snapshot_dir does not exist"
	# (4) the touched manifest must exist & be readable.
	[ -f "$_snap/touched" ] && [ -r "$_snap/touched" ] || _tx_recover_fail "$_snap/touched" "touched-manifest-missing" "the touched manifest is absent or unreadable"
	# (5)-(9) validated rollback + post-verify (exits 4 on the first failure).
	TX_SNAP="$_snap"
	tx_journal "rollback-step" "" "resume-rollback: recovering interrupted '$_ltarget' operation"
	_tx_recover_apply || _tx_recover_fail "$_snap" "rollback" "rollback did not complete"
	# All steps held: it is now safe to clear recovery state.
	tx_journal "completion" "" "recovery complete: interrupted operation rolled back; lock cleared"
	rm -rf "$_snap" 2>/dev/null || true
	rm -f "$LOCK" 2>/dev/null || true
	echo "Recovery complete: rolled back the interrupted operation and cleared $LOCK."
	exit 0
}
