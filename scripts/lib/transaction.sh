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
	# Durable append: build the FULL line first, append it in a single write, then flush the
	# file + its parent directory to stable storage where a flush primitive is available. A
	# torn (partially-written) trailing line from a crash is a recognised recovery artifact —
	# tx_journal_verify tolerates a single torn TAIL line but rejects any earlier corruption.
	_tj_line=$(printf '%s' "$_tj_body" | jq -c --arg h "$_tj_hash" '. + {hash:$h}' 2>/dev/null || printf '')
	if [ -n "$_tj_line" ]; then
		# Heal a torn prior tail BEFORE appending: if the file does not end in a newline
		# (crash mid-write), this append would concatenate onto that tail, turning a
		# tolerated trailing artifact into prefix corruption that blocks recovery.
		if [ -s "$_tj_file" ] && [ -n "$(tail -c1 "$_tj_file" 2>/dev/null)" ]; then
			printf '\n' >> "$_tj_file" 2>/dev/null || true
		fi
		printf '%s\n' "$_tj_line" >> "$_tj_file" 2>/dev/null \
			|| log_warn "journal: could not append a '$_tj_phase' entry to $_tj_file"
		_tx_sync
	else
		log_warn "journal: could not finalise a '$_tj_phase' entry"
	fi
	return 0
}

# --- durability primitives ---------------------------------------------------
# These underpin the production transaction contract: atomic mutual-exclusion lock
# acquisition (a lock that CANNOT be won by two processes at once), a PID-independent
# ownership TOKEN, process-start identity to defeat PID reuse, host + engine-version
# metadata, an explicit state machine, and best-effort durable flushing. Everything is
# POSIX sh and degrades safely (never falsely reports durability) where a primitive is
# unavailable.

# _tx_rm <path> — best-effort recursive remove that ALWAYS succeeds (return 0), so a
# cleanup step can never abort a caller running under `set -e`. Not a gate.
_tx_rm() { [ -n "${1:-}" ] && rm -rf -- "$1" 2>/dev/null; return 0; }

# _tx_sync — flush buffered writes to stable storage where a flush primitive exists.
# `sync` has no bounded-failure mode we can act on, so this is best-effort (return 0);
# its ABSENCE is recorded honestly by callers rather than pretended-away.
_tx_sync() { command -v sync >/dev/null 2>&1 && sync 2>/dev/null; return 0; }

# _tx_lockdir — the atomic mutual-exclusion directory for this target. A single `mkdir`
# of this path is the ONLY thing that grants lock ownership (see tx_begin).
_tx_lockdir() { printf '%s' "${SS_DIR:-}/operation-lock.d"; }

# _tx_engine_version — the engine version stamped into a lock so a lock written by a
# different engine build is auditable. Never fails.
_tx_engine_version() { printf '%s' "${SENTINEL_SHIELD_VERSION:-${TX_ENGINE_VERSION:-unknown}}"; }

# _tx_hostname — this host's name (so a lock is never mistaken for a live process on a
# DIFFERENT machine that happens to share a PID number). Falls back to "unknown".
_tx_hostname() {
	_txh=$(uname -n 2>/dev/null || printf '')
	[ -n "$_txh" ] || _txh=$(hostname 2>/dev/null || printf '')
	[ -n "$_txh" ] || _txh="unknown"
	printf '%s' "$_txh"; unset _txh
}

# _tx_host_id — a stable machine identifier where the OS exposes one (Linux machine-id),
# else the hostname. Distinguishes two hosts that share a hostname.
_tx_host_id() {
	_txi=""
	[ -r /etc/machine-id ] && _txi=$(cat /etc/machine-id 2>/dev/null || printf '')
	[ -n "$_txi" ] || { [ -r /var/lib/dbus/machine-id ] && _txi=$(cat /var/lib/dbus/machine-id 2>/dev/null || printf ''); }
	[ -n "$_txi" ] || _txi=$(_tx_hostname)
	printf '%s' "$_txi"; unset _txi
}

# _tx_gen_token — a random ownership token INDEPENDENT of the PID. A raw PID can be reused
# by an unrelated process; a fresh per-acquisition token cannot, so it uniquely identifies
# THIS operation's ownership of the lock. Prefers /dev/urandom; falls back to a digest of
# high-entropy-ish process state (still unique per acquisition in practice).
_tx_gen_token() {
	_txt=""
	if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
		_txt=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
	fi
	if [ -z "$_txt" ]; then
		# POSIX fallback (no /dev/urandom): a digest of per-acquisition-unique process state.
		_txt=$(printf '%s-%s-%s-%s' "$$" "$(date +%s 2>/dev/null || echo 0)" "$(date +%N 2>/dev/null || echo 0)" "$(_tx_hostname)" | _tx_hash 2>/dev/null || printf '')
	fi
	[ -n "$_txt" ] || _txt="notoken-$$"
	printf '%s' "$_txt"; unset _txt
}

# _tx_pid_start <pid> — a process-START identity that changes when a PID is reused, so a
# recycled PID owned by an unrelated process is NOT mistaken for the original lock owner.
# Linux: field 22 (starttime) of /proc/<pid>/stat. BSD/macOS: `ps -o lstart=`. Prints ""
# where neither is available (the caller then degrades to PID-liveness alone, documented).
_tx_pid_start() {
	_txp="$1"; _txs=""
	case "$_txp" in ''|*[!0-9]*) printf ''; unset _txp _txs; return 0 ;; esac
	if [ -r "/proc/$_txp/stat" ]; then
		# Strip the leading "pid (comm) " (comm may contain spaces/parens); starttime is then
		# the 20th remaining field (overall field 22).
		_txs=$(sed -e 's/^[0-9][0-9]* (.*) //' "/proc/$_txp/stat" 2>/dev/null | awk '{print $20}' 2>/dev/null || printf '')
	elif command -v ps >/dev/null 2>&1; then
		_txs=$(ps -o lstart= -p "$_txp" 2>/dev/null | tr -s ' ' ' ' | sed -e 's/^ *//' -e 's/ *$//' || printf '')
	fi
	printf '%s' "$_txs"; unset _txp _txs
}

