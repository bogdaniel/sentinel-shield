#!/bin/sh
# tests/prod/251-transaction-durability.sh — DURABLE transaction / concurrency / crash-recovery.
#
# Proves the production hardening in scripts/lib/transaction.sh + scripts/recover-operation.sh:
# atomic (mkdir) lock acquisition that two processes cannot both win; a PID-independent
# ownership token; process-start identity that defeats PID reuse; an explicit state machine with
# rejected impossible transitions; journal chain verification before resume (with a torn-tail
# tolerance); durable atomic managed-file writes with post-write digest validation; and
# fail-closed handling of write/permission/disk-full faults. Every crash point in the task's
# required list is reproduced deterministically with hand-built fixtures or documented fault
# seams — nothing depends on real timing races for its PASS/FAIL.
#
# Required cases (1)-(15) are labelled inline. Self-contained, NETWORK-FREE. jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
INSTALL="$ROOT/scripts/install-baseline.sh"
RECOVER="$ROOT/scripts/recover-operation.sh"
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_TX="$ROOT/scripts/lib/transaction.sh"
LOCK_SCHEMA="$ROOT/schemas/operation-lock.schema.json"
INSPECT_SCHEMA="$ROOT/schemas/recovery-inspection.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssdur)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

IS_ROOT=0; [ "$(id -u 2>/dev/null || echo 0)" = "0" ] && IS_ROOT=1
MANAGED=".github/workflows/sentinel-shield.yml"

# th_hash — the SAME digest the library uses (sha256 else cksum fallback), reading stdin.
th_hash() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
	else printf 'cksum:'; cksum | awk '{print $1}'; fi
}

# mk_target — a fresh CANONICAL target dir holding an empty .sentinel-shield.
mk_target() {
	_d=$(mktemp -d "$WORK/tgt.XXXXXX" 2>/dev/null || mktemp -d -t ssdur)
	_c=$(CDPATH= cd -P -- "$_d" && pwd -P)
	mkdir -p "$_c/.sentinel-shield"
	printf '%s' "$_c"
}

# write_lock <target> <snapshot_dir> <state> [pid] [pid_start] [hostname] — emit a schema-valid,
# NEW-STYLE operation-lock with ownership metadata. Missing pid/host default to a benign owner.
write_lock() {
	_wt=$1; _ws=$2; _wst=$3; _wp=${4:-1}; _wps=${5:-}; _wh=${6:-$(uname -n 2>/dev/null || echo host)}
	jq -n --arg tgt "$_wt" --arg snap "$_ws" --arg st "$_wst" --argjson pid "$_wp" \
		--arg ps "$_wps" --arg host "$_wh" '{
			schema_version:"1", operation:"install", target:$tgt,
			started_at:"2026-01-01T00:00:00Z", pid:$pid, snapshot_dir:$snap, state:$st,
			token:"tok-0000", hostname:$host, host_id:$host, pid_start:$ps,
			engine_version:"test", lock_dir:($tgt+"/.sentinel-shield/operation-lock.d")
		}' > "$_wt/.sentinel-shield/operation-lock.json"
}

resume() { sh "$RECOVER" --target "$1" --resume-rollback >/dev/null 2>&1; }
inspect() { sh "$RECOVER" --target "$1" --inspect >/dev/null 2>&1; }

# Source the library into THIS shell for the in-process unit assertions (classify + primitives).
# shellcheck source=/dev/null
. "$LIB_COMMON"
# shellcheck source=/dev/null
. "$LIB_TX"

# ============================================================================
# Schemas present + jq-valid (structural gate parity).
# ============================================================================
jq -e . "$LOCK_SCHEMA" >/dev/null 2>&1 && pass "operation-lock schema jq-valid" || fail "operation-lock schema jq-valid"
jq -e . "$INSPECT_SCHEMA" >/dev/null 2>&1 && pass "recovery-inspection schema jq-valid" || fail "recovery-inspection schema jq-valid"

