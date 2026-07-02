#!/bin/sh
# Sentinel Shield — interrupted-operation inspector / recovery driver.
#
# A thin operator front-end over scripts/lib/transaction.sh. It inspects the operation-lock
# and the append-only transaction journal of a consuming project, and (on request) resumes the
# SAME fail-closed rollback the install/sync/migrate scripts expose via --recover — without
# duplicating any tx_* logic.
#
# Modes:
#   inspect          Read-only. Report the interrupted operation (if any) from the lock, then
#                    VALIDATE the transaction journal chain and REJECT tampered/partial entries.
#                    Exit 0 when consistent; exit 4 when the journal is tampered/partial.
#   resume-rollback  Perform the fail-closed rollback (tx_recover): restore snapshots / remove
#                    created files and clear the lock ONLY when every recovery step holds;
#                    otherwise retain the lock + snapshots and exit 4.
#
# Usage:
#   sh scripts/recover-operation.sh --target <dir> [--mode inspect|resume-rollback]
#   sh scripts/recover-operation.sh --target <dir> --inspect
#   sh scripts/recover-operation.sh --target <dir> --resume-rollback
#
# Exit codes: 0 ok/consistent; 2 invalid invocation / missing jq / not a target; 4 interrupted
#             operation could not be (or was not) safely cleared, or journal integrity failed.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

TARGET=""; MODE="inspect"

usage() {
	cat <<'EOF'
Usage: recover-operation.sh --target <dir> [--mode inspect|resume-rollback]
  --target <dir>       Consuming project directory (required; must hold .sentinel-shield/).
  --mode <mode>        inspect (default) | resume-rollback.
  --inspect            Alias for --mode inspect (read-only report + journal integrity check).
  --resume-rollback    Alias for --mode resume-rollback (fail-closed tx_recover).
  -h, --help           Show help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--inspect) MODE="inspect"; shift ;;
		--resume-rollback) MODE="resume-rollback"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) log_error "unknown argument '$1'"; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { log_error "--target is required"; usage; exit 2; }
[ -d "$TARGET" ] || { log_error "target '$TARGET' is not a directory"; exit 2; }
TARGET=$(CDPATH= cd -P -- "$TARGET" && pwd -P) || { log_error "cannot resolve target '$TARGET'"; exit 2; }
[ -d "$TARGET/.sentinel-shield" ] || { log_error "'$TARGET/.sentinel-shield' not found — not a Sentinel Shield consumer."; exit 2; }
command_exists jq || { log_error "jq is required."; exit 2; }
case "$MODE" in inspect|resume-rollback) ;; *) log_error "invalid --mode '$MODE' (inspect|resume-rollback)"; exit 2 ;; esac

# Caller contract for transaction.sh (see its header). TX_SELF points recovery hints back here.
SS_DIR="$TARGET/.sentinel-shield"
LOCK="$SS_DIR/operation-lock.json"
JOURNAL="$SS_DIR/transaction-journal.jsonl"
TX_OP="unknown"; TX_SELF="scripts/recover-operation.sh"; TX_ACTIVE=0; TX_SNAP=""
# shellcheck source=scripts/lib/transaction.sh
. "$SCRIPT_DIR/lib/transaction.sh"

