#!/bin/sh
# tests/prod/211-transaction-symlink.sh — SYMLINK-escape containment during snapshot & recovery.
#
# Companion to 210 (journal) and 121 (fail-closed recovery). It proves the PHYSICAL containment
# validator (scripts/lib/transaction.sh :: _tx_contained / _tx_manifest_check / _tx_guard_entry):
# a transaction path whose parent (or final) component is a SYMLINK, or which is otherwise
# malformed, must NEVER be followed out of the consumer root during recovery/rollback.
#
# Threat model: an attacker plants a symlink (or tampers a manifest) so that restoring a
# snapshot, deleting a "created" file, or writing a restoration parent would land OUTSIDE the
# target. For each attack we seed a sentinel file OUTSIDE the target, drive recovery, and assert:
#   (i)   recovery FAILS CLOSED (exit 4) — it never silently skips-and-continues;
#   (ii)  the external sentinel is BYTE-FOR-BYTE unchanged (no escape write/delete);
#   (iii) the lock AND snapshot are RETAINED (nothing destroyed);
#   (iv)  the lock is stamped state=rollback-incomplete;
#   (v)   the journal records the containment failure.
# Plus a positive control: a NORMAL nested restore still succeeds (exit 0).
#
# Self-contained, NETWORK-FREE, and requires NO root (pure symlink/manifest tampering).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RECOVER="$ROOT/scripts/recover-operation.sh"
INSTALL="$ROOT/scripts/install-baseline.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sssym)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# mk_target — a fresh CANONICAL target dir holding an empty .sentinel-shield.
mk_target() {
	_d=$(mktemp -d "$WORK/tgt.XXXXXX" 2>/dev/null || mktemp -d -t sssym)
	_c=$(CDPATH= cd -P -- "$_d" && pwd -P)
	mkdir -p "$_c/.sentinel-shield"
	printf '%s' "$_c"
}

# write_lock <target> <snapshot_dir> — emit a CONTRACT(2)-shaped, schema-valid operation-lock.
write_lock() {
	printf '{"schema_version":"1","operation":"install","target":"%s","started_at":"2026-01-01T00:00:00Z","pid":1,"snapshot_dir":"%s","state":"active"}' \
		"$1" "$2" > "$1/.sentinel-shield/operation-lock.json"
}

recover() { sh "$RECOVER" --target "$1" --resume-rollback >/dev/null 2>&1; }

# assert_fail_closed <label> <target> <txn> <sentinel-file> <sentinel-content> [<live-file> <live-content>]
# Run recovery and assert the full fail-closed contract (i)-(v), plus (optionally) that a live
# target file was NOT partially mutated.
assert_fail_closed() {
	_lbl=$1; _t=$2; _txn=$3; _sf=$4; _sc=$5; _lf=${6:-}; _lc=${7:-}
	_lk="$_t/.sentinel-shield/operation-lock.json"
	_jrnl="$_t/.sentinel-shield/transaction-journal.jsonl"
	recover "$_t" && _rc=0 || _rc=$?
	[ "$_rc" = 4 ] && pass "$_lbl: fail-closed (exit 4)" || fail "$_lbl: fail-closed (exit 4; got $_rc)"
	{ [ -f "$_sf" ] && [ "$(cat "$_sf")" = "$_sc" ]; } \
		&& pass "$_lbl: external sentinel byte-for-byte unchanged" || fail "$_lbl: external sentinel unchanged"
	[ -f "$_lk" ] && pass "$_lbl: lock retained" || fail "$_lbl: lock retained"
	[ -d "$_txn" ] && pass "$_lbl: snapshot retained" || fail "$_lbl: snapshot retained"
	[ "$(jq -r '.state' "$_lk" 2>/dev/null)" = "rollback-incomplete" ] \
		&& pass "$_lbl: lock stamped rollback-incomplete" || fail "$_lbl: lock stamped rollback-incomplete"
	{ [ -f "$_jrnl" ] && grep -q 'FAILED' "$_jrnl" 2>/dev/null; } \
		&& pass "$_lbl: journal records the containment failure" || fail "$_lbl: journal records failure"
	if [ -n "$_lf" ]; then
		[ "$(cat "$_lf" 2>/dev/null)" = "$_lc" ] \
			&& pass "$_lbl: live target file not partially mutated" || fail "$_lbl: live target file unchanged"
	fi
}

# ============================================================================
# (1) target PARENT dir is a symlink to an OUTSIDE dir (modified-file restore escape).
# ============================================================================
OUT=$WORK/out1; mkdir -p "$OUT"; printf 'SENTINEL1' > "$OUT/file.txt"
T=$(mk_target); ln -s "$OUT" "$T/linkdir"
TXN="$T/.sentinel-shield/.txn-c1"; mkdir -p "$TXN/snap/linkdir"
printf 'linkdir/file.txt\n' > "$TXN/touched"
printf 'RESTORED\n' > "$TXN/snap/linkdir/file.txt"
write_lock "$T" "$TXN"
assert_fail_closed "(1) symlinked target parent" "$T" "$TXN" "$OUT/file.txt" "SENTINEL1"