# ============================================================================
# (1) TWO SIMULTANEOUS INSTALLS on one project — atomic lock; two cannot both proceed.
# ============================================================================
# Deterministic core: a pre-existing mutex directory (a sibling won the mkdir) makes a new
# --apply fail closed WITHOUT writing anything.
T1=$(mk_target)
mkdir "$T1/.sentinel-shield/operation-lock.d"
out=$(sh "$INSTALL" --target "$T1" --apply --force 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(1) a held mutex blocks a concurrent --apply (non-zero exit)" \
	|| fail "(1) held mutex blocks concurrent --apply (rc=$rc)"
[ ! -f "$T1/.sentinel-shield/installation.json" ] \
	&& pass "(1) blocked concurrent install wrote nothing" || fail "(1) blocked install wrote nothing"
case "$out" in *--recover*) pass "(1) blocked install points at recovery" ;; *) fail "(1) recovery hint offered" ;; esac
# Recovery clears a mutex-only (torn) lock, then install works again.
resume "$T1" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(1) recovery clears a mutex-only torn lock (exit 0)" || fail "(1) recovery clears torn mutex (rc=$rc)"
[ ! -d "$T1/.sentinel-shield/operation-lock.d" ] && pass "(1) mutex removed after recovery" || fail "(1) mutex removed"
sh "$INSTALL" --target "$T1" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(1) install succeeds after the mutex is cleared" || fail "(1) install works after clear (rc=$rc)"

# Real race: two backgrounded installs on a fresh target must leave a CONSISTENT result
# (no dangling lock/mutex/snapshot; installation.json valid) — the mutex serialises them.
T1b=$(mk_target)
sh "$INSTALL" --target "$T1b" --apply --force >/dev/null 2>&1 &
p1=$!
sh "$INSTALL" --target "$T1b" --apply --force >/dev/null 2>&1 &
p2=$!
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
_cons=1
[ -f "$T1b/.sentinel-shield/operation-lock.json" ] && _cons=0
[ -d "$T1b/.sentinel-shield/operation-lock.d" ] && _cons=0
[ -n "$(find "$T1b/.sentinel-shield" -maxdepth 1 -name '.txn-*' 2>/dev/null)" ] && _cons=0
jq -e . "$T1b/.sentinel-shield/installation.json" >/dev/null 2>&1 || _cons=0
[ "$_cons" = 1 ] && pass "(1) racing installs leave a consistent state (no dangling lock/mutex/snapshot)" \
	|| fail "(1) racing installs consistent"

# ============================================================================
# (2) TWO SIMULTANEOUS RECOVERIES — idempotent + safe; no data loss.
# ============================================================================
T2=$(mk_target)
TXN="$T2/.sentinel-shield/.txn-c2"; mkdir -p "$TXN/snap"
printf 'f.txt\n' > "$TXN/touched"
printf 'PRE\n' > "$TXN/snap/f.txt"
printf 'POST\n' > "$T2/f.txt"           # a modified file to restore
write_lock "$T2" "$TXN" "active"
sh "$RECOVER" --target "$T2" --resume-rollback >/dev/null 2>&1 &
r1=$!
sh "$RECOVER" --target "$T2" --resume-rollback >/dev/null 2>&1 &
r2=$!
rc1=0; wait "$r1" || rc1=$?
rc2=0; wait "$r2" || rc2=$?
# At least one must succeed; the target must end restored + cleared regardless of the interleave.
{ [ "$rc1" = 0 ] || [ "$rc2" = 0 ]; } && pass "(2) at least one concurrent recovery succeeds" \
	|| fail "(2) at least one concurrent recovery succeeds (rc1=$rc1 rc2=$rc2)"
[ "$(cat "$T2/f.txt" 2>/dev/null)" = "PRE" ] && pass "(2) modified file restored exactly once (no corruption)" \
	|| fail "(2) modified file restored (got '$(cat "$T2/f.txt" 2>/dev/null)')"
[ ! -f "$T2/.sentinel-shield/operation-lock.json" ] && pass "(2) lock cleared after concurrent recovery" || fail "(2) lock cleared"

# ============================================================================
# (3) PID-REUSE SIMULATION — a recycled PID is classified stale, not live.
# ============================================================================
LOCK="$WORK/classify-lock.json"    # _tx_owner_classify reads $LOCK
SS_DIR="$WORK"                     # not otherwise used here
sleep 30 & LIVEPID=$!
CHOST=$(_tx_hostname); CHID=$(_tx_host_id); REALSTART=$(_tx_pid_start "$LIVEPID")
# live: correct owner (alive PID + matching start identity, where the platform exposes one).
jq -n --arg h "$CHOST" --arg hi "$CHID" --argjson p "$LIVEPID" --arg ps "$REALSTART" \
	'{schema_version:"1",operation:"install",target:"/t",started_at:"2026-01-01T00:00:00Z",pid:$p,snapshot_dir:"/t/.sentinel-shield/.txn-x",state:"active",token:"tk",hostname:$h,host_id:$hi,pid_start:$ps,engine_version:"t",lock_dir:"/t/.sentinel-shield/operation-lock.d"}' > "$LOCK"
