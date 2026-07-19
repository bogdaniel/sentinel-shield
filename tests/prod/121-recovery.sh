#!/bin/sh
# tests/prod/121-recovery.sh — interrupted-operation recovery must FAIL CLOSED (BLOCKER 2).
#
# Drives the --recover / tx_recover path of install/sync/migrate with FAULT INJECTION and
# asserts the RECOVERY CONTRACT: a recovery may clear state (delete snapshot + lock, exit 0)
# ONLY when every step holds. On ANY fault it must RETAIN the lock AND all snapshots, print
# the failing path+operation, and exit 4 — never claim success, never delete recovery data.
#
# Scenarios: malformed lock JSON; missing snapshot_dir; unsafe snapshot_dir (outside .txn-*);
# missing touched manifest; unsafe touched path (no deletion outside target); missing expected
# snapshot file; copy-restore failure (read-only file); remove-created failure (read-only dir);
# read-only target; interrupted install/sync/migration detection; SUCCESSFUL complete recovery
# (clears state, exit 0); recovery RETRIED after a failed recovery (still safe).
#
# Self-contained, NETWORK-FREE. CRITICAL: a failed recovery NEVER rm's an unsafe path — each
# destructive case asserts the SCRIPT refuses (exit 4) and the would-be-deleted sentinel SURVIVES.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
INSTALL="$ROOT/scripts/install-baseline.sh"
SYNC="$ROOT/scripts/sync-baseline.sh"
MIGRATE="$ROOT/scripts/migrate-v1.sh"

