#!/bin/sh
# tests/prod/210-transaction-journal.sh — append-only transaction JOURNAL + integrity contract.
#
# Drives scripts/install-baseline.sh (which now journals every transaction phase via the shared
# scripts/lib/transaction.sh) and scripts/recover-operation.sh with FAULT INJECTION, asserting:
#   (a) a successful install writes a JSONL journal whose every line conforms to
#       schemas/transaction-journal.schema.json and covers all seven phases;
#   (b) recover-operation.sh --inspect verifies the chain (exit 0) on an untampered journal;
#   (c) a faulted install records rollback-step entries (the rollback is journalled);
#   (d) in-place TAMPER of any entry is REJECTED (--inspect exit 4);
#   (e) a PARTIAL/truncated trailing entry is REJECTED (--inspect exit 4);
#   (f) an entry carrying an UNSAFE (traversal) path is REJECTED even with a valid hash chain;
#   (g) the journal leaks NO secrets / NO file contents.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
INSTALL="$ROOT/scripts/install-baseline.sh"
RECOVER="$ROOT/scripts/recover-operation.sh"
SCHEMA="$ROOT/schemas/transaction-journal.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssjrnl)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

MANAGED=".github/workflows/sentinel-shield.yml"

# th_hash — same digest the library uses (sha256, else cksum fallback), reading stdin.
th_hash() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
	else printf 'cksum:'; cksum | awk '{print $1}'; fi
}

# ============================================================================
# (a) a successful install journals every phase; every line conforms to the schema
# ============================================================================
TA="$WORK/a"; mkdir -p "$TA"
sh "$INSTALL" --target "$TA" --apply --mode report-only >/dev/null 2>&1
sh "$INSTALL" --target "$TA" --apply --force >/dev/null 2>&1
J="$TA/.sentinel-shield/transaction-journal.jsonl"
[ -f "$J" ] && pass "(a) transaction journal created" || fail "(a) transaction journal created"

# Every line is valid JSON AND conforms to the single-entry schema contract.
_bad=0; _n=0
while IFS= read -r _l || [ -n "$_l" ]; do
	[ -n "$_l" ] || continue
	_n=$((_n + 1))
	printf '%s' "$_l" | jq -e '
		(.schema_version=="1") and (.seq|type=="number") and (.ts|type=="string" and (length>0)) and
		(.operation|type=="string") and (.pid|type=="number") and
		(.phase as $p|["start","precondition","snapshot","mutation","validation","rollback-step","completion"]|index($p)!=null) and
		(.path|type=="string") and (.detail|type=="string") and (.prev|type=="string") and
		(.hash|type=="string" and (length>0))
	' >/dev/null 2>&1 || _bad=$((_bad + 1))
done < "$J"
[ "$_bad" -eq 0 ] && [ "$_n" -gt 0 ] && pass "(a) all $_n journal lines conform to the entry schema" || fail "(a) journal lines conform ($_bad bad of $_n)"

# The schema file itself is jq-valid (structural gate parity).
jq -e . "$SCHEMA" >/dev/null 2>&1 && pass "(a) transaction-journal.schema.json is jq-valid" || fail "(a) schema jq-valid"

# All seven phases are present after a real (create + validate + commit) install.
_missing=""
_phases=$(jq -rs 'map(.phase)|unique|join(" ")' "$J")
for _p in start precondition snapshot mutation validation completion; do
	case " $_phases " in *" $_p "*) ;; *) _missing="$_missing $_p" ;; esac
done
[ -z "$_missing" ] && pass "(a) journal covers start/precondition/snapshot/mutation/validation/completion" \
	|| fail "(a) journal missing phases:$_missing"

# seq is a strict 1..N monotonic run.
if jq -rs '[.[].seq] == [range(1; length+1)]' "$J" | grep -qx true; then
	pass "(a) journal seq is a 1..N monotonic run"
else
	fail "(a) journal seq is a 1..N monotonic run"
fi

# ============================================================================
# (b) recover-operation.sh --inspect verifies the untampered chain (exit 0)
# ============================================================================
sh "$RECOVER" --target "$TA" --inspect >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(b) --inspect verifies an untampered journal (exit 0)" || fail "(b) --inspect exit 0 (got $rc)"