[ "$(_tx_owner_classify)" = "live" ] && pass "(3) a genuinely-live owner classifies 'live'" || fail "(3) live owner classify (got '$(_tx_owner_classify)')"
if [ -n "$REALSTART" ]; then
	# reuse: SAME (alive) PID but a DIFFERENT start identity => the PID was recycled.
	jq -n --arg h "$CHOST" --arg hi "$CHID" --argjson p "$LIVEPID" --arg ps "REUSED-$REALSTART" \
		'{schema_version:"1",operation:"install",target:"/t",started_at:"2026-01-01T00:00:00Z",pid:$p,snapshot_dir:"/t/.sentinel-shield/.txn-x",state:"active",token:"tk",hostname:$h,host_id:$hi,pid_start:$ps,engine_version:"t",lock_dir:"/t/.sentinel-shield/operation-lock.d"}' > "$LOCK"
	[ "$(_tx_owner_classify)" = "stale" ] && pass "(3) a reused PID (start mismatch) classifies 'stale'" \
		|| fail "(3) reused PID classify (got '$(_tx_owner_classify)')"
else
	pass "(3) process-start identity unavailable on this platform — reuse assertion skipped (documented degrade)"
fi
# foreign host: never mistaken for a live local process.
jq -n --argjson p "$LIVEPID" \
	'{schema_version:"1",operation:"install",target:"/t",started_at:"2026-01-01T00:00:00Z",pid:$p,snapshot_dir:"/t/.sentinel-shield/.txn-x",state:"active",token:"tk",hostname:"some-other-host-xyz",host_id:"some-other-host-xyz",pid_start:"0",engine_version:"t",lock_dir:"/t"}' > "$LOCK"
[ "$(_tx_owner_classify)" = "foreign" ] && pass "(3) a lock from another host classifies 'foreign'" || fail "(3) foreign host classify"
kill "$LIVEPID" 2>/dev/null || true
wait "$LIVEPID" 2>/dev/null || true
# dead PID => stale.
jq -n --arg h "$CHOST" --arg hi "$CHID" --argjson p "$LIVEPID" --arg ps "$REALSTART" \
	'{schema_version:"1",operation:"install",target:"/t",started_at:"2026-01-01T00:00:00Z",pid:$p,snapshot_dir:"/t/.sentinel-shield/.txn-x",state:"active",token:"tk",hostname:$h,host_id:$hi,pid_start:$ps,engine_version:"t",lock_dir:"/t"}' > "$LOCK"
[ "$(_tx_owner_classify)" = "stale" ] && pass "(3) a dead-PID lock classifies 'stale' (recoverable)" || fail "(3) dead PID classify"
unset LOCK SS_DIR

# The state machine rejects impossible transitions (explicit contract).
_tx_state_transition_ok active validating && pass "(3b) active->validating allowed" || fail "(3b) active->validating allowed"
_tx_state_transition_ok committing completed && pass "(3b) committing->completed allowed" || fail "(3b) committing->completed allowed"
! _tx_state_transition_ok completed active && pass "(3b) completed->active REJECTED" || fail "(3b) completed->active rejected"
! _tx_state_transition_ok rollback-incomplete completed && pass "(3b) rollback-incomplete->completed REJECTED" || fail "(3b) rollback-incomplete->completed rejected"
! _tx_state_transition_ok active active && pass "(3b) active->active REJECTED" || fail "(3b) active->active rejected"

