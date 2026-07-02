#!/bin/sh
# scripts/report-consumer-validation.sh — assemble a consumer-validation record.
#
# Shared reporter for the real-consumer validation drivers (tests/prod/2NN-*-consumer.sh).
# It takes the caller's already-computed gate results (as JSON files) plus metadata
# flags, stamps a UTC timestamp + schema_version, and prints ONE record on stdout that
# conforms to schemas/consumer-validation.schema.json. It does NOT decide pass/fail and
# it NEVER invents a green result — the driver supplies --result and the gate array; the
# reporter only wraps and structurally re-validates them (required keys present, valid
# JSON). A 'skip' gate stays a skip. Fail closed (exit 2) on malformed input.
#
# Usage:
#   report-consumer-validation.sh \
#     --consumer-name NAME --consumer-kind KIND --consumer-path PATH \
#     --profile PROFILE --composer present|absent --php present|absent \
#     --result pass|fail|partial \
#     --tool-groups-file FILE --gates-file FILE --mutation-file FILE \
#     [--limitation TEXT ...]
#
# --tool-groups-file : JSON object {test,static_analysis,style} (schema tool_groups)
# --gates-file       : JSON array of gate objects (schema gates[])
# --mutation-file    : JSON object (schema mutation)
#
# Exit: 0 ok (record on stdout), 2 bad args / malformed input / jq missing.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

SCHEMA_VERSION="1"

CONSUMER_NAME=""
CONSUMER_KIND=""
CONSUMER_PATH=""
PROFILE=""
COMPOSER="absent"
PHP="absent"
RESULT=""
TOOL_GROUPS_FILE=""
GATES_FILE=""
MUTATION_FILE=""
# Limitations accumulate into a newline-delimited buffer (POSIX: no arrays).
LIMITATIONS=""

usage() {
	log_error "usage: report-consumer-validation.sh --consumer-name N --consumer-kind K --consumer-path P --profile PR --composer present|absent --php present|absent --result pass|fail|partial --tool-groups-file F --gates-file F --mutation-file F [--limitation TEXT ...]"
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--consumer-name) CONSUMER_NAME="${2:-}"; shift 2 ;;
		--consumer-kind) CONSUMER_KIND="${2:-}"; shift 2 ;;
		--consumer-path) CONSUMER_PATH="${2:-}"; shift 2 ;;
		--profile) PROFILE="${2:-}"; shift 2 ;;
		--composer) COMPOSER="${2:-}"; shift 2 ;;
		--php) PHP="${2:-}"; shift 2 ;;
		--result) RESULT="${2:-}"; shift 2 ;;
		--tool-groups-file) TOOL_GROUPS_FILE="${2:-}"; shift 2 ;;
		--gates-file) GATES_FILE="${2:-}"; shift 2 ;;
		--mutation-file) MUTATION_FILE="${2:-}"; shift 2 ;;
		--limitation)
			# Append item + a literal newline. Do NOT wrap in $(...) — command
			# substitution strips trailing newlines and would merge entries.
			LIMITATIONS="${LIMITATIONS}${2:-}
"
			shift 2 ;;
		-h | --help) usage ;;
		*) log_error "unknown argument: $1"; usage ;;
	esac
done

command_exists jq || { log_error "jq is required by report-consumer-validation.sh"; exit 2; }

# Required scalar flags.
for _pair in \
	"consumer-name:$CONSUMER_NAME" \
	"consumer-kind:$CONSUMER_KIND" \
	"consumer-path:$CONSUMER_PATH" \
	"profile:$PROFILE" \
	"result:$RESULT"; do
	_k=${_pair%%:*}
	_v=${_pair#*:}
	if [ -z "$_v" ]; then
		log_error "missing required --$_k"
		usage
	fi
done

case "$COMPOSER" in present | absent) ;; *) log_error "--composer must be present|absent"; exit 2 ;; esac
case "$PHP" in present | absent) ;; *) log_error "--php must be present|absent"; exit 2 ;; esac
case "$RESULT" in pass | fail | partial) ;; *) log_error "--result must be pass|fail|partial"; exit 2 ;; esac

# Required JSON inputs must exist and parse.
for _f in "$TOOL_GROUPS_FILE" "$GATES_FILE" "$MUTATION_FILE"; do
	if [ -z "$_f" ]; then
		log_error "missing one of --tool-groups-file/--gates-file/--mutation-file"
		exit 2
	fi
	if [ ! -f "$_f" ]; then
		log_error "input file not found: $_f"
		exit 2
	fi
	if ! jq -e . "$_f" >/dev/null 2>&1; then
		log_error "input file is not valid JSON: $_f"
		exit 2
	fi
done

# gates must be a non-empty array; mutation and tool_groups must be objects.
if [ "$(jq -r 'if type=="array" then "array" else type end' "$GATES_FILE")" != "array" ]; then
	log_error "--gates-file must contain a JSON array"
	exit 2
fi
if [ "$(jq -r 'length' "$GATES_FILE")" -lt 1 ]; then
	log_error "--gates-file array must not be empty"
	exit 2
fi
if [ "$(jq -r 'type' "$TOOL_GROUPS_FILE")" != "object" ]; then
	log_error "--tool-groups-file must contain a JSON object"
	exit 2
fi
if [ "$(jq -r 'type' "$MUTATION_FILE")" != "object" ]; then
	log_error "--mutation-file must contain a JSON object"
	exit 2
fi

# Build the limitations JSON array from the newline buffer.
LIMITATIONS_JSON=$(printf '%s' "$LIMITATIONS" | jq -R -s 'split("\n") | map(select(length > 0))')

jq -n \
	--arg schema_version "$SCHEMA_VERSION" \
	--arg generated_at "$(timestamp_utc)" \
	--arg name "$CONSUMER_NAME" \
	--arg kind "$CONSUMER_KIND" \
	--arg path "$CONSUMER_PATH" \
	--arg profile "$PROFILE" \
	--arg composer "$COMPOSER" \
	--arg php "$PHP" \
	--arg result "$RESULT" \
	--argjson tool_groups "$(cat "$TOOL_GROUPS_FILE")" \
	--argjson gates "$(cat "$GATES_FILE")" \
	--argjson mutation "$(cat "$MUTATION_FILE")" \
	--argjson limitations "$LIMITATIONS_JSON" \
	'{
		schema_version: $schema_version,
		generated_at: $generated_at,
		consumer: { name: $name, kind: $kind, path: $path },
		profile: $profile,
		toolchain: { composer: $composer, php: $php },
		tool_groups: $tool_groups,
		gates: $gates,
		mutation: $mutation,
		result: $result,
		limitations: $limitations
	}'
