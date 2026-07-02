#!/bin/sh
# Sentinel Shield — consumer-validation reporter (POSIX sh library).
#
# Source this file; do not execute it. It provides helpers that emit and validate
# consumer-validation records conforming to schemas/consumer-validation.schema.json
# (line-delimited JSON, one object per line). Real-consumer validation drivers
# (e.g. tests/prod/200-php-consumer.sh, tests/prod/201-node-consumers.sh) use it so
# every consumer produces uniform, machine-checkable evidence.
#
# Requires the shared library first (for log_* / command_exists / timestamp_utc) and jq:
#   . "$ROOT/scripts/lib/sentinel-shield-common.sh"
#   . "$ROOT/scripts/report-consumer-validation.sh"
#
# Optional per-driver tag: export RCV_ECOSYSTEM=php|node|react before calling
# rcv_record to stamp the optional "ecosystem" field. Leave it empty/unset for
# stack-agnostic synthetic fixtures — the field is then omitted.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_RCV_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_RCV_LOADED=1

# rcv_record <consumer> <package_manager> <check> <gate> <status> <reason_code> <mode> [detail]
# Emit ONE schema-valid JSON record on stdout. jq guarantees correct escaping.
# The optional "ecosystem" field is added from $RCV_ECOSYSTEM when it is non-empty.
rcv_record() {
	command_exists jq || {
		log_error "rcv_record: jq is required to emit consumer-validation records"
		return 2
	}
	jq -cn \
		--arg consumer "$1" \
		--arg pm "$2" \
		--arg check "$3" \
		--arg gate "$4" \
		--arg status "$5" \
		--arg reason "$6" \
		--arg mode "$7" \
		--arg detail "${8:-}" \
		--arg ecosystem "${RCV_ECOSYSTEM:-}" \
		--arg ts "$(timestamp_utc)" '
		{
			schema_version: "1",
			consumer: $consumer,
			package_manager: $pm,
			check: $check,
			gate: $gate,
			status: $status,
			reason_code: $reason,
			mode: $mode,
			timestamp: $ts
		}
		+ (if $ecosystem == "" then {} else { ecosystem: $ecosystem } end)
		+ (if $detail == "" then {} else { detail: $detail } end)'
}

# rcv_validate <file> — structurally validate a JSONL record file against the
# schema's required keys and enums using jq (jq-structural; no ajv). Prints the
# offending line to stderr and returns 1 on the first invalid record; 0 if all
# records are well-formed. An empty file is an error (no evidence produced).
rcv_validate() {
	command_exists jq || {
		log_error "rcv_validate: jq is required"
		return 2
	}
	if [ ! -s "$1" ]; then
		log_error "rcv_validate: '$1' is empty — no consumer-validation records emitted"
		return 1
	fi
	# Each line must: parse as an object; carry schema_version "1"; have all
	# required keys; and use only enum-permitted values for the closed fields.
	# 'ecosystem' is optional but, when present, must be php|node|react.
	_bad=$(jq -c '
		. as $r
		| select(
			($r | type != "object")
			or ($r.schema_version != "1")
			or ($r | has("consumer") | not) or ($r.consumer == "")
			or ($r | has("check") | not) or ($r.check == "")
			or ($r | has("reason_code") | not) or ($r.reason_code == "")
			or ([ "npm","pnpm","yarn","none" ] | index($r.package_manager) | not)
			or ([ "pass","fail","skip" ] | index($r.status) | not)
			or ([ "live","structural" ] | index($r.mode) | not)
			or ([ "package-manager","lockfile","one-of","typecheck","lint","test","audit","rollback","install","manifest","static-analysis","style","config" ] | index($r.gate) | not)
			or (($r | has("ecosystem")) and ([ "php","node","react" ] | index($r.ecosystem) | not))
		)' "$1" 2>/dev/null) || {
		log_error "rcv_validate: '$1' contains a line that is not valid JSON"
		return 1
	}
	if [ -n "$_bad" ]; then
		log_error "rcv_validate: invalid consumer-validation record(s):"
		printf '%s\n' "$_bad" >&2
		return 1
	fi
	return 0
}