# ============================================================================
# (4) KILLED AFTER SNAPSHOT, BEFORE WRITE — recovery restores (live == snapshot) + clears.
# ============================================================================
T4=$(mk_target)
TXN="$T4/.sentinel-shield/.txn-c4"; mkdir -p "$TXN/snap"
printf 'g.txt\n' > "$TXN/touched"
printf 'ORIG\n' > "$TXN/snap/g.txt"
printf 'ORIG\n' > "$T4/g.txt"           # write never happened: live still == snapshot
write_lock "$T4" "$TXN" "active"
resume "$T4" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(4) recovery after snapshot-before-write exits 0" || fail "(4) recovery exit 0 (rc=$rc)"
[ "$(cat "$T4/g.txt")" = "ORIG" ] && pass "(4) pre-write state preserved" || fail "(4) pre-write state preserved"
[ ! -f "$T4/.sentinel-shield/operation-lock.json" ] && pass "(4) lock cleared" || fail "(4) lock cleared"

# ============================================================================
# (5) KILLED AFTER WRITE, BEFORE VALIDATION — recovery restores the pre-write snapshot.
# ============================================================================
T5=$(mk_target)
TXN="$T5/.sentinel-shield/.txn-c5"; mkdir -p "$TXN/snap"
printf 'h.txt\n' > "$TXN/touched"
printf 'PRE\n' > "$TXN/snap/h.txt"
printf 'HALF-WRITTEN-POST\n' > "$T5/h.txt"   # written but not yet validated
write_lock "$T5" "$TXN" "active"
resume "$T5" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(5) recovery after write-before-validate exits 0" || fail "(5) recovery exit 0 (rc=$rc)"
[ "$(cat "$T5/h.txt")" = "PRE" ] && pass "(5) post-write content rolled back to pre-write snapshot" || fail "(5) rolled back to pre-write"

# ============================================================================
# (6) KILLED DURING COMMIT (state=committing) — COMPLETE-FORWARD, never roll back a success.
# ============================================================================
T6=$(mk_target)
TXN="$T6/.sentinel-shield/.txn-c6"; mkdir -p "$TXN/snap"
printf 'k.txt\n' > "$TXN/touched"
printf 'PRE\n' > "$TXN/snap/k.txt"
printf 'COMMITTED\n' > "$T6/k.txt"     # write + validation already succeeded
write_lock "$T6" "$TXN" "committing"
resume "$T6" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(6) recovery of a committing txn exits 0" || fail "(6) recovery committing exit 0 (rc=$rc)"
[ "$(cat "$T6/k.txt")" = "COMMITTED" ] && pass "(6) committed write NOT rolled back (complete-forward)" \
	|| fail "(6) committed write preserved (got '$(cat "$T6/k.txt")')"
[ ! -f "$T6/.sentinel-shield/operation-lock.json" ] && pass "(6) lock cleared after complete-forward" || fail "(6) lock cleared"

# ============================================================================
# (7) KILLED DURING ROLLBACK (state=rolling-back / rollback-incomplete) — resume completes it.
# ============================================================================
T7=$(mk_target)
TXN="$T7/.sentinel-shield/.txn-c7"; mkdir -p "$TXN/snap"
printf 'm.txt\n' > "$TXN/touched"
printf 'PRE\n' > "$TXN/snap/m.txt"
printf 'POST\n' > "$T7/m.txt"          # rollback had not yet restored it
write_lock "$T7" "$TXN" "rolling-back"
resume "$T7" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(7) resuming an interrupted rollback exits 0" || fail "(7) resume rollback exit 0 (rc=$rc)"
[ "$(cat "$T7/m.txt")" = "PRE" ] && pass "(7) interrupted rollback is completed (file restored)" || fail "(7) rollback completed"
# rollback-incomplete retry.
T7b=$(mk_target)
TXN="$T7b/.sentinel-shield/.txn-c7b"; mkdir -p "$TXN/snap"
printf 'm.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/m.txt"; printf 'POST\n' > "$T7b/m.txt"
write_lock "$T7b" "$TXN" "rollback-incomplete"
resume "$T7b" && rc=0 || rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T7b/m.txt")" = "PRE" ] && pass "(7) rollback-incomplete retry completes the rollback" \
	|| fail "(7) rollback-incomplete retry (rc=$rc content='$(cat "$T7b/m.txt" 2>/dev/null)')"

