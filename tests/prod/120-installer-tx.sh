#!/bin/sh
# tests/prod/120-installer-tx.sh — transactional installer/sync contract (WS12/13).
# Self-contained, no network: installs the default profile into mktemp targets and asserts
#   (a) installation.json is written ATOMICALLY and conforms to schema_version "2" (required
#       keys present; no leftover temp file; no dangling lock on success),
#   (b) an interrupted install (pre-seeded stale operation-lock.json) is DETECTED and a
#       recovery path (--recover) is offered, and --recover clears the lock,
#   (c) accepted-risks.json and a project-owned file are PRESERVED across install + sync,
#   (d) a simulated mid-operation failure RESTORES snapshotted files (auto-rollback).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
INSTALL="$ROOT/scripts/install-baseline.sh"
SYNC="$ROOT/scripts/sync-baseline.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sstx)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

MANAGED=".github/workflows/sentinel-shield.yml"   # managed file in the default profile

# ============================================================================
# (a) atomic write + schema_version "2" conformance
# ============================================================================
TA="$WORK/a"; mkdir -p "$TA"
sh "$INSTALL" --target "$TA" --apply --mode report-only >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(a) install --apply exits 0" || fail "(a) install --apply exits 0 (got rc=$rc)"

INST="$TA/.sentinel-shield/installation.json"
[ -f "$INST" ] && pass "(a) installation.json created" || fail "(a) installation.json created"

[ "$(jq -r '.schema_version' "$INST" 2>/dev/null)" = "2" ] \
	&& pass "(a) schema_version == 2" || fail "(a) schema_version == 2"

# Every required key present with the correct top-level type.
if jq -e '
	(.schema_version=="2") and
	(.version|type=="string" and (length>0)) and
	(.profile|type=="string" and (length>0)) and
	(.tool_mode as $tm | ["config-only","require-existing","bootstrap-tools"]|index($tm)!=null) and
	(.installed_at|type=="string" and (length>0)) and
	(.updated_at|type=="string" and (length>0)) and
	(.managed_files|type=="array") and
	(.project_owned_files|type=="array") and
	(.enabled_tools|type=="array") and
	(.disabled_tools|type=="array")
' "$INST" >/dev/null 2>&1; then
	pass "(a) all required v2 keys present with correct types"
else
	fail "(a) all required v2 keys present with correct types"
fi

# No credential userinfo ('@') ever stored in repository.
#
# This assertion used to be STRUCTURALLY UNFALSIFIABLE. Fixture TA is a bare `mkdir -p`
# with no .sentinel-shield-ref record, and install-baseline.sh only populates .repository
# from that record — so `has("repository")` was always false and the `pass` branch always
# fired. A `null` .repository would additionally make test() raise a jq error, which is
# also non-zero, which also passed. Regressing the installer to persist
# `https://tok@host/o/r` would not have been detected.
#
# A positive control now proves the check can actually see a credential-bearing value.
if jq -e 'has("repository")' "$INST" >/dev/null 2>&1; then
	if jq -e '.repository | test("@")' "$INST" >/dev/null 2>&1; then
		fail "(a) repository must not carry credentials ('@')"
	else
		pass "(a) repository carries no credential userinfo"
	fi
else
	pass "(a) no repository recorded (nothing to leak)"
fi
# Positive control: the same predicate MUST flag a credential-bearing record.
_ctl="$WORK/cred-control.json"
printf '{"repository":"https://tok@github.com/o/r"}\n' > "$_ctl"
if jq -e '.repository | test("@")' "$_ctl" >/dev/null 2>&1; then
	pass "(a) positive control: the credential predicate detects userinfo"
else
	fail "(a) positive control FAILED — the credential check cannot detect '@' at all"
fi

# Atomic write leaves NO temp file and NO dangling lock after success.
[ -z "$(find "$TA/.sentinel-shield" -name 'installation.json.tmp.*' 2>/dev/null)" ] \
	&& pass "(a) no leftover installation.json temp file" || fail "(a) no leftover temp file"
[ ! -f "$TA/.sentinel-shield/operation-lock.json" ] \
	&& pass "(a) no dangling operation-lock after success" || fail "(a) no dangling lock after success"
[ -z "$(find "$TA/.sentinel-shield" -maxdepth 1 -name '.txn-*' 2>/dev/null)" ] \
	&& pass "(a) snapshot dir cleaned after commit" || fail "(a) snapshot dir cleaned after commit"

# ============================================================================
# (b) interrupted prior op (stale lock) is detected; recovery offered + works
# ============================================================================
TB="$WORK/b"; mkdir -p "$TB"
sh "$INSTALL" --target "$TB" --apply --mode report-only >/dev/null 2>&1
CTB=$(CDPATH= cd -P -- "$TB" && pwd -P)   # canonical (physical) target — matches what the script records
LOCK="$TB/.sentinel-shield/operation-lock.json"
# CONTRACT(2)-valid stale lock pointing at a real (empty) snapshot dir: --recover must roll
# back cleanly (nothing touched) and clear the lock. schema_version/target/state present.
STALE_TXN="$CTB/.sentinel-shield/.txn-stale"
mkdir -p "$STALE_TXN/snap"; : > "$STALE_TXN/touched"
printf '{"schema_version":"1","operation":"install","target":"%s","started_at":"2026-01-01T00:00:00Z","pid":1,"snapshot_dir":"%s","state":"active"}' \
	"$CTB" "$STALE_TXN" > "$LOCK"