# ============================================================================
# (2) NESTED symlink parent (a/ real, a/b -> outside): restore must not escape.
# ============================================================================
OUT=$WORK/out2; mkdir -p "$OUT"; printf 'SENTINEL2' > "$OUT/file.txt"
T=$(mk_target); mkdir -p "$T/a"; ln -s "$OUT" "$T/a/b"
TXN="$T/.sentinel-shield/.txn-c2"; mkdir -p "$TXN/snap/a/b"
printf 'a/b/file.txt\n' > "$TXN/touched"
printf 'RESTORED\n' > "$TXN/snap/a/b/file.txt"
write_lock "$T" "$TXN"
assert_fail_closed "(2) nested symlink parent" "$T" "$TXN" "$OUT/file.txt" "SENTINEL2"

# ============================================================================
# (3) symlink created AFTER snapshot, BEFORE rollback: the final component is now a
#     symlink to an outside file — restoring must not write through it.
# ============================================================================
OUT=$WORK/out3; mkdir -p "$OUT"; printf 'SENTINEL3' > "$OUT/sentinel"
T=$(mk_target); ln -s "$OUT/sentinel" "$T/file.txt"   # live final component swapped to a symlink
TXN="$T/.sentinel-shield/.txn-c3"; mkdir -p "$TXN/snap"
printf 'file.txt\n' > "$TXN/touched"                  # modified (snap present)
printf 'RESTORED\n' > "$TXN/snap/file.txt"
write_lock "$T" "$TXN"
assert_fail_closed "(3) post-snapshot symlinked final" "$T" "$TXN" "$OUT/sentinel" "SENTINEL3"

# ============================================================================
# (4) snapshot-side symlink REPLACING a saved file: the snapshot entry is a symlink to an
#     outside file — recovery must never follow it (no exfil into the live tree, no escape).
# ============================================================================
OUT=$WORK/out4; mkdir -p "$OUT"; printf 'SENTINEL4' > "$OUT/secret"
T=$(mk_target)
TXN="$T/.sentinel-shield/.txn-c4"; mkdir -p "$TXN/snap"
ln -s "$OUT/secret" "$TXN/snap/file.txt"              # malicious snapshot symlink
printf 'file.txt\n' > "$TXN/touched"                  # modified (snap "present" but a symlink)
printf 'LIVE4\n' > "$T/file.txt"                      # real live file that must stay intact
write_lock "$T" "$TXN"
assert_fail_closed "(4) snapshot-side symlink" "$T" "$TXN" "$OUT/secret" "SENTINEL4" "$T/file.txt" "LIVE4"

# ============================================================================
# (5) tampered 'touched' with '../' traversal: rejected before any mutation.
# ============================================================================
T=$(mk_target)
OUTSIDE="$(dirname "$T")/escape5"; printf 'SENTINEL5' > "$OUTSIDE"
TXN="$T/.sentinel-shield/.txn-c5"; mkdir -p "$TXN/snap"
printf '../escape5\n' > "$TXN/touched"
printf '../escape5\n' > "$TXN/created"
write_lock "$T" "$TXN"
assert_fail_closed "(5) '../' traversal manifest" "$T" "$TXN" "$OUTSIDE" "SENTINEL5"

# ============================================================================
# (6) ABSOLUTE path manifest entry: rejected (no absolute write/delete).
# ============================================================================
T=$(mk_target)
ABS="$WORK/abs6-sentinel"; printf 'SENTINEL6' > "$ABS"
TXN="$T/.sentinel-shield/.txn-c6"; mkdir -p "$TXN/snap"
printf '%s\n' "$ABS" > "$TXN/touched"                 # absolute path entry
printf '%s\n' "$ABS" > "$TXN/created"
write_lock "$T" "$TXN"
assert_fail_closed "(6) absolute path entry" "$T" "$TXN" "$ABS" "SENTINEL6"

# ============================================================================
# (7) DUPLICATE path in 'touched': malformed manifest must not partially execute.
# ============================================================================
T=$(mk_target)
IRR=$WORK/irr7; printf 'SENTINEL7' > "$IRR"
TXN="$T/.sentinel-shield/.txn-c7"; mkdir -p "$TXN/snap"
printf 'file.txt\nfile.txt\n' > "$TXN/touched"        # byte-identical duplicate line
printf 'RESTORED\n' > "$TXN/snap/file.txt"
printf 'LIVE7\n' > "$T/file.txt"
write_lock "$T" "$TXN"
assert_fail_closed "(7) duplicate manifest path" "$T" "$TXN" "$IRR" "SENTINEL7" "$T/file.txt" "LIVE7"