FAILS=0
SKIPPED=0
# skip <message> — record a check that could NOT run. Deliberately NOT `pass`: the suite
# header says "a skip is not a pass", and under a root CI container these are exactly the
# permission-failure paths the suite exists to prove.
skip() { printf 'SKIP: %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssrec)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

IS_ROOT=0; [ "$(id -u 2>/dev/null || echo 0)" = "0" ] && IS_ROOT=1

# mk_target — create a fresh, CANONICAL target dir holding an empty .sentinel-shield.
mk_target() {
	_d=$(mktemp -d "$WORK/tgt.XXXXXX" 2>/dev/null || mktemp -d -t ssrec)
	# Resolve PHYSICALLY (symlinks resolved) so the lock 'target' we write matches the
	# canonical target the scripts now record (cd -P / pwd -P).
	_c=$(CDPATH= cd -P -- "$_d" && pwd -P)
	mkdir -p "$_c/.sentinel-shield"
	printf '%s' "$_c"
}

# write_lock <target> <snapshot_dir> [op] [state] — emit a CONTRACT(2)-shaped operation-lock.
write_lock() {
	_op=${3:-install}; _st=${4:-active}
	printf '{"schema_version":"1","operation":"%s","target":"%s","started_at":"2026-01-01T00:00:00Z","pid":1,"snapshot_dir":"%s","state":"%s"}' \
		"$_op" "$1" "$2" "$_st" > "$1/.sentinel-shield/operation-lock.json"
}

# recover_install/sync/migrate <target> — run a script's standalone recovery mode; capture rc.
recover_install() { sh "$INSTALL" --target "$1" --recover >/dev/null 2>&1; }
recover_sync()    { sh "$SYNC"    --target "$1" --recover >/dev/null 2>&1; }
recover_migrate() { sh "$MIGRATE" --target "$1" --recover >/dev/null 2>&1; }

# ============================================================================
# (1) malformed lock JSON -> refuse, exit 4, lock retained (left untouched).
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
printf '{not valid json' > "$L"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(1) malformed lock -> exit 4" || fail "(1) malformed lock -> exit 4 (rc=$rc)"
[ -f "$L" ] && pass "(1) malformed lock retained" || fail "(1) malformed lock retained"
[ "$(cat "$L")" = '{not valid json' ] && pass "(1) malformed lock left byte-for-byte" || fail "(1) malformed lock left untouched"

# ============================================================================
# (2) missing snapshot_dir -> exit 4, lock retained.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
write_lock "$T" "$T/.sentinel-shield/.txn-gone"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(2) missing snapshot_dir -> exit 4" || fail "(2) missing snapshot_dir -> exit 4 (rc=$rc)"
[ -f "$L" ] && pass "(2) lock retained on missing snapshot_dir" || fail "(2) lock retained on missing snapshot_dir"

# ============================================================================
# (3) unsafe snapshot_dir (outside .txn-*) -> refuse; sentinel inside SURVIVES.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
EVIL="$T/.sentinel-shield/evil-not-a-txn"; mkdir -p "$EVIL"
printf 'KEEP3' > "$EVIL/sentinel"
write_lock "$T" "$EVIL"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(3) unsafe snapshot_dir -> exit 4" || fail "(3) unsafe snapshot_dir -> exit 4 (rc=$rc)"
[ -f "$EVIL/sentinel" ] && pass "(3) sentinel in unsafe snapshot_dir NOT deleted" || fail "(3) sentinel in unsafe snapshot_dir survives"
[ -f "$L" ] && pass "(3) lock retained on unsafe snapshot_dir" || fail "(3) lock retained on unsafe snapshot_dir"

# ============================================================================
# (4) missing touched manifest -> exit 4, snapshot dir + lock retained.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
TXN="$T/.sentinel-shield/.txn-notouched"; mkdir -p "$TXN/snap"; printf 'KEEP4' > "$TXN/sentinel"
write_lock "$T" "$TXN"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(4) missing touched manifest -> exit 4" || fail "(4) missing touched manifest -> exit 4 (rc=$rc)"
[ -f "$TXN/sentinel" ] && pass "(4) snapshot dir retained (sentinel survives)" || fail "(4) snapshot dir retained"
[ -f "$L" ] && pass "(4) lock retained on missing touched manifest" || fail "(4) lock retained on missing touched manifest"

# ============================================================================
# (5) unsafe touched path ('../escape') -> refuse BEFORE any mutation; a real file
#     the unsafe path resolves to (OUTSIDE the target) is NEVER deleted.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
TXN="$T/.sentinel-shield/.txn-unsafe"; mkdir -p "$TXN/snap"
# '../escape' from $T resolves to $(dirname $T)/escape — seed a real sentinel there.
OUTSIDE="$(dirname "$T")/escape"; printf 'KEEP5' > "$OUTSIDE"
printf '../escape\n' > "$TXN/touched"
printf '../escape\n' > "$TXN/created"   # would-be rm of the resolved outside file
write_lock "$T" "$TXN"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(5) unsafe touched path -> exit 4" || fail "(5) unsafe touched path -> exit 4 (rc=$rc)"
{ [ -f "$OUTSIDE" ] && [ "$(cat "$OUTSIDE")" = KEEP5 ]; } \
	&& pass "(5) outside-target file NOT deleted by unsafe touched path" \
	|| fail "(5) outside-target file survives"
[ -f "$L" ] && pass "(5) lock retained on unsafe touched path" || fail "(5) lock retained on unsafe touched path"

# ============================================================================
# (6) missing expected snapshot file (modified file, no snap) -> refuse to touch
#     the live file; exit 4; live file intact; lock marked rollback-incomplete.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
TXN="$T/.sentinel-shield/.txn-nosnap"; mkdir -p "$TXN/snap"
printf 'mod.txt\n' > "$TXN/touched"   # modified (NOT in 'created') but snap/mod.txt absent
printf 'LIVE6' > "$T/mod.txt"
write_lock "$T" "$TXN"
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(6) missing expected snapshot -> exit 4" || fail "(6) missing expected snapshot -> exit 4 (rc=$rc)"
{ [ -f "$T/mod.txt" ] && [ "$(cat "$T/mod.txt")" = LIVE6 ]; } \
	&& pass "(6) live file NOT touched when snapshot missing" || fail "(6) live file untouched"
[ -f "$L" ] && pass "(6) lock retained on missing snapshot" || fail "(6) lock retained on missing snapshot"
[ "$(jq -r '.state' "$L" 2>/dev/null)" = "rollback-incomplete" ] \
	&& pass "(6) lock stamped state=rollback-incomplete" || fail "(6) lock stamped rollback-incomplete"

# ----- (6b) recovery RETRIED after a failed recovery is STILL safe (still exit 4) -----
recover_install "$T" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(6b) retried recovery still exits 4" || fail "(6b) retried recovery still exits 4 (rc=$rc)"
{ [ -f "$T/mod.txt" ] && [ "$(cat "$T/mod.txt")" = LIVE6 ]; } \
	&& pass "(6b) live file still intact after retry" || fail "(6b) live file intact after retry"
[ -f "$L" ] && pass "(6b) lock still retained after retry" || fail "(6b) lock still retained after retry"

# ----- (6c)/(6d) a touched path absent from BOTH 'snap' and 'created' is in NEITHER
#       manifest: sync AND migrate recovery must FAIL CLOSED exactly like install — refuse
#       to delete the live file, retain the lock, exit 4 (a corrupt snapshot is not data loss).
for _pair in "sync:recover_sync:sync" "migrate:recover_migrate:migration"; do
	_name=${_pair%%:*}; _rest=${_pair#*:}; _fn=${_rest%%:*}; _op=${_rest#*:}
	T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
	TXN="$T/.sentinel-shield/.txn-neither-$_name"; mkdir -p "$TXN/snap"
	printf 'mod.txt\n' > "$TXN/touched"   # touched but in NEITHER snap nor created
	printf 'LIVE6%s' "$_name" > "$T/mod.txt"; _live=$(cat "$T/mod.txt")
	write_lock "$T" "$TXN" "$_op"
	"$_fn" "$T" && rc=0 || rc=$?
	[ "$rc" = 4 ] && pass "(6c) $_name: path in neither manifest -> exit 4" || fail "(6c) $_name: path in neither manifest -> exit 4 (rc=$rc)"
	{ [ -f "$T/mod.txt" ] && [ "$(cat "$T/mod.txt")" = "$_live" ]; } \
		&& pass "(6c) $_name: live file NOT deleted (no data loss)" || fail "(6c) $_name: live file NOT deleted"
	[ -f "$L" ] && pass "(6c) $_name: lock retained" || fail "(6c) $_name: lock retained"
done

# ============================================================================
# (7) copy-restore failure (read-only modified file) -> exit 4, live file intact.
# ============================================================================
if [ "$IS_ROOT" -eq 0 ]; then
	T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
	TXN="$T/.sentinel-shield/.txn-rocopy"; mkdir -p "$TXN/snap/ro"
	printf 'OLD7' > "$TXN/snap/ro/mod.txt"
	printf 'ro/mod.txt\n' > "$TXN/touched"     # modified: snap exists
	mkdir -p "$T/ro"; printf 'NEW7' > "$T/ro/mod.txt"
	chmod 0444 "$T/ro/mod.txt"                 # unwritable -> cp -p must fail
	write_lock "$T" "$TXN"
	recover_install "$T" && rc=0 || rc=$?
	chmod 0644 "$T/ro/mod.txt" 2>/dev/null || true
	[ "$rc" = 4 ] && pass "(7) copy-restore failure -> exit 4" || fail "(7) copy-restore failure -> exit 4 (rc=$rc)"
	[ "$(cat "$T/ro/mod.txt")" = NEW7 ] && pass "(7) live file not corrupted on restore failure" || fail "(7) live file not corrupted"
	[ -f "$L" ] && pass "(7) lock retained on copy-restore failure" || fail "(7) lock retained on copy-restore failure"
else
	skip "(7) copy-restore failure -> exit 4 — permission-failure path is unreachable as root"
fi

# ============================================================================
# (8) remove-created failure (read-only dir holding a newly-created file) -> exit 4;
#     the created file SURVIVES (not deleted); lock retained.
# ============================================================================
if [ "$IS_ROOT" -eq 0 ]; then
	T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
	TXN="$T/.sentinel-shield/.txn-rorm"; mkdir -p "$TXN/snap"
	printf 'ro2/new.txt\n' > "$TXN/touched"
	printf 'ro2/new.txt\n' > "$TXN/created"    # newly-created: must be removed
	mkdir -p "$T/ro2"; printf 'KEEP8' > "$T/ro2/new.txt"
	chmod 0555 "$T/ro2"                          # dir unwritable -> rm must fail
	write_lock "$T" "$TXN"
	recover_install "$T" && rc=0 || rc=$?
	chmod 0755 "$T/ro2" 2>/dev/null || true
	[ "$rc" = 4 ] && pass "(8) remove-created failure -> exit 4" || fail "(8) remove-created failure -> exit 4 (rc=$rc)"
	{ [ -f "$T/ro2/new.txt" ] && [ "$(cat "$T/ro2/new.txt")" = KEEP8 ]; } \
		&& pass "(8) created file survives a failed removal" || fail "(8) created file survives"
	[ -f "$L" ] && pass "(8) lock retained on remove-created failure" || fail "(8) lock retained on remove-created failure"
else
	skip "(8) remove-created failure -> exit 4 — permission-failure path is unreachable as root"
fi

# ============================================================================
# (9) read-only TARGET dir (restore must recreate a deleted file) -> exit 4; lock retained.
# ============================================================================
if [ "$IS_ROOT" -eq 0 ]; then
	T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
	TXN="$T/.sentinel-shield/.txn-rotgt"; mkdir -p "$TXN/snap"
	printf 'gone.txt\n' > "$TXN/touched"       # modified: snap exists but live file removed
	printf 'OLD9' > "$TXN/snap/gone.txt"
	# live gone.txt absent; restoring it must CREATE it in $T, which is read-only -> fail.
	chmod 0555 "$T"
	write_lock "$T" "$TXN"
	recover_install "$T" && rc=0 || rc=$?
	chmod 0755 "$T" 2>/dev/null || true
	[ "$rc" = 4 ] && pass "(9) read-only target -> exit 4" || fail "(9) read-only target -> exit 4 (rc=$rc)"
	[ ! -e "$T/gone.txt" ] && pass "(9) no partial write into read-only target" || fail "(9) no partial write into read-only target"
	[ -f "$L" ] && pass "(9) lock retained on read-only target" || fail "(9) lock retained on read-only target"
else
	skip "(9) read-only target -> exit 4 — permission-failure path is unreachable as root"
fi

# ============================================================================
# (10) interrupted install / sync / migration are DETECTED (stale lock blocks --apply, exit 4,
#      --recover offered, lock retained). One real installed fixture reused per op.
# ============================================================================
TI=$(mktemp -d "$WORK/inst.XXXXXX"); TI=$(CDPATH= cd -P -- "$TI" && pwd -P)
sh "$INSTALL" --target "$TI" --apply --mode report-only >/dev/null 2>&1
LI="$TI/.sentinel-shield/operation-lock.json"
seed_int_lock() { # <op>
	_x="$TI/.sentinel-shield/.txn-int"; mkdir -p "$_x/snap"; : > "$_x/touched"
	write_lock "$TI" "$_x" "$1"
}

seed_int_lock install
out=$(sh "$INSTALL" --target "$TI" --apply --force 2>&1) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(10) interrupted install detected (exit 4)" || fail "(10) interrupted install detected (rc=$rc)"
case "$out" in *--recover*) pass "(10) install offers --recover" ;; *) fail "(10) install offers --recover" ;; esac
[ -f "$LI" ] && pass "(10) install lock retained (not silently cleared)" || fail "(10) install lock retained"
rm -f "$LI"