# _tx_pid_alive <pid> — 0 iff a process with that PID currently exists (signal 0 probe).
_tx_pid_alive() {
	case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$1" 2>/dev/null
}

# _tx_owner_classify — classify the CURRENT lock's owner from its recorded metadata:
#   none       no lock present
#   completed  the owner recorded a durable 'completed' state (finalise, do not roll back)
#   foreign    the lock belongs to a DIFFERENT host — liveness cannot be assessed here
#   live       same host, PID alive, and (where recorded) process-start identity MATCHES
#   stale      any other case (dead PID, reused PID, or a legacy lock with no ownership
#              metadata) — an interrupted operation that recovery may roll back
# Prints exactly one token. Read-only.
_tx_owner_classify() {
	[ -s "${LOCK:-}" ] || { printf 'none'; return 0; }
	_txc_state=$(jq -r '.state // ""' "$LOCK" 2>/dev/null || printf '')
	[ "$_txc_state" = "completed" ] && { printf 'completed'; unset _txc_state; return 0; }
	_txc_host=$(jq -r '.hostname // ""' "$LOCK" 2>/dev/null || printf '')
	_txc_hostid=$(jq -r '.host_id // ""' "$LOCK" 2>/dev/null || printf '')
	_txc_pid=$(jq -r '.pid // ""' "$LOCK" 2>/dev/null || printf '')
	_txc_pidstart=$(jq -r '.pid_start // ""' "$LOCK" 2>/dev/null || printf '')
	# A lock with NO ownership metadata predates durable ownership (or was hand-seeded): it
	# cannot be a live process of THIS engine, so treat it as an interrupted, recoverable run.
	if [ -z "$_txc_host" ] && [ -z "$_txc_pidstart" ]; then
		printf 'stale'; unset _txc_state _txc_host _txc_hostid _txc_pid _txc_pidstart; return 0
	fi
	_txc_ch=$(_tx_hostname); _txc_chi=$(_tx_host_id)
	if { [ -n "$_txc_host" ] && [ "$_txc_host" != "$_txc_ch" ]; } \
		|| { [ -n "$_txc_hostid" ] && [ "$_txc_hostid" != "$_txc_chi" ]; }; then
		printf 'foreign'; unset _txc_state _txc_host _txc_hostid _txc_pid _txc_pidstart _txc_ch _txc_chi; return 0
	fi
	if _tx_pid_alive "$_txc_pid"; then
		if [ -n "$_txc_pidstart" ]; then
			_txc_now=$(_tx_pid_start "$_txc_pid")
			if [ -n "$_txc_now" ] && [ "$_txc_now" = "$_txc_pidstart" ]; then
				printf 'live'
			else
				# PID is alive but its start identity differs -> the PID was RECYCLED.
				printf 'stale'
			fi
			unset _txc_now
		else
			printf 'live'
		fi
	else
		printf 'stale'
	fi
	unset _txc_state _txc_host _txc_hostid _txc_pid _txc_pidstart _txc_ch _txc_chi
	return 0
}

# --- explicit transaction state machine --------------------------------------
# States: initializing active validating committing rolling-back rollback-incomplete
# completed. _tx_state_transition_ok rejects every transition NOT on this list, so a
# corrupt/tampered lock claiming an impossible jump (e.g. completed -> active) is refused.
_tx_state_transition_ok() {
	case "$1|$2" in
		"|active"|"|initializing"|"initializing|active"|"initializing|rolling-back") return 0 ;;
		"active|validating"|"active|committing"|"active|rolling-back"|"active|completed") return 0 ;;
		"validating|committing"|"validating|rolling-back") return 0 ;;
		"committing|completed"|"committing|rolling-back") return 0 ;;
		"rolling-back|completed"|"rolling-back|rollback-incomplete") return 0 ;;
		"rollback-incomplete|rolling-back") return 0 ;;
		*) return 1 ;;
	esac
}

# _tx_current_state — the lock's recorded state, or "" when no lock is present.
_tx_current_state() {
	[ -s "${LOCK:-}" ] || { printf ''; return 0; }
	jq -r '.state // ""' "$LOCK" 2>/dev/null || printf ''
}

# _tx_write_lock <state> — write a COMPLETE, durable operation-lock marker (all ownership
# metadata) atomically: serialise to a temp file, rename it over $LOCK (same-dir atomic
# replace), then flush. Returns non-zero (writing nothing partial) on any failure.
_tx_write_lock() {
	_wl_state="$1"; _wl_tmp="$LOCK.tmp.$$"
	if jq -n --arg op "${TX_OP:-unknown}" --arg tgt "$TARGET" --arg at "$(timestamp_utc)" \
		--argjson pid "$$" --arg snap "$TX_SNAP" --arg state "$_wl_state" \
		--arg token "${TX_TOKEN:-}" --arg host "$(_tx_hostname)" --arg hostid "$(_tx_host_id)" \
		--arg pidstart "$(_tx_pid_start "$$")" --arg ver "$(_tx_engine_version)" \
		--arg ld "$(_tx_lockdir)" '{
			schema_version:"1", operation:$op, target:$tgt, started_at:$at, pid:$pid,
			snapshot_dir:$snap, state:$state, token:$token, hostname:$host, host_id:$hostid,
			pid_start:$pidstart, engine_version:$ver, lock_dir:$ld
		}' > "$_wl_tmp" 2>/dev/null; then
		if mv -- "$_wl_tmp" "$LOCK" 2>/dev/null; then
			_tx_sync; unset _wl_state _wl_tmp; return 0
		fi
	fi
	_tx_rm "$_wl_tmp"; unset _wl_state _wl_tmp; return 1
}