# ============================================================================
# (8) path in BOTH created AND carrying a snapshot (created+modified contradiction).
# ============================================================================
T=$(mk_target)
IRR=$WORK/irr8; printf 'SENTINEL8' > "$IRR"
TXN="$T/.sentinel-shield/.txn-c8"; mkdir -p "$TXN/snap"
printf 'file.txt\n' > "$TXN/touched"
printf 'file.txt\n' > "$TXN/created"                  # claims newly-created …
printf 'RESTORED\n' > "$TXN/snap/file.txt"            # … yet ALSO has a snapshot (contradiction)
printf 'LIVE8\n' > "$T/file.txt"
write_lock "$T" "$TXN"
assert_fail_closed "(8) created+modified contradiction" "$T" "$TXN" "$IRR" "SENTINEL8" "$T/file.txt" "LIVE8"

# ============================================================================
# (9) NEW-FILE rollback through a symlinked parent: 'rm' of a created file must not delete
#     an outside file reached via a symlinked parent.
# ============================================================================
OUT=$WORK/out9; mkdir -p "$OUT"; printf 'SENTINEL9' > "$OUT/new.txt"
T=$(mk_target); ln -s "$OUT" "$T/linkdir"
TXN="$T/.sentinel-shield/.txn-c9"; mkdir -p "$TXN/snap"
printf 'linkdir/new.txt\n' > "$TXN/touched"
printf 'linkdir/new.txt\n' > "$TXN/created"           # would rm $T/linkdir/new.txt == $OUT/new.txt
write_lock "$T" "$TXN"
assert_fail_closed "(9) new-file rm via symlinked parent" "$T" "$TXN" "$OUT/new.txt" "SENTINEL9"

# ============================================================================
# (10) POSITIVE CONTROL: a NORMAL nested restore still succeeds (exit 0), so the hardening
#      did not break legitimate recovery.
# ============================================================================
T=$(mk_target)
TXN="$T/.sentinel-shield/.txn-ok"; mkdir -p "$TXN/snap/sub/dir"
printf 'sub/dir/mod.txt\n'  > "$TXN/touched"
printf 'sub/dir/new.txt\n' >> "$TXN/touched"
printf 'sub/dir/new.txt\n'  > "$TXN/created"
printf 'PRISTINE\n' > "$TXN/snap/sub/dir/mod.txt"
mkdir -p "$T/sub/dir"
printf 'MUTATED\n' > "$T/sub/dir/mod.txt"
printf 'CREATED\n' > "$T/sub/dir/new.txt"
write_lock "$T" "$TXN"
recover "$T" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(10) normal nested restore succeeds (exit 0)" || fail "(10) normal nested restore exit 0 (got $rc)"
[ "$(cat "$T/sub/dir/mod.txt" 2>/dev/null)" = PRISTINE ] && pass "(10) nested modified file restored" || fail "(10) nested modified file restored"
[ ! -e "$T/sub/dir/new.txt" ] && pass "(10) nested created file removed" || fail "(10) nested created file removed"
[ ! -f "$T/.sentinel-shield/operation-lock.json" ] && pass "(10) lock cleared after clean recovery" || fail "(10) lock cleared"
[ ! -d "$TXN" ] && pass "(10) snapshot cleared after clean recovery" || fail "(10) snapshot cleared"

# ============================================================================
# (11) WRITE-SIDE (snapshot-time) containment: a live install into a target whose managed
#      parent dir (.github) was pre-planted as a symlink to an OUTSIDE dir must ABORT and
#      auto-roll-back — never snapshotting/writing THROUGH the symlink into the outside dir.
# ============================================================================
OUT=$WORK/out11; mkdir -p "$OUT"
T=$(mktemp -d "$WORK/inst.XXXXXX"); T=$(CDPATH= cd -P -- "$T" && pwd -P)
ln -s "$OUT" "$T/.github"                              # managed workflows land under .github/
sh "$INSTALL" --target "$T" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(11) live install aborts on a symlinked managed parent (nonzero)" \
	|| fail "(11) live install aborts on symlinked parent (got $rc)"
[ ! -e "$OUT/workflows" ] && pass "(11) nothing written THROUGH the symlink into the outside dir" \
	|| fail "(11) no escape write into outside dir"
[ ! -f "$T/.sentinel-shield/operation-lock.json" ] \
	&& pass "(11) graceful auto-rollback cleared the lock" || fail "(11) lock cleared after auto-rollback"
JI="$T/.sentinel-shield/transaction-journal.jsonl"
{ [ -f "$JI" ] && grep -q 'REJECTED' "$JI" 2>/dev/null; } \
	&& pass "(11) journal records the snapshot-time rejection" || fail "(11) journal records snapshot-time rejection"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll transaction symlink-containment assertions passed.\n'
exit 0
