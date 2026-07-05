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
# Opt-in operational-event emission (off by default). Sourced defensively so a minimal copied tree
# still works; every oe_emit is a no-op unless SENTINEL_SHIELD_EVENTS=1 + a sink are configured.
if [ -f "$SCRIPT_DIR/lib/operational-events.sh" ]; then
	# shellcheck source=scripts/lib/operational-events.sh
	. "$SCRIPT_DIR/lib/operational-events.sh"
fi

TARGET=""; MODE="inspect"; FORMAT="human"

usage() {
	cat <<'EOF'
Usage: recover-operation.sh --target <dir> [--mode inspect|resume-rollback] [--format human|json]
  --target <dir>       Consuming project directory (required; must hold .sentinel-shield/).
  --mode <mode>        inspect (default) | resume-rollback.
  --inspect            Alias for --mode inspect (read-only report + journal integrity check).
  --resume-rollback    Alias for --mode resume-rollback (fail-closed tx_recover).
  --format <fmt>       inspect output: human (default) | json (machine-readable contract:
                       schemas/recovery-inspection.schema.json).
  -h, --help           Show help.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--inspect) MODE="inspect"; shift ;;
		--resume-rollback) MODE="resume-rollback"; shift ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) log_error "unknown argument '$1'"; usage; exit 2 ;;
	esac
done

case "$FORMAT" in human|json) ;; *) log_error "invalid --format '$FORMAT' (human|json)"; exit 2 ;; esac

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

# Opt-in operational events: mark the start of recovery and, via a fail-safe EXIT trap, emit a
# terminal event whose status is derived from the real exit code (0 consistent / 4 could-not-clear).
# The trap CAPTURES $? first and RETURNS it unchanged, so it can never alter the recovery exit
# contract; emission itself is best-effort and never aborts recovery.
_oe_recover_start_ms=""
if command -v oe_now_ms >/dev/null 2>&1; then _oe_recover_start_ms=$(oe_now_ms); fi
if command -v oe_emit >/dev/null 2>&1; then
	oe_emit --command recovery --phase start --event-type start --status in-progress \
		--reason-code "recovery_${MODE}" --component recovery --target "$TARGET" \
		${_oe_recover_start_ms:+--start-ms "$_oe_recover_start_ms"} || :
fi
_oe_recover_on_exit() {
	_oe_rc=$?
	if command -v oe_emit >/dev/null 2>&1; then
		_oe_st=success; _oe_et=complete; _oe_sev=info; _oe_rs=recovery_consistent
		case "$_oe_rc" in
			0) : ;;
			4) _oe_st=failure; _oe_et=error; _oe_sev=error; _oe_rs=recovery_could_not_clear ;;
			*) _oe_st=unknown; _oe_et=error; _oe_sev=warning; _oe_rs=recovery_aborted ;;
		esac
		oe_emit --command recovery --phase complete --event-type "$_oe_et" --severity "$_oe_sev" \
			--status "$_oe_st" --reason-code "$_oe_rs" --component recovery --target "$TARGET" \
			${_oe_recover_start_ms:+--start-ms "$_oe_recover_start_ms"} >/dev/null 2>&1 || :
	fi
	return "$_oe_rc"
}
trap _oe_recover_on_exit EXIT

# journal_verify — validate the append-only journal chain. Delegates to the SINGLE
# implementation in scripts/lib/transaction.sh (tx_journal_verify) so recovery duplicates no
# tx_* logic. Strict mode: reject a non-JSON/partial line, a missing/ill-typed field, an unsafe
# path, a broken seq/prev linkage, and a recomputed-hash mismatch. Returns 0 (consistent/absent)
# or 4 (tampered/partial).
journal_verify() { tx_journal_verify strict; }

