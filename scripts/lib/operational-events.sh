#!/bin/sh
# Sentinel Shield — normalized operational-event model + OPT-IN JSONL emission (POSIX sh library).
#
# Source this file; do NOT execute it. It defines oe_* helper functions only and does not enable
# `set -eu` (the caller decides). POSIX sh only: no Bash arrays, no `local`, no `[[ ]]`, no process
# substitution.
#
# WHAT THIS PROVIDES
#   A SINGLE normalized operational-event object, emitted (opt-in) as one JSON object per line to a
#   JSONL sink, conforming to schemas/operational-event.schema.json. Every long-running or mutating
#   Sentinel Shield operation — acquisition, install, sync, migration, bootstrap, doctor, pipeline,
#   recovery, security scanning, evidence collection, artifact verification, release finalization,
#   and health — can emit a correlated stream of these so an operator (or an automated collector)
#   can reconstruct exactly what happened, in order, across a failed operation AND its recovery.
#
#   The event model carries: schema + schema version, command, phase, event type, severity, a stable
#   reason code, an ISO-8601 UTC timestamp, a best-effort (monotonic-where-available) elapsed
#   duration in milliseconds, a correlation ID (shared across an operation and its follow-ups), an
#   operation ID (unique per operation), a REDACTED, non-reversible target identity, a component,
#   a status, retryability, and a redacted next-action hint.
#
# OPT-IN CONTRACT (off by default; zero behavior change when disabled)
#   Emission happens ONLY when BOTH are set:
#     SENTINEL_SHIELD_EVENTS=1            (or true|yes|on)
#     SENTINEL_SHIELD_EVENTS_FILE=<path>  (the JSONL sink; appended, never truncated)
#   When either is unset, every oe_emit is a no-op returning 0. Like the transaction journal,
#   emission is a best-effort AUDIT trail: a failed WRITE degrades to a visible warning and NEVER
#   aborts the host operation. Enum VALIDATION, by contrast, fails closed — an event that does not
#   conform to the closed vocabulary is refused (return 2) rather than written malformed.
#
# CORRELATION
#   oe_correlation_id honours an inherited SENTINEL_SHIELD_CORRELATION_ID so a parent operation and
#   the recovery it triggers share ONE correlation id (export it before invoking the child). Each
#   operation still gets its OWN operation id (oe_operation_id), so a stream can be grouped by
#   correlation and split by operation.
#
# REDACTION
#   The target identity is a NON-REVERSIBLE 12-hex prefix of sha256(absolute target path) — never a
#   raw path. The free-text next-action hint is passed through the unified redaction library
#   (rd_redact_stream) so no credential or repo-local absolute path can leak into the event stream.
#
# Requires scripts/lib/sentinel-shield-common.sh (log_*, timestamp_utc, ss_sha256_stdin) sourced
# first, and jq to build/validate events. The enum accessors (oe_commands, oe_phases, …) are kept
# in lockstep with schemas/operational-event.schema.json; tests/prod/254-operational-health.sh
# cross-checks the two so the vocabulary can never drift from the code.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_OPERATIONAL_EVENTS_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_OPERATIONAL_EVENTS_LOADED=1

# Resolve THIS library's directory so dependencies resolve regardless of the caller's CWD.
__oe_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/sentinel-shield-common.sh" ]; then
		# shellcheck source=scripts/lib/sentinel-shield-common.sh
		. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
	elif [ -f "$__oe_dir/sentinel-shield-common.sh" ]; then
		# shellcheck source=scripts/lib/sentinel-shield-common.sh
		. "$__oe_dir/sentinel-shield-common.sh"
	fi
fi
# Pull in the unified redaction library so free-text fields share ONE redaction implementation.
if [ "${__SENTINEL_SHIELD_REDACTION_LOADED:-}" != "1" ]; then
	if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/lib/redaction.sh" ]; then
		# shellcheck source=scripts/lib/redaction.sh
		. "$SCRIPT_DIR/lib/redaction.sh"
	elif [ -f "$__oe_dir/redaction.sh" ]; then
		# shellcheck source=scripts/lib/redaction.sh
		. "$__oe_dir/redaction.sh"
	fi
fi

# The event-model schema version. Bumped only on a breaking change to the object shape.
OE_SCHEMA_VERSION='1'