# _tx_set_state <to> — validated, DURABLE state transition. Reads the current on-disk state,
# rejects an impossible transition (fail closed), then rewrites the lock preserving every
# other field, atomically + flushed. Returns non-zero on rejection or any write failure.
_tx_set_state() {
	_st_to="$1"; _st_from=$(_tx_current_state)
	if ! _tx_state_transition_ok "$_st_from" "$_st_to"; then
		log_error "tx: refusing an impossible state transition '$_st_from' -> '$_st_to'"
		unset _st_to _st_from; return 1
	fi
	[ -s "$LOCK" ] || { log_error "tx: cannot set state '$_st_to' — lock is absent"; unset _st_to _st_from; return 1; }
	_st_tmp="$LOCK.tmp.$$"
	if jq --arg s "$_st_to" '.state = $s' "$LOCK" > "$_st_tmp" 2>/dev/null && mv -- "$_st_tmp" "$LOCK" 2>/dev/null; then
		_tx_sync; unset _st_to _st_from _st_tmp; return 0
	fi
	_tx_rm "$_st_tmp"; log_error "tx: could not durably record state '$_st_to'"; unset _st_to _st_from _st_tmp; return 1
}

# tx_release_lock — remove the lock marker AND the mutex directory, then flush. Called only
# once the terminal state has been durably recorded (or the lock is provably clearable).
tx_release_lock() {
	_tx_rm "$LOCK"
	_tx_rm "$(_tx_lockdir)"
	_tx_sync
	return 0
}