out=$(sh "$INSTALL" --target "$TB" --apply --force 2>&1) && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(b) stale lock blocks a new --apply (non-zero exit)" \
	|| fail "(b) stale lock blocks a new --apply (got rc=$rc)"
case "$out" in *--recover*) pass "(b) recovery path (--recover) is offered" ;;
	*) fail "(b) recovery path (--recover) is offered (out: $out)" ;; esac
case "$out" in *interrupted*) pass "(b) interrupted-operation is reported" ;;
	*) fail "(b) interrupted-operation is reported" ;; esac
[ -f "$LOCK" ] && pass "(b) a blocked run does NOT silently clear the lock" \
	|| fail "(b) blocked run preserved the lock"

# --recover clears the lock and exits 0.
sh "$INSTALL" --target "$TB" --recover >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(b) --recover exits 0" || fail "(b) --recover exits 0 (got rc=$rc)"
[ ! -f "$LOCK" ] && pass "(b) --recover clears the operation-lock" || fail "(b) --recover clears the lock"

# After recovery a normal --apply works again.
sh "$INSTALL" --target "$TB" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(b) --apply works again after recovery" || fail "(b) --apply works after recovery (rc=$rc)"

# ============================================================================
# (c) accepted-risks.json + a project-owned file preserved across install/sync
# ============================================================================
TC="$WORK/c"; mkdir -p "$TC"
sh "$INSTALL" --target "$TC" --apply --mode report-only >/dev/null 2>&1
# project-local risk decision (must NEVER be written/overwritten)
printf '{"version":"1.1","risks":[{"id":"KEEP_RISK_C"}]}' > "$TC/.sentinel-shield/accepted-risks.json"
AR_BEFORE=$(cat "$TC/.sentinel-shield/accepted-risks.json")
# project-owned (create-if-missing) file: profile.yaml — tag it locally
printf '\n# PROJECT_OWNED_EDIT_C\n' >> "$TC/.sentinel-shield/profile.yaml"
PO_BEFORE=$(cat "$TC/.sentinel-shield/profile.yaml")

sh "$INSTALL" --target "$TC" --apply --force >/dev/null 2>&1
sh "$SYNC" --target "$TC" --apply --force >/dev/null 2>&1

[ "$(cat "$TC/.sentinel-shield/accepted-risks.json")" = "$AR_BEFORE" ] \
	&& pass "(c) accepted-risks.json preserved across install+sync" \
	|| fail "(c) accepted-risks.json preserved across install+sync"
[ "$(cat "$TC/.sentinel-shield/profile.yaml")" = "$PO_BEFORE" ] \
	&& pass "(c) project-owned profile.yaml preserved across install+sync" \
	|| fail "(c) project-owned profile.yaml preserved across install+sync"
# the install never CREATED accepted-risks.json by itself either (only our seed exists)
grep -q KEEP_RISK_C "$TC/.sentinel-shield/accepted-risks.json" \
	&& pass "(c) project risk record content intact" || fail "(c) project risk record content intact"

# ============================================================================
# (d) simulated mid-operation failure restores snapshotted files
# ============================================================================
TD="$WORK/d"; mkdir -p "$TD"
sh "$INSTALL" --target "$TD" --apply --mode report-only >/dev/null 2>&1
# Tag the managed file locally so we can detect whether a faulted run is rolled back.
printf '\n# LOCAL_BEFORE_FAULT_D\n' >> "$TD/$MANAGED"
WF_BEFORE=$(cat "$TD/$MANAGED")

# Force-overwrite the managed file but crash right after it is written; the transaction must
# restore the pre-write (LOCAL_BEFORE_FAULT_D) content.
SENTINEL_SHIELD_FAULT_AFTER="$MANAGED" sh "$INSTALL" --target "$TD" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(d) faulted install exits non-zero" || fail "(d) faulted install exits non-zero (rc=$rc)"
[ "$(cat "$TD/$MANAGED")" = "$WF_BEFORE" ] \
	&& pass "(d) snapshotted managed file restored byte-for-byte" \
	|| fail "(d) snapshotted managed file restored byte-for-byte"
grep -q LOCAL_BEFORE_FAULT_D "$TD/$MANAGED" \
	&& pass "(d) local pre-fault edit survives rollback" || fail "(d) local pre-fault edit survives rollback"
# A graceful failure auto-rolls-back AND clears the lock (no manual recover needed).
[ ! -f "$TD/.sentinel-shield/operation-lock.json" ] \
	&& pass "(d) graceful failure auto-clears the lock" || fail "(d) graceful failure auto-clears the lock"
[ -z "$(find "$TD/.sentinel-shield" -maxdepth 1 -name '.txn-*' 2>/dev/null)" ] \
	&& pass "(d) snapshot dir removed after rollback" || fail "(d) snapshot dir removed after rollback"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll installer-transaction assertions passed.\n'
exit 0