# --- closed vocabularies (kept in lockstep with the schema; test cross-checks) ----------------
# One value per line. A machine-readable drift check compares each list to the schema enum.
oe_commands() {
	printf '%s\n' acquisition install sync migration bootstrap doctor pipeline recovery \
		security-scan evidence-collection artifact-verification release-finalization health engine
}
oe_phases() {
	printf '%s\n' start precondition acquire snapshot execute mutate validate scan collect \
		verify finalize rollback complete
}
oe_event_types() {
	printf '%s\n' start progress complete error timeout retry skip
}
oe_severities() {
	printf '%s\n' debug info notice warning error critical
}
oe_statuses() {
	printf '%s\n' ok in-progress success failure skipped timeout unknown
}
oe_retryabilities() {
	printf '%s\n' none retryable non-retryable manual
}

# _oe_in_list <value> <list-producer-fn> — return 0 iff <value> is exactly one line of the list.
_oe_in_list() {
	"$2" | grep -Fxq -- "$1" 2>/dev/null
}

# --- monotonic-where-available clock ----------------------------------------------------------
# oe_now_ms — print a best-effort millisecond clock reading. Uses `date +%s%N` (nanoseconds) where
# the platform supports it; otherwise falls back to whole-second granularity (×1000). Not a true
# monotonic source — POSIX sh cannot reach one portably — but ELAPSED deltas between two readings
# are stable and non-negative under a steady clock, which is what the event stream records.
oe_now_ms() {
	_oe_ns=$(date +%s%N 2>/dev/null || printf '')
	case "$_oe_ns" in
		'' | *[!0-9]*)
			# No nanosecond support (e.g. a trailing literal 'N'): use whole seconds.
			_oe_s=$(date +%s 2>/dev/null || printf '0')
			case "$_oe_s" in ''|*[!0-9]*) _oe_s=0 ;; esac
			printf '%s' "$((_oe_s * 1000))"
			;;
		*)
			printf '%s' "$((_oe_ns / 1000000))"
			;;
	esac
	unset _oe_ns _oe_s
}

# oe_monotonic_available — return 0 when the high-resolution clock path is available (informational).
oe_monotonic_available() {
	_oe_ns=$(date +%s%N 2>/dev/null || printf '')
	case "$_oe_ns" in '' | *[!0-9]*) unset _oe_ns; return 1 ;; esac
	unset _oe_ns; return 0
}

# --- identity: correlation, operation, redacted target ----------------------------------------
# oe_gen_id <prefix> — mint a fresh id "<prefix>-<hex>". Prefers /dev/urandom; falls back to
# pid+epoch so an id is always produced (uniqueness is best-effort in the fallback).
oe_gen_id() {
	_oe_p="${1:-id}"
	_oe_r=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '')
	if [ -z "$_oe_r" ]; then
		_oe_r=$(printf '%s%s' "$$" "$(date +%s 2>/dev/null || printf '0')")
	fi
	printf '%s-%s' "$_oe_p" "$_oe_r"
	unset _oe_p _oe_r
}

# oe_correlation_id — the correlation id for THIS operation and any operations it triggers. Honours
# an inherited, non-empty SENTINEL_SHIELD_CORRELATION_ID so a parent and its recovery correlate.
oe_correlation_id() {
	if [ -n "${SENTINEL_SHIELD_CORRELATION_ID:-}" ]; then
		printf '%s' "$SENTINEL_SHIELD_CORRELATION_ID"
	else
		oe_gen_id corr
	fi
}

# oe_correlation_export — ensure SENTINEL_SHIELD_CORRELATION_ID is set+exported (minting one if
# absent) so a child process inherits the SAME correlation id. Prints the id.
oe_correlation_export() {
	if [ -z "${SENTINEL_SHIELD_CORRELATION_ID:-}" ]; then
		SENTINEL_SHIELD_CORRELATION_ID=$(oe_gen_id corr)
	fi
	export SENTINEL_SHIELD_CORRELATION_ID
	printf '%s' "$SENTINEL_SHIELD_CORRELATION_ID"
}

# oe_operation_id — the id UNIQUE to this operation. Honours a set SENTINEL_SHIELD_OPERATION_ID
# (so a wrapper can pin it); otherwise mints a fresh one.
oe_operation_id() {
	if [ -n "${SENTINEL_SHIELD_OPERATION_ID:-}" ]; then
		printf '%s' "$SENTINEL_SHIELD_OPERATION_ID"
	else
		oe_gen_id op
	fi
}