# ============================================================================
# (8) JOURNAL PARTIAL FINAL LINE — inspect (strict) REJECTS; resume (lenient) tolerates the tail.
# ============================================================================
T8=$(mk_target)
TXN="$T8/.sentinel-shield/.txn-c8"; mkdir -p "$TXN/snap"
printf 'p.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/p.txt"; printf 'POST\n' > "$T8/p.txt"
write_lock "$T8" "$TXN" "active"
# A valid single-entry journal (correctly chained), then a torn trailing line (crash mid-append).
J8="$T8/.sentinel-shield/transaction-journal.jsonl"
_b=$(jq -cn '{schema_version:"1",seq:1,ts:"2026-01-01T00:00:00Z",operation:"install",pid:1,phase:"start",path:"",detail:"begin",prev:""}')
_h=$(printf '%s' "$_b" | th_hash)
printf '%s' "$_b" | jq -c --arg h "$_h" '. + {hash:$h}' > "$J8"
printf '{"schema_version":"1","seq":2,"ts":"2026' >> "$J8"     # torn tail
inspect "$T8" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(8) --inspect (strict) rejects a partial trailing journal line (exit 4)" || fail "(8) inspect rejects partial (rc=$rc)"
resume "$T8" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(8) --resume-rollback (lenient) tolerates the torn tail and recovers (exit 0)" || fail "(8) resume tolerates torn tail (rc=$rc)"
[ "$(cat "$T8/p.txt")" = "PRE" ] && pass "(8) recovery still restored the pre-write state" || fail "(8) recovery restored state"

# A PREFIX-tampered journal (not just a torn tail) must fail closed on resume too.
T8b=$(mk_target)
TXN="$T8b/.sentinel-shield/.txn-c8b"; mkdir -p "$TXN/snap"
printf 'p.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/p.txt"; printf 'POST\n' > "$T8b/p.txt"
write_lock "$T8b" "$TXN" "active"
J8b="$T8b/.sentinel-shield/transaction-journal.jsonl"
printf '%s' "$_b" | jq -c --arg h "$_h" '. + {hash:$h}' > "$J8b"
# Tamper the (complete, non-tail) first line's detail without fixing its hash, then add a 2nd line.
awk 'NR==1{sub(/"detail":"begin"/,"\"detail\":\"TAMPERED\"")} {print}' "$J8b" > "$J8b.x" && mv "$J8b.x" "$J8b"
_b2=$(jq -cn --arg pv "$_h" '{schema_version:"1",seq:2,ts:"2026-01-01T00:00:01Z",operation:"install",pid:1,phase:"precondition",path:"",detail:"x",prev:$pv}')
_h2=$(printf '%s' "$_b2" | th_hash); printf '%s' "$_b2" | jq -c --arg h "$_h2" '. + {hash:$h}' >> "$J8b"
resume "$T8b" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(8) prefix-tampered journal fails closed on resume (exit 4)" || fail "(8) prefix tamper resume fail-closed (rc=$rc)"
[ "$(cat "$T8b/p.txt")" = "POST" ] && pass "(8) nothing rolled back when the journal is tampered" || fail "(8) no rollback on tamper"

# ============================================================================
# (9) LOCK PARTIAL WRITE — a truncated lock JSON fails closed; a mutex-only torn lock is clearable.
# ============================================================================
T9=$(mk_target)
printf '{"schema_version":"1","operation":"install","target":"%s","started_at":"2026' "$T9" \
	> "$T9/.sentinel-shield/operation-lock.json"    # truncated (partial) lock write
resume "$T9" && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(9) a partially-written lock fails closed (exit 4)" || fail "(9) partial lock fail-closed (rc=$rc)"
[ -f "$T9/.sentinel-shield/operation-lock.json" ] && pass "(9) partial lock retained (not destroyed)" || fail "(9) partial lock retained"
# Mutex-only torn acquisition: install detects it and recovery clears it.
T9b=$(mk_target); mkdir "$T9b/.sentinel-shield/operation-lock.d"
sh "$INSTALL" --target "$T9b" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(9) a torn mutex-only lock blocks a new install" || fail "(9) torn mutex blocks install (rc=$rc)"

# ============================================================================
# (10) SNAPSHOT COPY FAILURE — tx_snapshot fails closed (abort), never mutating live state.
# ============================================================================
T10=$(mk_target)
TARGET="$T10"; SS_DIR="$T10/.sentinel-shield"; LOCK="$SS_DIR/operation-lock.json"; TX_OP="install"
TX_SNAP="$SS_DIR/.txn-s10"; mkdir -p "$TX_SNAP/snap"; : > "$TX_SNAP/touched"
printf 'LIVE\n' > "$T10/s.txt"
mkdir -p "$TX_SNAP/snap/s.txt"          # force the snapshot copy to FAIL (dest is a directory)
( tx_snapshot "s.txt" ) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(10) a failed snapshot copy fails closed (exit 4)" || fail "(10) snapshot-copy failure fail-closed (rc=$rc)"
unset TARGET SS_DIR LOCK TX_OP TX_SNAP