# tx_journal_verify [mode] — validate the append-only journal chain for $SS_DIR. mode:
#   strict  (default) reject ANY non-JSON line, including a torn trailing one (inspection).
#   lenient tolerate a SINGLE torn/partial TRAILING line (a crash-time append artifact) but
#           still reject any earlier corruption or a broken seq/prev/hash prefix (resume).
# Prints the first failure to stderr; echoes an OK summary to stdout. Returns 0 (consistent
# or absent) or 4 (tampered/partial). Read-only. This is the SINGLE journal-integrity
# implementation both recover-operation.sh --inspect and tx_recover call.
tx_journal_verify() {
	_jv_mode="${1:-strict}"
	_jv_file="${SS_DIR:-}/transaction-journal.jsonl"
	[ -f "$_jv_file" ] || { echo "journal: none present ($_jv_file absent)."; unset _jv_mode _jv_file; return 0; }
	_jv_prev=""; _jv_expect=1; _jv_n=0; _jv_more=1
	while [ "$_jv_more" = 1 ]; do
		if IFS= read -r _jv_line; then _jv_islast=0; else _jv_more=0; _jv_islast=1; [ -n "$_jv_line" ] || break; fi
		_jv_n=$((_jv_n + 1))
		if ! printf '%s' "$_jv_line" | jq -e . >/dev/null 2>&1; then
			if [ "$_jv_mode" = "lenient" ] && [ "$_jv_islast" = 1 ]; then
				# A torn TRAILING line is an expected crash artifact for resume — tolerate it.
				break
			fi
			echo "journal: TAMPER/PARTIAL at line $_jv_n — not valid JSON (truncated or corrupt entry)." >&2
			unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4
		fi
		if ! printf '%s' "$_jv_line" | jq -e '
			(.schema_version=="1") and (.seq|type=="number") and
			(.ts|type=="string" and (length>0)) and
			(.operation|type=="string") and (.pid|type=="number") and
			(.phase as $p | ["start","precondition","snapshot","mutation","validation","rollback-step","completion"]|index($p)!=null) and
			(.path|type=="string") and (.detail|type=="string") and
			(.prev|type=="string") and (.hash|type=="string" and (length>0))
		' >/dev/null 2>&1; then
			echo "journal: TAMPER/PARTIAL at line $_jv_n — missing/ill-typed field or unknown phase." >&2
			unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4
		fi
		_jv_seq=$(printf '%s' "$_jv_line" | jq -r '.seq')
		_jv_path=$(printf '%s' "$_jv_line" | jq -r '.path')
		_jv_lprev=$(printf '%s' "$_jv_line" | jq -r '.prev')
		_jv_hash=$(printf '%s' "$_jv_line" | jq -r '.hash')
		case "$_jv_path" in
			"" ) : ;;
			/*|..|../*|*/..|*/../*) echo "journal: TAMPER at line $_jv_n — unsafe path '$_jv_path'." >&2
				unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4 ;;
		esac
		if [ "$_jv_seq" != "$_jv_expect" ]; then
			echo "journal: TAMPER at line $_jv_n — seq=$_jv_seq, expected $_jv_expect." >&2
			unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4
		fi
		if [ "$_jv_lprev" != "$_jv_prev" ]; then
			echo "journal: TAMPER at line $_jv_n — prev linkage broken." >&2
			unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4
		fi
		_jv_body=$(printf '%s' "$_jv_line" | jq -c 'del(.hash)')
		_jv_calc=$(printf '%s' "$_jv_body" | _tx_hash 2>/dev/null || printf '')
		if [ "$_jv_calc" != "$_jv_hash" ]; then
			echo "journal: TAMPER at line $_jv_n — hash mismatch (entry altered)." >&2
			unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast; return 4
		fi
		_jv_prev="$_jv_hash"; _jv_expect=$((_jv_expect + 1))
	done < "$_jv_file"
	echo "journal: OK — verified chain + integrity of the complete prefix."
	unset _jv_mode _jv_file _jv_prev _jv_expect _jv_n _jv_more _jv_line _jv_islast \
		_jv_seq _jv_path _jv_lprev _jv_hash _jv_body _jv_calc
	return 0
}

# tx_install_file <abs_src> <rel_target> — the DURABLE managed-file mutation primitive:
# snapshot the pre-write state, physically re-validate containment, write to a same-dir
# in-flight temp, flush it, atomically rename it into place, then VERIFY the on-disk bytes
# match the source (post-write digest validation) and flush again. An interrupted write can
# only ever leave the in-flight temp — never a half-written managed file. Fails closed
# (exit 4) on containment/write/verify failure so the caller's trap rolls back. Includes two
# clearly-marked, inert-by-default FAULT SEAMS used only by the durability test.
tx_install_file() {
	_if_src="$1"; _if_rel="$2"; _if_dst="$TARGET/$_if_rel"
	tx_snapshot "$_if_rel"
	_if_r=$(_tx_contained "$TARGET" "$_if_rel" "TARGET_SYMLINK_PARENT") || {
		log_error "tx_install_file: refusing an unsafe target '$_if_rel' ($_if_r)"
		tx_journal "mutation" "$_if_rel" "REJECTED ($_if_r): unsafe managed-file path"
		exit 4; }
	ensure_dir "$(dirname -- "$_if_dst")"
	_if_tmp="$(dirname -- "$_if_dst")/.ss-inflight.$$.$(basename -- "$_if_rel")"
	# FAULT SEAM (test-only, inert unless the env names this exact rel path): simulate an
	# interrupted-write / disk-full (ENOSPC) so the fail-closed path is deterministically
	# exercised — nothing is renamed into place.
	if [ -n "${SENTINEL_SHIELD_TX_SIMULATE_ENOSPC:-}" ] && [ "$_if_rel" = "$SENTINEL_SHIELD_TX_SIMULATE_ENOSPC" ]; then
		_tx_rm "$_if_tmp"
		log_error "tx_install_file: simulated no-space/interrupted write for '$_if_rel' — managed file left untouched"
		tx_journal "mutation" "$_if_rel" "REJECTED (ENOSPC): simulated interrupted write; no partial file"
		exit 4
	fi
	if ! cp "$_if_src" "$_if_tmp" 2>/dev/null; then
		_tx_rm "$_if_tmp"
		log_error "tx_install_file: could not stage '$_if_rel' (permission denied / no space) — managed file left untouched"
		tx_journal "mutation" "$_if_rel" "REJECTED: write failed; no partial file"
		exit 4
	fi
	_tx_sync
	if ! mv -- "$_if_tmp" "$_if_dst" 2>/dev/null; then
		_tx_rm "$_if_tmp"
		log_error "tx_install_file: atomic replace failed for '$_if_rel'"
		tx_journal "mutation" "$_if_rel" "REJECTED: atomic replace failed"
		exit 4
	fi
	# FAULT SEAM (test-only): corrupt the just-written file so post-write verification trips.
	if [ -n "${SENTINEL_SHIELD_TX_CORRUPT_AFTER_WRITE:-}" ] && [ "$_if_rel" = "$SENTINEL_SHIELD_TX_CORRUPT_AFTER_WRITE" ]; then
		printf 'CORRUPTED-BY-FAULT-INJECTION\n' >> "$_if_dst" 2>/dev/null
	fi
	# Post-write digest validation: the managed file on disk MUST byte-match its source.
	if ! cmp -s "$_if_src" "$_if_dst"; then
		log_error "tx_install_file: post-write verification FAILED for '$_if_rel' (on-disk bytes != source)"
		tx_journal "validation" "$_if_rel" "REJECTED: post-write content/digest mismatch"
		exit 4
	fi
	_tx_sync
	tx_journal "mutation" "$_if_rel" "atomically wrote + post-write-verified managed file"
	unset _if_src _if_rel _if_dst _if_r _if_tmp
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
	# PHYSICAL containment BEFORE copying a pre-write file, appending to touched/created, or
	# creating any destination parent dir. A symlinked parent inside $TARGET is fail-closed:
	# abort the live operation so the caller's cleanup trap rolls back (never write through it).
	_ts_reason=$(_tx_contained "$TARGET" "$1" "TARGET_SYMLINK_PARENT") || {
		log_error "tx: refusing to snapshot an unsafe path: $1 ($_ts_reason)"
		tx_journal "snapshot" "$1" "REJECTED ($_ts_reason): unsafe transaction path — aborting operation"
		exit 4
	}
	# _tx_contained has already rejected a symlinked final component, so an existing target here
	# is a real regular file/dir (a genuine pre-write state to preserve).
	if [ -e "$TARGET/$1" ]; then
		ensure_dir "$TX_SNAP/snap/$(dirname -- "$1")"
		# VERIFIED snapshot copy: the pre-write state must be captured completely before the
		# live file is ever touched. A failed copy, or a snapshot that does not byte-match the
		# source, is fail-closed (abort the operation so the caller's trap rolls back) — a
		# partial/mismatched snapshot could otherwise mean silent data loss on rollback.
		if ! cp -p "$TARGET/$1" "$TX_SNAP/snap/$1" 2>/dev/null; then
			log_error "tx: could not snapshot '$1' (pre-write copy failed) — aborting operation"
			tx_journal "snapshot" "$1" "REJECTED: pre-write snapshot copy failed"
			exit 4
		fi
		if ! cmp -s "$TARGET/$1" "$TX_SNAP/snap/$1"; then
			log_error "tx: snapshot of '$1' does not match the live file (copy corrupt) — aborting operation"
			tx_journal "snapshot" "$1" "REJECTED: snapshot copy verification (cmp) failed"
			exit 4
		fi
		tx_journal "snapshot" "$1" "modified: pre-write copy saved (verified)"
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

# --- PHYSICAL containment validation -----------------------------------------
# The lexical _tx_rel_safe above rejects absolute paths and '..' but CANNOT see a parent
# component that is a SYMLINK: `a/b/c` where $TARGET/a is a symlink to /tmp/outside is
# lexically clean yet physically escapes. _tx_contained walks the real filesystem to close
# that hole and is the single choke point every mutating transaction path passes through
# (snapshot, rollback, recovery). It NEVER follows a symlinked component and NEVER requires
# the final destination to exist (so a brand-new file is fine).
#
# Bounds on a (possibly tampered) manifest so a hostile file cannot blow up recovery.
: "${TX_MAX_PATH_LEN:=1024}"
: "${TX_MAX_ENTRIES:=10000}"

# _tx_contained <base> <relpath> <symlink-reason> — verify that <base>/<relpath> stays
# physically within <base>. On success returns 0 and prints nothing. On failure prints a
# STABLE reason to stdout and returns 1:
#   INVALID_TRANSACTION_PATH  empty / absolute / '..' traversal / control-char (NUL, NL, CR,
#                             TAB, …) / '.'-or-empty component / unresolvable <base>.
#   <symlink-reason>          a parent (or the final) component is a symlink OR the nearest
#                             existing parent physically resolves outside <base>
#                             (callers pass TARGET_SYMLINK_PARENT or SNAPSHOT_SYMLINK).
# Contract: (2) walk EVERY existing parent from <base>; (3) reject any symlinked component;
# (4) resolve the nearest existing parent with `cd -P`/`pwd -P`; (5) confirm it is <base> or
# below <base>/; (6) the final component need not exist.
_tx_contained() {
	_pc_base="$1"; _pc_rel="$2"; _pc_symreason="${3:-TARGET_SYMLINK_PARENT}"
	# (1) lexical gate (reuse _tx_rel_safe) + control-character rejection.
	_tx_rel_safe "$_pc_rel" || { printf '%s' "INVALID_TRANSACTION_PATH"; return 1; }
	case "$_pc_rel" in
		*[[:cntrl:]]*) printf '%s' "INVALID_TRANSACTION_PATH"; return 1 ;;
	esac
	# Canonicalise the base itself (it must exist and be a directory).
	_pc_basereal=$(CDPATH= cd -P -- "$_pc_base" 2>/dev/null && pwd -P) \
		|| { printf '%s' "INVALID_TRANSACTION_PATH"; return 1; }
	# (2)/(3) walk each component under the LITERAL base so a symlinked component is caught
	# as it would actually be traversed; track the deepest EXISTING directory.
	_pc_cur="$_pc_base"; _pc_deepest="$_pc_base"; _pc_rest="$_pc_rel"
	while [ -n "$_pc_rest" ]; do
		case "$_pc_rest" in
			*/*) _pc_comp=${_pc_rest%%/*}; _pc_rest=${_pc_rest#*/} ;;
			*)   _pc_comp=$_pc_rest; _pc_rest="" ;;
		esac
		case "$_pc_comp" in
			"" | . | ..) printf '%s' "INVALID_TRANSACTION_PATH"; return 1 ;;
		esac
		_pc_cur="$_pc_cur/$_pc_comp"
		# A symlink at ANY component (broken or not) escapes containment — reject.
		if [ -L "$_pc_cur" ]; then printf '%s' "$_pc_symreason"; return 1; fi
		# First non-existent component: the remainder is new; the nearest existing parent
		# has been found. Stop descending.
		[ -e "$_pc_cur" ] || break
		[ -d "$_pc_cur" ] && _pc_deepest="$_pc_cur"
	done
	# (4)/(5) physically resolve the nearest existing parent and confirm containment.
	_pc_real=$(CDPATH= cd -P -- "$_pc_deepest" 2>/dev/null && pwd -P) \
		|| { printf '%s' "$_pc_symreason"; return 1; }
	[ "$_pc_real" = "$_pc_basereal" ] && return 0
	_pc_after=${_pc_real#"$_pc_basereal"/}
	[ "$_pc_after" != "$_pc_real" ] || { printf '%s' "$_pc_symreason"; return 1; }
	return 0
}