# oe_target_id <path> — a stable, NON-REVERSIBLE identity for a target directory: the 12-hex prefix
# of sha256(absolute path). Never the raw path. "target:none" for an empty argument;
# "target:unknown" when no sha256 tool is available.
oe_target_id() {
	if [ -z "${1:-}" ]; then printf 'target:none'; return 0; fi
	_oe_abs=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || _oe_abs="$1"
	if command -v ss_sha256_stdin >/dev/null 2>&1; then
		_oe_h=$(printf '%s' "$_oe_abs" | ss_sha256_stdin 2>/dev/null || printf '')
	else
		_oe_h=""
	fi
	if [ -n "$_oe_h" ]; then
		printf 'target:%s' "$(printf '%s' "$_oe_h" | cut -c1-12)"
	else
		printf 'target:unknown'
	fi
	unset _oe_abs _oe_h
}

# --- opt-in gate ------------------------------------------------------------------------------
# oe_enabled — return 0 iff opt-in JSONL emission is turned on AND a sink path is configured.
oe_enabled() {
	case "${SENTINEL_SHIELD_EVENTS:-}" in
		1 | true | True | TRUE | yes | Yes | YES | on | On | ON) : ;;
		*) return 1 ;;
	esac
	[ -n "${SENTINEL_SHIELD_EVENTS_FILE:-}" ] || return 1
	return 0
}