# journal_verify — validate the append-only journal chain. Rejects: a non-JSON (partial/truncated)
# line; a missing required field; an unsafe (absolute/traversal) path; a broken seq; a broken prev
# linkage; and a recomputed hash mismatch (in-place tampering). Prints the first failure and
# returns 4; returns 0 when the journal is absent or fully consistent. Read-only.
journal_verify() {
	[ -f "$JOURNAL" ] || { echo "journal: none present ($JOURNAL absent)."; return 0; }
	_jv_prev=""; _jv_expect=1; _jv_n=0
	while IFS= read -r _line || [ -n "$_line" ]; do
		[ -n "$_line" ] || continue
		_jv_n=$((_jv_n + 1))
		if ! printf '%s' "$_line" | jq -e . >/dev/null 2>&1; then
			echo "journal: TAMPER/PARTIAL at line $_jv_n — not valid JSON (truncated or corrupt entry)." >&2
			return 4
		fi
		# Required fields + correct types.
		if ! printf '%s' "$_line" | jq -e '
			(.schema_version=="1") and (.seq|type=="number") and
			(.ts|type=="string" and (length>0)) and
			(.operation|type=="string") and (.pid|type=="number") and
			(.phase as $p | ["start","precondition","snapshot","mutation","validation","rollback-step","completion"]|index($p)!=null) and
			(.path|type=="string") and (.detail|type=="string") and
			(.prev|type=="string") and (.hash|type=="string" and (length>0))
		' >/dev/null 2>&1; then
			echo "journal: TAMPER/PARTIAL at line $_jv_n — missing/ill-typed field or unknown phase." >&2
			return 4
		fi
		_jv_seq=$(printf '%s' "$_line" | jq -r '.seq')
		_jv_path=$(printf '%s' "$_line" | jq -r '.path')
		_jv_lprev=$(printf '%s' "$_line" | jq -r '.prev')
		_jv_hash=$(printf '%s' "$_line" | jq -r '.hash')
		# A file-scoped path must be project-relative (no absolute root, no '..').
		case "$_jv_path" in
			"" ) : ;;
			/*|..|../*|*/..|*/../*) echo "journal: TAMPER at line $_jv_n — unsafe path '$_jv_path'." >&2; return 4 ;;
		esac
		# Monotonic sequence.
		[ "$_jv_seq" = "$_jv_expect" ] || { echo "journal: TAMPER at line $_jv_n — seq=$_jv_seq, expected $_jv_expect." >&2; return 4; }
		# Chain linkage.
		[ "$_jv_lprev" = "$_jv_prev" ] || { echo "journal: TAMPER at line $_jv_n — prev linkage broken." >&2; return 4; }
		# Recompute the digest over the entry MINUS its hash (same canonical form used to write it).
		_jv_body=$(printf '%s' "$_line" | jq -c 'del(.hash)')
		_jv_calc=$(printf '%s' "$_jv_body" | _tx_hash 2>/dev/null || true)
		[ "$_jv_calc" = "$_jv_hash" ] || { echo "journal: TAMPER at line $_jv_n — hash mismatch (entry altered)." >&2; return 4; }
		_jv_prev="$_jv_hash"; _jv_expect=$((_jv_expect + 1))
	done < "$JOURNAL"
	echo "journal: OK — $_jv_n entr$( [ "$_jv_n" -eq 1 ] && echo y || echo ies ) verified (chain + integrity intact)."
	return 0
}

case "$MODE" in
	inspect)
		echo "Sentinel Shield — operation inspection"
		echo "Target: $TARGET"
		echo "------------------------------------------------------------"
		if [ -f "$LOCK" ]; then
			if _tx_lock_valid "$LOCK"; then
				echo "operation-lock: PRESENT (schema-valid)"
				echo "  operation:    $(jq -r '.operation' "$LOCK")"
				echo "  state:        $(jq -r '.state' "$LOCK")"
				echo "  started_at:   $(jq -r '.started_at' "$LOCK")"
				echo "  pid:          $(jq -r '.pid' "$LOCK")"
				echo "  snapshot_dir: $(jq -r '.snapshot_dir' "$LOCK")"
				echo "  => an operation was interrupted; run: sh scripts/recover-operation.sh --target '$TARGET' --resume-rollback"
			else
				echo "operation-lock: PRESENT but NOT schema-valid (tampered/corrupt) — recovery will fail closed."
			fi
		else
			echo "operation-lock: none (no interrupted operation)."
		fi
		echo "------------------------------------------------------------"
		journal_verify || exit 4
		exit 0
		;;
	resume-rollback)
		# Delegate to the shared, fail-closed recovery contract (exits 0 on clean recovery, 4 otherwise).
		tx_recover
		;;
esac