# _tx_manifest_check <snapshot-dir> — HARDEN the untrusted touched/created manifests before a
# single entry is executed. On the FIRST problem it sets _TX_MC_PATH + _TX_MC_REASON (a stable
# reason) and returns 1; returns 0 when both manifests are well-formed and mutually consistent.
# Enforces: one physically-contained relative path per line; a bounded line length + entry
# count; no duplicate line within a manifest; every 'created' path also present in 'touched';
# and NO 'created' path carrying a snapshot copy (created == no prior state — a snapshot for it
# means the entry is claimed BOTH newly-created and modified). Stable reasons:
#   INVALID_TRANSACTION_PATH, DUPLICATE_TRANSACTION_PATH, CONTRADICTORY_TRANSACTION_STATE,
#   plus TARGET_SYMLINK_PARENT from _tx_contained.
_tx_manifest_check() {
	_mc_snap="$1"; _TX_MC_PATH=""; _TX_MC_REASON=""
	_mc_touched="$_mc_snap/touched"; _mc_created="$_mc_snap/created"
	if [ ! -f "$_mc_touched" ]; then
		_TX_MC_PATH="$_mc_touched"; _TX_MC_REASON="INVALID_TRANSACTION_PATH"; return 1
	fi
	# Duplicate line within 'touched' (byte-identical dupes included — a well-formed manifest
	# is deduped at write time, so ANY repeat signals tampering).
	_mc_dup=$(grep -v '^$' "$_mc_touched" 2>/dev/null | sort | uniq -d | head -n 1)
	if [ -n "$_mc_dup" ]; then
		_TX_MC_PATH="$_mc_dup"; _TX_MC_REASON="DUPLICATE_TRANSACTION_PATH"; return 1
	fi
	# Per-line: bounded count + length; exactly one physically-contained relative path.
	_mc_n=0
	while IFS= read -r _mc_line || [ -n "$_mc_line" ]; do
		[ -n "$_mc_line" ] || continue
		_mc_n=$((_mc_n + 1))
		if [ "$_mc_n" -gt "$TX_MAX_ENTRIES" ] || [ "${#_mc_line}" -gt "$TX_MAX_PATH_LEN" ]; then
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="INVALID_TRANSACTION_PATH"; return 1
		fi
		_mc_r=$(_tx_contained "$TARGET" "$_mc_line" "TARGET_SYMLINK_PARENT") || {
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="$_mc_r"; return 1; }
	done < "$_mc_touched"
	# 'created' is optional; when present it must be a consistent subset of 'touched'.
	[ -f "$_mc_created" ] || return 0
	_mc_dup=$(grep -v '^$' "$_mc_created" 2>/dev/null | sort | uniq -d | head -n 1)
	if [ -n "$_mc_dup" ]; then
		_TX_MC_PATH="$_mc_dup"; _TX_MC_REASON="DUPLICATE_TRANSACTION_PATH"; return 1
	fi
	_mc_n=0
	while IFS= read -r _mc_line || [ -n "$_mc_line" ]; do
		[ -n "$_mc_line" ] || continue
		_mc_n=$((_mc_n + 1))
		if [ "$_mc_n" -gt "$TX_MAX_ENTRIES" ] || [ "${#_mc_line}" -gt "$TX_MAX_PATH_LEN" ]; then
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="INVALID_TRANSACTION_PATH"; return 1
		fi
		_mc_r=$(_tx_contained "$TARGET" "$_mc_line" "TARGET_SYMLINK_PARENT") || {
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="$_mc_r"; return 1; }
		# A 'created' path must be declared in 'touched' too …
		if ! grep -qxF "$_mc_line" "$_mc_touched" 2>/dev/null; then
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="CONTRADICTORY_TRANSACTION_STATE"; return 1
		fi
		# … and must NOT also carry a snapshot copy (that would claim it both created + modified).
		if [ -e "$_mc_snap/snap/$_mc_line" ] || [ -L "$_mc_snap/snap/$_mc_line" ]; then
			_TX_MC_PATH="$_mc_line"; _TX_MC_REASON="CONTRADICTORY_TRANSACTION_STATE"; return 1
		fi
	done < "$_mc_created"
	return 0
}