# --- the emitter ------------------------------------------------------------------------------
# oe_emit [flags] — build ONE normalized operational-event object and append it to the JSONL sink.
# A no-op returning 0 when emission is disabled. Flags (all optional except --command; unspecified
# fields take documented defaults):
#   --command <c>        one of oe_commands            (REQUIRED)
#   --phase <p>          one of oe_phases              (default: start)
#   --event-type <t>     one of oe_event_types         (default: progress)
#   --severity <s>       one of oe_severities          (default: info)
#   --status <st>        one of oe_statuses            (default: ok)
#   --reason-code <r>    stable snake/kebab reason code (default: unspecified)
#   --component <cmp>    subsystem name                (default: engine)
#   --retryability <rt>  one of oe_retryabilities      (default: none)
#   --next-action <txt>  free-text hint (REDACTED)     (default: none)
#   --target <dir>       target dir (identity is REDACTED to a hash)  (default: none)
#   --correlation-id <id>  override the inherited/derived correlation id
#   --operation-id <id>    override the inherited/derived operation id
#   --elapsed-ms <n>     precomputed elapsed ms (integer >= 0)
#   --start-ms <n>       start clock (from oe_now_ms); elapsed = now - start
# Returns 0 on success or when disabled; 2 on an invalid/closed-vocabulary violation (fail closed);
# a write failure degrades to a visible warning and returns 0 (audit trail, never a host abort).
oe_emit() {
	# Fast path: disabled => cheap no-op. Still validate NOTHING (no work) so the hot path is free.
	oe_enabled || return 0

	_oe_command=""; _oe_phase="start"; _oe_type="progress"; _oe_sev="info"
	_oe_status="ok"; _oe_reason="unspecified"; _oe_component="engine"; _oe_retry="none"
	_oe_next=""; _oe_target=""; _oe_corr=""; _oe_op=""; _oe_elapsed=""; _oe_start=""

	while [ $# -gt 0 ]; do
		case "$1" in
			--command)        _oe_command="${2:-}"; shift 2 ;;
			--phase)          _oe_phase="${2:-}"; shift 2 ;;
			--event-type)     _oe_type="${2:-}"; shift 2 ;;
			--severity)       _oe_sev="${2:-}"; shift 2 ;;
			--status)         _oe_status="${2:-}"; shift 2 ;;
			--reason-code)    _oe_reason="${2:-}"; shift 2 ;;
			--component)      _oe_component="${2:-}"; shift 2 ;;
			--retryability)   _oe_retry="${2:-}"; shift 2 ;;
			--next-action)    _oe_next="${2:-}"; shift 2 ;;
			--target)         _oe_target="${2:-}"; shift 2 ;;
			--correlation-id) _oe_corr="${2:-}"; shift 2 ;;
			--operation-id)   _oe_op="${2:-}"; shift 2 ;;
			--elapsed-ms)     _oe_elapsed="${2:-}"; shift 2 ;;
			--start-ms)       _oe_start="${2:-}"; shift 2 ;;
			*) log_warn "oe_emit: unknown flag '$1'"; return 2 ;;
		esac
	done

	# --- closed-vocabulary validation (FAIL CLOSED) --------------------------------------------
	command -v jq >/dev/null 2>&1 || { log_warn "oe_emit: jq unavailable; skipping event (audit only)"; return 0; }
	[ -n "$_oe_command" ] || { log_warn "oe_emit: --command is required"; return 2; }
	_oe_in_list "$_oe_command" oe_commands       || { log_warn "oe_emit: invalid command '$_oe_command'"; return 2; }
	_oe_in_list "$_oe_phase" oe_phases           || { log_warn "oe_emit: invalid phase '$_oe_phase'"; return 2; }
	_oe_in_list "$_oe_type" oe_event_types       || { log_warn "oe_emit: invalid event-type '$_oe_type'"; return 2; }
	_oe_in_list "$_oe_sev" oe_severities         || { log_warn "oe_emit: invalid severity '$_oe_sev'"; return 2; }
	_oe_in_list "$_oe_status" oe_statuses        || { log_warn "oe_emit: invalid status '$_oe_status'"; return 2; }
	_oe_in_list "$_oe_retry" oe_retryabilities   || { log_warn "oe_emit: invalid retryability '$_oe_retry'"; return 2; }
	[ -n "$_oe_reason" ] || { log_warn "oe_emit: --reason-code must be non-empty"; return 2; }
	[ -n "$_oe_component" ] || _oe_component="engine"

	# Elapsed: explicit --elapsed-ms wins; else derive from --start-ms; else null.
	_oe_elapsed_json='null'
	if [ -n "$_oe_elapsed" ]; then
		case "$_oe_elapsed" in ''|*[!0-9]*) log_warn "oe_emit: --elapsed-ms must be a non-negative integer"; return 2 ;; esac
		_oe_elapsed_json="$_oe_elapsed"
	elif [ -n "$_oe_start" ]; then
		case "$_oe_start" in ''|*[!0-9]*) log_warn "oe_emit: --start-ms must be a non-negative integer"; return 2 ;; esac
		_oe_nowms=$(oe_now_ms)
		if [ "$_oe_nowms" -ge "$_oe_start" ] 2>/dev/null; then
			_oe_elapsed_json=$((_oe_nowms - _oe_start))
		else
			_oe_elapsed_json=0
		fi
		unset _oe_nowms
	fi

	# Identity.
	[ -n "$_oe_corr" ] || _oe_corr=$(oe_correlation_id)
	[ -n "$_oe_op" ] || _oe_op=$(oe_operation_id)
	_oe_tid=$(oe_target_id "$_oe_target")

	# Redact the ONLY free-text field. Controlled-vocabulary fields need no redaction.
	if [ -n "$_oe_next" ]; then
		if command -v rd_redact_stream >/dev/null 2>&1; then
			_oe_next=$(printf '%s' "$_oe_next" | rd_redact_stream 2>/dev/null || printf '')
			_oe_next_json=$(printf '%s' "$_oe_next" | jq -Rs '.')
		else
			# Fail closed: without the redactor we cannot guarantee this free-text field
			# carries no secret/path, so we drop the content rather than emit it raw.
			_oe_next_json='"[redaction-unavailable]"'
		fi
	else
		_oe_next_json='null'
	fi

	_oe_line=$(jq -cn \
		--arg sv "$OE_SCHEMA_VERSION" \
		--arg ts "$(timestamp_utc)" \
		--arg command "$_oe_command" \
		--arg phase "$_oe_phase" \
		--arg event_type "$_oe_type" \
		--arg severity "$_oe_sev" \
		--arg reason_code "$_oe_reason" \
		--arg status "$_oe_status" \
		--arg component "$_oe_component" \
		--arg retryability "$_oe_retry" \
		--arg correlation_id "$_oe_corr" \
		--arg operation_id "$_oe_op" \
		--arg target "$_oe_tid" \
		--argjson elapsed_ms "$_oe_elapsed_json" \
		--argjson next_action "$_oe_next_json" '
		{
			schema: "operational-event",
			schema_version: $sv,
			ts: $ts,
			command: $command,
			phase: $phase,
			event_type: $event_type,
			severity: $severity,
			reason_code: $reason_code,
			status: $status,
			component: $component,
			retryability: $retryability,
			correlation_id: $correlation_id,
			operation_id: $operation_id,
			target: $target,
			elapsed_ms: $elapsed_ms,
			next_action: $next_action
		}' 2>/dev/null || printf '')

	if [ -z "$_oe_line" ]; then
		log_warn "oe_emit: could not build a '$_oe_command/$_oe_phase' event"
		return 0
	fi

	# Best-effort durable append to the JSONL sink (never aborts the host operation).
	if ! printf '%s\n' "$_oe_line" >> "$SENTINEL_SHIELD_EVENTS_FILE" 2>/dev/null; then
		log_warn "oe_emit: could not append an event to the sink"
	fi
	# Optional echo to stdout for pipelines that also want the stream inline.
	case "${SENTINEL_SHIELD_EVENTS_STDOUT:-}" in
		1 | true | yes | on) printf '%s\n' "$_oe_line" ;;
	esac

	unset _oe_command _oe_phase _oe_type _oe_sev _oe_status _oe_reason _oe_component _oe_retry \
		_oe_next _oe_target _oe_corr _oe_op _oe_elapsed _oe_start _oe_elapsed_json _oe_tid \
		_oe_next_json _oe_line
	return 0
}