seed_int_lock sync
out=$(sh "$SYNC" --target "$TI" --apply --force 2>&1) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(10) interrupted sync detected (exit 4)" || fail "(10) interrupted sync detected (rc=$rc)"
case "$out" in *--recover*) pass "(10) sync offers --recover" ;; *) fail "(10) sync offers --recover" ;; esac
[ -f "$LI" ] && pass "(10) sync lock retained" || fail "(10) sync lock retained"
rm -f "$LI"

seed_int_lock migration
out=$(sh "$MIGRATE" --target "$TI" --apply --force 2>&1) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(10) interrupted migration detected (exit 4)" || fail "(10) interrupted migration detected (rc=$rc)"
case "$out" in *--recover*) pass "(10) migrate offers --recover" ;; *) fail "(10) migrate offers --recover" ;; esac
[ -f "$LI" ] && pass "(10) migrate lock retained" || fail "(10) migrate lock retained"
rm -f "$LI"

# ============================================================================
# (11) SUCCESSFUL complete recovery: restore a modified file + remove a created file,
#      then clear snapshot + lock and exit 0.
# ============================================================================
T=$(mk_target); L="$T/.sentinel-shield/operation-lock.json"
TXN="$T/.sentinel-shield/.txn-ok"; mkdir -p "$TXN/snap"
printf 'mod.txt\n'  > "$TXN/touched"
printf 'new.txt\n' >> "$TXN/touched"
printf 'new.txt\n'  > "$TXN/created"
printf 'PRISTINE\n' > "$TXN/snap/mod.txt"      # the pre-write content to restore
printf 'MUTATED\n'  > "$T/mod.txt"             # current (post-write) content
printf 'CREATED\n'  > "$T/new.txt"             # newly-created file to remove
write_lock "$T" "$TXN"
sh "$INSTALL" --target "$T" --recover >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(11) successful recovery exits 0" || fail "(11) successful recovery exits 0 (rc=$rc)"
[ "$(cat "$T/mod.txt" 2>/dev/null)" = PRISTINE ] && pass "(11) modified file restored to pre-write state" || fail "(11) modified file restored"
[ ! -e "$T/new.txt" ] && pass "(11) newly-created file removed" || fail "(11) newly-created file removed"
[ ! -f "$L" ] && pass "(11) lock cleared after successful recovery" || fail "(11) lock cleared"
[ ! -d "$TXN" ] && pass "(11) snapshot dir cleared after successful recovery" || fail "(11) snapshot dir cleared"

# ----- (11b) re-running --recover after success is a clean no-op (exit 0). -----
sh "$INSTALL" --target "$T" --recover >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(11b) --recover with no lock is a clean no-op (exit 0)" || fail "(11b) no-op recover exit 0 (rc=$rc)"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll recovery fail-closed assertions passed.\n'
exit 0