# ============================================================================
# (11) TARGET WRITE FAILURE (permission denied) — tx_install_file fails closed; file untouched.
# ============================================================================
if [ "$IS_ROOT" = 0 ]; then
	T11=$(mk_target)
	TARGET="$T11"; SS_DIR="$T11/.sentinel-shield"; LOCK="$SS_DIR/operation-lock.json"; TX_OP="install"
	TX_SNAP="$SS_DIR/.txn-s11"; mkdir -p "$TX_SNAP/snap"; : > "$TX_SNAP/touched"
	mkdir -p "$T11/sub"; printf 'ORIGINAL\n' > "$T11/sub/w.txt"
	SRC="$WORK/src11"; printf 'NEWCONTENT\n' > "$SRC"
	chmod 500 "$T11/sub"                  # read-only parent: staging the temp will fail
	( tx_install_file "$SRC" "sub/w.txt" ) && rc=0 || rc=$?
	chmod 700 "$T11/sub"
	[ "$rc" = 4 ] && pass "(11) a permission-denied managed write fails closed (exit 4)" || fail "(11) target-write failure fail-closed (rc=$rc)"
	[ "$(cat "$T11/sub/w.txt")" = "ORIGINAL" ] && pass "(11) the managed file was left byte-for-byte (no partial write)" || fail "(11) managed file untouched"
	unset TARGET SS_DIR LOCK TX_OP TX_SNAP
else
	pass "(11) skipped under root (permission gate not enforceable)"
fi

# ============================================================================
# (12) POST-WRITE DIGEST MISMATCH — a corrupted write is detected and fails closed.
# ============================================================================
T12=$(mk_target)
TARGET="$T12"; SS_DIR="$T12/.sentinel-shield"; LOCK="$SS_DIR/operation-lock.json"; TX_OP="install"
TX_SNAP="$SS_DIR/.txn-s12"; mkdir -p "$TX_SNAP/snap"; : > "$TX_SNAP/touched"
SRC="$WORK/src12"; printf 'GOOD\n' > "$SRC"
( SENTINEL_SHIELD_TX_CORRUPT_AFTER_WRITE="d.txt" tx_install_file "$SRC" "d.txt" ) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(12) a post-write digest mismatch fails closed (exit 4)" || fail "(12) post-write digest mismatch fail-closed (rc=$rc)"
unset TARGET SS_DIR LOCK TX_OP TX_SNAP

# ============================================================================
# (13) DISK-FULL (constrained fixture) — an interrupted/ENOSPC write leaves no partial file.
# ============================================================================
T13=$(mk_target)
TARGET="$T13"; SS_DIR="$T13/.sentinel-shield"; LOCK="$SS_DIR/operation-lock.json"; TX_OP="install"
TX_SNAP="$SS_DIR/.txn-s13"; mkdir -p "$TX_SNAP/snap"; : > "$TX_SNAP/touched"
printf 'EXISTING\n' > "$T13/e.txt"
SRC="$WORK/src13"; printf 'REPLACEMENT\n' > "$SRC"
( SENTINEL_SHIELD_TX_SIMULATE_ENOSPC="e.txt" tx_install_file "$SRC" "e.txt" ) && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(13) a simulated disk-full write fails closed (exit 4)" || fail "(13) disk-full fail-closed (rc=$rc)"
[ "$(cat "$T13/e.txt")" = "EXISTING" ] && pass "(13) the pre-existing file survives an ENOSPC write" || fail "(13) file survives ENOSPC"
[ -z "$(find "$T13" -maxdepth 1 -name '.ss-inflight*' 2>/dev/null)" ] && pass "(13) no in-flight temp left behind" || fail "(13) in-flight temp cleaned up"
unset TARGET SS_DIR LOCK TX_OP TX_SNAP