# _tx_guard_entry <relpath> <created?0|1> — physically validate ONE touched entry on both the
# target and (for a modified entry) the snapshot side, IMMEDIATELY before it is mutated, so a
# symlink planted between validation and use cannot be followed. Fails closed via
# _tx_recover_fail (retain lock+snapshot, exit 4) on any containment/shape violation.
_tx_guard_entry() {
	_ge_rel="$1"; _ge_created="$2"
	_ge_r=$(_tx_contained "$TARGET" "$_ge_rel" "TARGET_SYMLINK_PARENT") \
		|| _tx_recover_fail "$_ge_rel" "containment-target" "$_ge_r: target path escapes $TARGET via a symlinked parent (or is otherwise unsafe)"
	[ "$_ge_created" = "1" ] && return 0
	# Modified entry: its snapshot copy must be contained, exist, and be a REGULAR file that is
	# NOT a symlink (a malicious symlink inside the snapshot must never be followed).
	_ge_r=$(_tx_contained "$TX_SNAP/snap" "$_ge_rel" "SNAPSHOT_SYMLINK") \
		|| _tx_recover_fail "$_ge_rel" "containment-snapshot" "$_ge_r: snapshot path escapes the snapshot dir via a symlinked parent"
	[ -e "$TX_SNAP/snap/$_ge_rel" ] \
		|| _tx_recover_fail "$_ge_rel" "missing-expected-snapshot" "no snapshot for a modified file (snapshot corrupt/incomplete) — refusing to touch the live file"
	{ [ -f "$TX_SNAP/snap/$_ge_rel" ] && [ ! -L "$TX_SNAP/snap/$_ge_rel" ]; } \
		|| _tx_recover_fail "$_ge_rel" "snapshot-not-regular" "SNAPSHOT_SYMLINK: snapshot entry is not a regular file (symlink/dir/device) — refusing to follow it"
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
		(.state as $s | ["initializing","active","validating","committing","rolling-back","rollback-incomplete","completed"] | index($s) != null)
	' "$1" >/dev/null 2>&1
}

# tx_rollback — restore every snapshotted file (or remove files that were newly created).
# Every path is PHYSICALLY re-validated (target + snapshot side) before it is touched; an
# entry that would escape $TARGET via a symlinked parent is NEVER skipped-and-continued —
# it fails closed through the shared recovery path (retain lock+snapshot, exit 4).
tx_rollback() {
	[ -n "$TX_SNAP" ] && [ -f "$TX_SNAP/touched" ] || return 0
	_tx_snap_safe "$TX_SNAP" || { log_warn "tx: refusing rollback from an unexpected snapshot dir: $TX_SNAP"; return 0; }
	_snap="$TX_SNAP"
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		_rb_r=$(_tx_contained "$TARGET" "$_rel" "TARGET_SYMLINK_PARENT") \
			|| _tx_recover_fail "$_rel" "rollback-containment" "$_rb_r: refusing to roll back a path that escapes $TARGET via a symlinked parent"
		if [ -e "$TX_SNAP/snap/$_rel" ] || [ -L "$TX_SNAP/snap/$_rel" ]; then
			_rb_r=$(_tx_contained "$TX_SNAP/snap" "$_rel" "SNAPSHOT_SYMLINK") \
				|| _tx_recover_fail "$_rel" "rollback-snapshot" "$_rb_r: snapshot entry escapes the snapshot dir via a symlinked parent"
			{ [ -f "$TX_SNAP/snap/$_rel" ] && [ ! -L "$TX_SNAP/snap/$_rel" ]; } \
				|| _tx_recover_fail "$_rel" "rollback-snapshot" "SNAPSHOT_SYMLINK: snapshot entry is not a regular file — refusing to follow it"
			ensure_dir "$TARGET/$(dirname -- "$_rel")" || _tx_recover_fail "$_rel" "restore-mkdir" "could not recreate the parent directory for the restored file"
			cp -p "$TX_SNAP/snap/$_rel" "$TARGET/$_rel" || _tx_recover_fail "$_rel" "restore-copy" "could not restore the prior file (read-only target or permission denied)"
			tx_journal "rollback-step" "$_rel" "restored pre-write copy"
		else
			rm -f "$TARGET/$_rel" || _tx_recover_fail "$_rel" "remove-created" "could not remove the newly-created file (read-only directory?)"
			tx_journal "rollback-step" "$_rel" "removed newly-created file"
		fi
	done < "$TX_SNAP/touched"
}