# --- validation (structural, jq-based; no ajv) ------------------------------------------------
# oe_validate_line — read ONE JSON line on STDIN; return 0 iff it conforms to the operational-event
# contract (all required fields, correct types, and every closed field within its vocabulary).
oe_validate_line() {
	command -v jq >/dev/null 2>&1 || { log_error "oe_validate_line: jq is required"; return 2; }
	_oe_commands_json=$(oe_commands | jq -Rn '[inputs]')
	_oe_phases_json=$(oe_phases | jq -Rn '[inputs]')
	_oe_types_json=$(oe_event_types | jq -Rn '[inputs]')
	_oe_sev_json=$(oe_severities | jq -Rn '[inputs]')
	_oe_status_json=$(oe_statuses | jq -Rn '[inputs]')
	_oe_retry_json=$(oe_retryabilities | jq -Rn '[inputs]')
	jq -e \
		--argjson commands "$_oe_commands_json" \
		--argjson phases "$_oe_phases_json" \
		--argjson types "$_oe_types_json" \
		--argjson sevs "$_oe_sev_json" \
		--argjson statuses "$_oe_status_json" \
		--argjson retries "$_oe_retry_json" '
		(.schema == "operational-event") and
		(.schema_version == "1") and
		(.ts | type == "string" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
		(.command as $x | $commands | index($x) != null) and
		(.phase as $x | $phases | index($x) != null) and
		(.event_type as $x | $types | index($x) != null) and
		(.severity as $x | $sevs | index($x) != null) and
		(.status as $x | $statuses | index($x) != null) and
		(.retryability as $x | $retries | index($x) != null) and
		(.reason_code | type == "string" and (length > 0)) and
		(.component | type == "string" and (length > 0)) and
		(.correlation_id | type == "string" and (length > 0)) and
		(.operation_id | type == "string" and (length > 0)) and
		(.target | type == "string" and (length > 0)) and
		((.elapsed_ms == null) or (.elapsed_ms | type == "number")) and
		((.next_action == null) or (.next_action | type == "string"))
	' >/dev/null 2>&1
	_oe_rc=$?
	unset _oe_commands_json _oe_phases_json _oe_types_json _oe_sev_json _oe_status_json _oe_retry_json
	return "$_oe_rc"
}

# oe_validate_file <path> — validate EVERY non-empty line of a JSONL event file. Returns 0 iff all
# lines conform; 1 on the first non-conforming line (logged, fail closed); 2 if jq/file missing.
oe_validate_file() {
	command -v jq >/dev/null 2>&1 || { log_error "oe_validate_file: jq is required"; return 2; }
	[ -f "${1:-}" ] || { log_error "oe_validate_file: missing file '${1:-}'"; return 2; }
	_oe_n=0
	while IFS= read -r _oe_l || [ -n "$_oe_l" ]; do
		[ -n "$_oe_l" ] || continue
		_oe_n=$((_oe_n + 1))
		if ! printf '%s' "$_oe_l" | oe_validate_line; then
			log_error "oe_validate_file: line $_oe_n does not conform to operational-event.schema.json"
			unset _oe_n _oe_l
			return 1
		fi
	done < "$1"
	unset _oe_n _oe_l
	return 0
}