# ============================================================================
# (14) REPEATED RECOVERY INVOCATION — idempotent (a second run is a clean no-op).
# ============================================================================
T14=$(mk_target)
TXN="$T14/.sentinel-shield/.txn-c14"; mkdir -p "$TXN/snap"
printf 'v.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/v.txt"; printf 'POST\n' > "$T14/v.txt"
write_lock "$T14" "$TXN" "active"
resume "$T14" && rc1=0 || rc1=$?
resume "$T14" && rc2=0 || rc2=$?
resume "$T14" && rc3=0 || rc3=$?
{ [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ]; } \
	&& pass "(14) recovery is idempotent across repeated invocations (all exit 0)" \
	|| fail "(14) repeated recovery idempotent (rc=$rc1/$rc2/$rc3)"
[ "$(cat "$T14/v.txt")" = "PRE" ] && pass "(14) file restored once and stays restored" || fail "(14) file stays restored"

# ============================================================================
# (15) A COMPLETED TRANSACTION CANNOT BE RECOVERED AGAIN (never re-rolled-back).
# ============================================================================
T15=$(mk_target)
TXN="$T15/.sentinel-shield/.txn-c15"; mkdir -p "$TXN/snap"
printf 'z.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/z.txt"; printf 'DONE\n' > "$T15/z.txt"
write_lock "$T15" "$TXN" "completed"
resume "$T15" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(15) recovering a completed txn exits 0 (clear only)" || fail "(15) completed recover exit 0 (rc=$rc)"
[ "$(cat "$T15/z.txt")" = "DONE" ] && pass "(15) a completed txn is NEVER rolled back" || fail "(15) completed not rolled back (got '$(cat "$T15/z.txt")')"
[ ! -f "$T15/.sentinel-shield/operation-lock.json" ] && pass "(15) completed lock cleared" || fail "(15) completed lock cleared"
resume "$T15" && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(15) a second recovery of the (now cleared) txn is a clean no-op" || fail "(15) second recover no-op (rc=$rc)"

# ============================================================================
# Output contract: recover --inspect --format json exposes the required fields + conforms.
# ============================================================================
T16=$(mk_target)
TXN="$T16/.sentinel-shield/.txn-c16"; mkdir -p "$TXN/snap"
printf 'q.txt\n' > "$TXN/touched"; printf 'PRE\n' > "$TXN/snap/q.txt"; printf 'POST\n' > "$T16/q.txt"
write_lock "$T16" "$TXN" "active" 4242 "" "$(uname -n 2>/dev/null || echo host)"
IJSON="$WORK/inspect.json"
sh "$RECOVER" --target "$T16" --inspect --format json > "$IJSON" 2>/dev/null && rc=0 || rc=$?
[ "$rc" = 0 ] && jq -e . "$IJSON" >/dev/null 2>&1 && pass "(oc) --inspect --format json emits valid JSON (exit 0)" || fail "(oc) inspect json valid (rc=$rc)"
# Structural conformance to schemas/recovery-inspection.schema.json (jq, no ajv).
if jq -e '
	(.schema == "recovery-inspection") and (.target | type=="string" and (length>0)) and
	((.state|type) as $t | ($t=="string" or $t=="null")) and
	(.lock_owner | type=="object") and (.lock_owner | has("pid") and has("token") and has("hostname")) and
	(.journal_valid | type=="boolean") and (.safe_to_resume | type=="boolean") and
	(.safe_to_rollback | type=="boolean") and (.required_manual_actions | type=="array")
' "$IJSON" >/dev/null 2>&1; then
	pass "(oc) inspection JSON conforms (state, lock_owner{pid,token,hostname}, journal_valid, safe_to_resume/rollback, required_manual_actions)"
else
	fail "(oc) inspection JSON conforms: $(jq -c . "$IJSON" 2>/dev/null)"
fi
[ "$(jq -r '.state' "$IJSON")" = "active" ] && pass "(oc) reported state=active" || fail "(oc) reported state"
[ "$(jq -r '.lock_owner.pid' "$IJSON")" = "4242" ] && pass "(oc) lock_owner.pid surfaced" || fail "(oc) lock_owner.pid"
[ "$(jq -r '.safe_to_rollback' "$IJSON")" = "true" ] && pass "(oc) a clean interrupted op is safe_to_rollback" || fail "(oc) safe_to_rollback true"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll transaction-durability assertions passed.\n'
exit 0