# tx_begin — open the transaction: snapshot dir + ATOMIC lock acquisition. Ownership is
# granted ONLY by a successful `mkdir` of the mutex directory (an atomic test-and-set on
# every POSIX filesystem), so two simultaneous operations on one project can never both
# proceed — the loser gets a non-zero mkdir and fails closed. The winner then writes a
# durable lock marker carrying a PID-independent token, process-start identity, host, and
# engine version.
tx_begin() {
	ensure_dir "$SS_DIR"
	TX_SNAP="$SS_DIR/.txn-$$"
	# A prior process with THIS pid may have left a stale snapshot dir behind (PID reuse).
	# Truncating only 'touched' would leave stale 'created' entries and snap/ copies that later
	# make _tx_manifest_check reject recovery (created not a subset of touched) — remove any
	# leftover dir wholesale so the transaction starts from clean state.
	_tx_rm "$TX_SNAP"
	ensure_dir "$TX_SNAP"
	: > "$TX_SNAP/touched"
	_tx_ld=$(_tx_lockdir)
	if ! mkdir "$_tx_ld" 2>/dev/null; then
		# The mutex is held: a sibling process owns it right now, or a crash left it behind.
		# NEVER write through a mutex we do not own — fail closed.
		_tx_rm "$TX_SNAP"; TX_SNAP=""; TX_ACTIVE=0
		_tx_cls=$(_tx_owner_classify)
		echo "error: could not acquire the Sentinel Shield operation lock (mutex held: $_tx_ld)." >&2
		if [ "$_tx_cls" = "live" ]; then
			echo "       another '$TX_OP' operation is currently running on this target — refusing to run concurrently." >&2
			echo "         sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover  (only if it is truly dead)" >&2
		else
			echo "       a previous operation did not release the lock; recover it with:" >&2
			echo "         sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover" >&2
		fi
		unset _tx_ld _tx_cls
		exit 4
	fi
	# We hold the mutex. Mint a fresh ownership token (PID-independent) and record durable
	# ownership metadata BEFORE any mutation runs under the lock's protection.
	TX_TOKEN=$(_tx_gen_token)
	if ! _tx_write_lock "active"; then
		_tx_rm "$TX_SNAP"; TX_SNAP=""; _tx_rm "$_tx_ld"; TX_ACTIVE=0
		log_error "tx: could not write the operation lock — refusing to proceed"
		unset _tx_ld
		exit 4
	fi
	TX_ACTIVE=1
	unset _tx_ld
	tx_journal "start" "" "operation=$TX_OP target=$TARGET"
	tx_journal "precondition" "" "acquired mutex + durable operation-lock (token owner); snapshot dir ready; state=active"
}

# tx_commit — close the transaction successfully. Durable state machine:
# active -> committing -> completed, each state fsync'd, and the lock is removed ONLY AFTER
# the terminal 'completed' state is durably recorded. A crash mid-finalise therefore leaves a
# 'completed' marker that the next run/recovery treats as already-finished (idempotent),
# never as an interrupted operation to roll back.
tx_commit() {
	TX_ACTIVE=0
	_tx_set_state "committing" || log_warn "tx: could not record 'committing' state (continuing to finalise)"
	tx_journal "completion" "" "committed: operation succeeded; finalising"
	_tx_set_state "completed" || log_warn "tx: could not record 'completed' state before release"
	tx_release_lock
	[ -n "$TX_SNAP" ] && _tx_rm "$TX_SNAP"
	TX_SNAP=""
}