# ============================================================================
# (c) a faulted install journals rollback-step entries (rollback is audited)
# ============================================================================
TC="$WORK/c"; mkdir -p "$TC"
sh "$INSTALL" --target "$TC" --apply --mode report-only >/dev/null 2>&1
SENTINEL_SHIELD_FAULT_AFTER="$MANAGED" sh "$INSTALL" --target "$TC" --apply --force >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" != 0 ] && pass "(c) faulted install exits non-zero" || fail "(c) faulted install exits non-zero (rc=$rc)"
JC="$TC/.sentinel-shield/transaction-journal.jsonl"
jq -e -s 'any(.[]; .phase=="rollback-step")' "$JC" >/dev/null 2>&1 \
	&& pass "(c) rollback-step recorded for the faulted run" || fail "(c) rollback-step recorded"
# The chain is still consistent after the fault+rollback.
sh "$RECOVER" --target "$TC" --inspect >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(c) journal chain intact after fault+rollback" || fail "(c) chain intact after fault (rc=$rc)"

# ============================================================================
# (d) in-place TAMPER of an entry is rejected (--inspect exit 4)
# ============================================================================
TD="$WORK/d"; mkdir -p "$TD"
sh "$INSTALL" --target "$TD" --apply --mode report-only >/dev/null 2>&1
JD="$TD/.sentinel-shield/transaction-journal.jsonl"
# rewrite line 2's detail WITHOUT recomputing its hash -> hash mismatch.
awk 'NR==2{sub(/"detail":"[^"]*"/,"\"detail\":\"TAMPERED\"")} {print}' "$JD" > "$JD.x" && mv "$JD.x" "$JD"
sh "$RECOVER" --target "$TD" --inspect >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(d) in-place tamper rejected (exit 4)" || fail "(d) tamper rejected (got $rc)"

# ============================================================================
# (e) a PARTIAL / truncated trailing entry is rejected (--inspect exit 4)
# ============================================================================
TE="$WORK/e"; mkdir -p "$TE"
sh "$INSTALL" --target "$TE" --apply --mode report-only >/dev/null 2>&1
JE="$TE/.sentinel-shield/transaction-journal.jsonl"
# Append a truncated (non-JSON) line, simulating a crash mid-append.
printf '{"schema_version":"1","seq":999,"ts":"2026' >> "$JE"
sh "$RECOVER" --target "$TE" --inspect >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(e) partial/truncated entry rejected (exit 4)" || fail "(e) partial entry rejected (got $rc)"

# ============================================================================
# (f) an UNSAFE (traversal) path is rejected even with a VALID hash chain
# ============================================================================
TF="$WORK/f"; mkdir -p "$TF/.sentinel-shield"
JF="$TF/.sentinel-shield/transaction-journal.jsonl"
# Forge a fully valid, correctly-chained single entry whose path is a traversal escape.
_body=$(jq -cn --arg sv "1" --argjson seq 1 --arg ts "2026-01-01T00:00:00Z" \
	--arg op "install" --argjson pid 1 --arg phase "snapshot" \
	--arg path "../escape" --arg detail "forged" --arg prev "" \
	'{schema_version:$sv, seq:$seq, ts:$ts, operation:$op, pid:$pid, phase:$phase, path:$path, detail:$detail, prev:$prev}')
_h=$(printf '%s' "$_body" | th_hash)
printf '%s' "$_body" | jq -c --arg h "$_h" '. + {hash:$h}' > "$JF"
# Sanity: the forged entry's hash chain is itself valid (so ONLY the path check can reject it).
_body2=$(jq -c 'del(.hash)' "$JF"); _h2=$(printf '%s' "$_body2" | th_hash)
[ "$_h2" = "$(jq -r '.hash' "$JF")" ] && pass "(f) forged entry has a valid hash (isolates the path check)" || fail "(f) forged entry hash setup"
sh "$RECOVER" --target "$TF" --inspect >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 4 ] && pass "(f) unsafe traversal path rejected (exit 4)" || fail "(f) unsafe path rejected (got $rc)"

# ============================================================================
# (g) the journal leaks NO secrets / NO file contents
# ============================================================================
TG="$WORK/g"; mkdir -p "$TG"
sh "$INSTALL" --target "$TG" --apply --mode report-only >/dev/null 2>&1
# Plant a unique marker INSIDE a managed file, then force-sync/overwrite it.
MARK="SS_JOURNAL_SECRET_MARKER_9F3A"
printf '\n# %s\n' "$MARK" >> "$TG/$MANAGED"
sh "$INSTALL" --target "$TG" --apply --force >/dev/null 2>&1
JG="$TG/.sentinel-shield/transaction-journal.jsonl"
if grep -q "$MARK" "$JG" 2>/dev/null; then
	fail "(g) journal must NOT contain file contents (marker leaked)"
else
	pass "(g) journal contains no file contents (only paths + phase details)"
fi

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll transaction-journal assertions passed.\n'
exit 0