# emit_inspection_json — the machine-readable inspection CONTRACT
# (schemas/recovery-inspection.schema.json). Exposes: state, lock_owner{pid,token,hostname},
# journal_valid, safe_to_resume, safe_to_rollback, required_manual_actions[]. Read-only; reuses
# the same library validators (_tx_lock_valid, _tx_snap_safe, _tx_contained, tx_journal_verify)
# the real recovery path uses, so the report can never disagree with what recovery would do.
emit_inspection_json() {
	_ij_state="null"; _ij_owner="null"; _ij_jvalid=false; _ij_resume=false; _ij_rollback=false
	_ij_manual=""
	# Journal integrity (strict = the read-only inspection standard).
	if tx_journal_verify strict >/dev/null 2>&1; then _ij_jvalid=true; else
		_ij_jvalid=false
		_ij_manual="${_ij_manual}journal chain is tampered or has a partial entry — inspect and repair before resuming
"
	fi
	if [ -f "$LOCK" ]; then
		if _tx_lock_valid "$LOCK"; then
			_ij_st=$(jq -r '.state // ""' "$LOCK" 2>/dev/null || echo "")
			_ij_state=$(printf '%s' "$_ij_st" | jq -R .)
			_ij_pid=$(jq -r '.pid // ""' "$LOCK" 2>/dev/null || echo "")
			_ij_tok=$(jq -r '.token // ""' "$LOCK" 2>/dev/null || echo "")
			_ij_host=$(jq -r '.hostname // ""' "$LOCK" 2>/dev/null || echo "")
			_ij_owner=$(jq -n --argjson pid "$( [ -n "$_ij_pid" ] && printf '%s' "$_ij_pid" || printf 'null' )" \
				--arg token "$_ij_tok" --arg hostname "$_ij_host" \
				'{pid:$pid, token:(if $token=="" then null else $token end), hostname:(if $hostname=="" then null else $hostname end)}')
			if [ "$_ij_st" = "completed" ]; then
				# Already committed; resume-rollback will simply clear it (safe), nothing to roll back.
				_ij_rollback=false; _ij_resume=true
				_ij_manual="${_ij_manual}operation already committed (state=completed); run --resume-rollback to clear the stale marker
"
			else
				_ij_rollback=true
				_ij_lt=$(jq -r '.target // ""' "$LOCK" 2>/dev/null || echo "")
				if [ "$_ij_lt" != "$TARGET" ]; then
					_ij_rollback=false
					_ij_manual="${_ij_manual}lock target does not match the current canonical target — recovery must run against the recorded target
"
				fi
				_ij_snap=$(jq -r '.snapshot_dir // ""' "$LOCK" 2>/dev/null || echo "")
				if ! _tx_snap_safe "$_ij_snap" || [ ! -d "$_ij_snap" ]; then
					_ij_rollback=false
					_ij_manual="${_ij_manual}snapshot_dir is missing or not contained under .sentinel-shield/.txn-* — manual inspection required
"
				elif [ ! -f "$_ij_snap/touched" ]; then
					_ij_rollback=false
					_ij_manual="${_ij_manual}touched manifest is absent — the snapshot is incomplete; manual inspection required
"
				fi
				# Resume is safe only when a rollback is safe AND the journal is intact enough.
				if [ "$_ij_rollback" = true ] && tx_journal_verify lenient >/dev/null 2>&1; then
					_ij_resume=true
				else
					_ij_resume=false
				fi
			fi
		else
			_ij_manual="${_ij_manual}operation-lock is present but not schema-valid (tampered/corrupt) — recovery will fail closed
"
		fi
	fi
	_ij_manual_json=$(printf '%s' "$_ij_manual" | sed '/^$/d' | jq -R . | jq -s .)
	jq -n \
		--argjson state "$_ij_state" \
		--argjson lock_owner "$_ij_owner" \
		--argjson journal_valid "$_ij_jvalid" \
		--argjson safe_to_resume "$_ij_resume" \
		--argjson safe_to_rollback "$_ij_rollback" \
		--argjson required_manual_actions "$_ij_manual_json" \
		--arg target "$TARGET" '{
			schema: "recovery-inspection",
			target: $target,
			state: $state,
			lock_owner: $lock_owner,
			journal_valid: $journal_valid,
			safe_to_resume: $safe_to_resume,
			safe_to_rollback: $safe_to_rollback,
			required_manual_actions: $required_manual_actions
		}'
}

case "$MODE" in
	inspect)
		if [ "$FORMAT" = "json" ]; then
			# Machine-readable contract to stdout; exit 0 when the journal is consistent, 4 when
			# it is tampered/partial (same fail-closed exit as the human report).
			emit_inspection_json
			tx_journal_verify strict >/dev/null 2>&1 || exit 4
			exit 0
		fi
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