# tx_detect_stale — refuse to mutate when a prior operation-lock (or a torn mutex) is present.
# Distinguishes a still-LIVE operation from an INTERRUPTED one, and auto-finalises a lock that
# reached the durable 'completed' state but whose owner was killed before releasing it.
tx_detect_stale() {
	if [ ! -f "$LOCK" ]; then
		# A mutex dir with NO marker is a torn acquisition (crash between mkdir and the lock
		# write). Fail closed rather than silently reclaim it.
		if [ -d "$(_tx_lockdir)" ]; then
			echo "error: a partially-acquired Sentinel Shield lock was found (mutex present, no marker)." >&2
			echo "       clear it with: sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover" >&2
			exit 4
		fi
		return 0
	fi
	_ds_cls=$(_tx_owner_classify)
	if [ "$_ds_cls" = "completed" ]; then
		# A prior run committed durably but was killed before removing the marker — finalise it.
		tx_journal "completion" "" "cleared a completed-but-unreleased lock before a new operation"
		tx_release_lock
		unset _ds_cls
		return 0
	fi
	_op=$(jq -r '.operation // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	_at=$(jq -r '.started_at // "unknown"' "$LOCK" 2>/dev/null || echo unknown)
	if [ "$_ds_cls" = "live" ]; then
		_lp=$(jq -r '.pid // "?"' "$LOCK" 2>/dev/null || echo '?')
		echo "error: another Sentinel Shield '$_op' operation is currently running (pid $_lp) on this target." >&2
		echo "       refusing to run concurrently; wait for it to finish. If it is truly dead, recover with:" >&2
		echo "         sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover" >&2
		unset _ds_cls _op _at _lp
		exit 4
	fi
	echo "error: an interrupted Sentinel Shield operation was detected." >&2
	echo "       a previous '$_op' (started $_at) did not finish; $LOCK is present." >&2
	echo "       recover (roll back the partial run) with:" >&2
	echo "         sh ${TX_SELF:-scripts/install-baseline.sh} --target '$TARGET' --recover" >&2
	unset _ds_cls _op _at
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
	# (5) HARDEN the manifests up front: one contained relative path per line, bounded
	# count/length, no duplicates, no created-vs-modified contradiction (fails closed).
	_tx_manifest_check "$TX_SNAP" \
		|| _tx_recover_fail "$_TX_MC_PATH" "manifest-validation" "manifest rejected ($_TX_MC_REASON)"
	# (6)/(7) restore MODIFIED files from their snapshot; remove NEWLY-CREATED files. Every
	# path is PHYSICALLY re-validated (target + snapshot side) immediately before it is touched.
	while IFS= read -r _rel; do
		[ -n "$_rel" ] || continue
		if grep -qxF "$_rel" "$_created" 2>/dev/null; then
			_tx_guard_entry "$_rel" 1
			rm -f "$TARGET/$_rel" 2>/dev/null || _tx_recover_fail "$_rel" "remove-created" "could not remove the newly-created file (read-only directory?)"
			[ -e "$TARGET/$_rel" ] && _tx_recover_fail "$_rel" "remove-created" "newly-created file is still present after removal"
			tx_journal "rollback-step" "$_rel" "removed newly-created file"
		else
			# A modified file's pre-write snapshot MUST exist, be physically contained, and be a
			# regular (non-symlink) file — refuse rather than follow a planted link or delete a
			# live file over a corrupt/incomplete snapshot.
			_tx_guard_entry "$_rel" 0
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
	if [ ! -f "$LOCK" ]; then
		# IDEMPOTENCE: a torn mutex with no marker is safe to clear; otherwise nothing to do.
		if [ -d "$(_tx_lockdir)" ]; then
			_tx_rm "$(_tx_lockdir)"
			echo "Cleared a partially-acquired lock (mutex only, no marker); nothing to roll back."
			exit 0
		fi
		echo "No interrupted operation found ($LOCK absent); nothing to recover."; exit 0
	fi
	# (1) lock parses & is schema-valid (CONTRACT(2)).
	_tx_lock_valid "$LOCK" || _tx_recover_fail "$LOCK" "lock-schema-validation" "operation-lock is missing fields, mistyped, or not schema-conformant"
	# COMPLETE-FORWARD (never roll back a success): a lock that durably reached 'committing' or
	# 'completed' means every managed write AND its post-write validation already succeeded and
	# were fsync'd — only lock finalisation remained when the owner died. Rolling those writes
	# back would UNDO a successful operation, so recovery finalises forward: clear the snapshot +
	# lock and exit 0. This also makes repeated recovery idempotent (a completed/committing
	# transaction is never rolled back a second time).
	_rc_state=$(jq -r '.state // ""' "$LOCK" 2>/dev/null || echo "")
	if [ "$_rc_state" = "completed" ] || [ "$_rc_state" = "committing" ]; then
		_rc_snap=$(jq -r '.snapshot_dir // ""' "$LOCK" 2>/dev/null || printf '')
		_tx_snap_safe "$_rc_snap" && _tx_rm "$_rc_snap"
		tx_journal "completion" "" "recovery: finalised an already-committed transaction (state=$_rc_state); no rollback needed"
		tx_release_lock
		echo "Recovery: the interrupted operation had already committed (state=$_rc_state); cleared $LOCK (no rollback)."
		unset _rc_state _rc_snap
		exit 0
	fi
	unset _rc_state
	_snap=$(jq -r '.snapshot_dir' "$LOCK" 2>/dev/null || true)
	_ltarget=$(jq -r '.target' "$LOCK" 2>/dev/null || true)
	# (2) lock.target must equal the current canonical target.
	[ "$_ltarget" = "$TARGET" ] || _tx_recover_fail "$LOCK" "target-mismatch" "lock target '$_ltarget' != current canonical target '$TARGET'"
	# (3) re-validate snapshot_dir containment (UNTRUSTED) and existence — LEXICALLY, then
	# PHYSICALLY (the .txn-* dir must not itself be a symlink pointing outside $SS_DIR).
	_tx_snap_safe "$_snap" || _tx_recover_fail "$_snap" "snapshot-dir-unsafe" "snapshot_dir is not canonically contained in $SS_DIR/.txn-*"
	[ -d "$_snap" ] || _tx_recover_fail "$_snap" "snapshot-dir-missing" "snapshot_dir does not exist"
	_sd_r=$(_tx_contained "$SS_DIR" "$(basename -- "$_snap")" "SNAPSHOT_SYMLINK") \
		|| _tx_recover_fail "$_snap" "snapshot-dir-symlink" "$_sd_r: snapshot_dir resolves outside $SS_DIR (symlinked .txn dir)"
	# (4) the touched manifest must exist & be readable.
	[ -f "$_snap/touched" ] && [ -r "$_snap/touched" ] || _tx_recover_fail "$_snap/touched" "touched-manifest-missing" "the touched manifest is absent or unreadable"
	# (4b) VERIFY the journal chain before resuming. A prefix-tampered journal is a corruption
	# signal and fails closed; a single torn TRAILING line (the crash's own interrupted append)
	# is tolerated in lenient mode so a genuine crash is still recoverable.
	tx_journal_verify lenient >/dev/null 2>&1 || _tx_recover_fail "$SS_DIR/transaction-journal.jsonl" "journal-verification" "the transaction journal chain is tampered/inconsistent (prefix corruption) — refusing to resume"
	# Mark the durable transition into rolling-back BEFORE we touch anything, then transition to
	# the terminal state only after post-verify. A best-effort set (the lock may be a legacy or
	# hand-seeded 'active' lock with no prior state machine) never blocks a legitimate rollback.
	if _tx_set_state "rolling-back" >/dev/null 2>&1; then :; else
		log_warn "tx: could not record 'rolling-back' state (continuing recovery)"
	fi
	# (5)-(9) validated rollback + post-verify (exits 4 on the first failure).
	TX_SNAP="$_snap"
	tx_journal "rollback-step" "" "resume-rollback: recovering interrupted '$_ltarget' operation"
	_tx_recover_apply || _tx_recover_fail "$_snap" "rollback" "rollback did not complete"
	# All steps held: it is now safe to clear recovery state (lock + mutex + snapshot).
	tx_journal "completion" "" "recovery complete: interrupted operation rolled back; lock cleared"
	_tx_rm "$_snap"
	tx_release_lock
	echo "Recovery complete: rolled back the interrupted operation and cleared $LOCK."
	exit 0
}
