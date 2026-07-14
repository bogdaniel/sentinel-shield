#!/bin/sh
# Sentinel Shield runner — dead code (knip, then ts-prune) -> reports/raw/js-dead-code.json.
#
# Prefers node_modules/.bin/knip (JSON reporter) and falls back to ts-prune (line count).
# The number of dead-code items becomes dead_code_count / dead_code_violations. Dead-code
# detection is noisy — profiles keep this optional.
#
# Contract: tool ABSENT or unparseable output -> leave report ABSENT + EXIT 0 + log_warn
# (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Usage: knip.sh [--output reports/raw/js-dead-code.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/js-dead-code.json"
POLICY=".sentinel-shield/quality-policy.yaml"  # reserved (dead_code has no numeric threshold)
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: knip.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "knip: jq is required."; exit 2; }
command_exists node || { log_warn "knip: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_err="$_dir/dead-code.stderr.log"
COUNT=""

if [ -x node_modules/.bin/knip ]; then
	log_info "knip: node_modules/.bin/knip --reporter json"
	_json="$_dir/knip.json"
	node_modules/.bin/knip --reporter json >"$_json" 2>"$_err" || true
	# Sum knip issue counts across the common categories (version-tolerant).
	COUNT=$(jq -r '
		if type=="object" then
			((.files // []) | length)
			+ ([ (.issues // [])[]? | ((.exports // {}) | length) + ((.types // {}) | length)
				+ ((.dependencies // []) | length) + ((.unlisted // {}) | length) ] | add // 0)
		else empty end' "$_json" 2>/dev/null || true)
elif [ -x node_modules/.bin/ts-prune ] || command_exists ts-prune; then
	_TP="ts-prune"; [ -x node_modules/.bin/ts-prune ] && _TP="node_modules/.bin/ts-prune"
	log_info "knip: falling back to $_TP (line count)"
	# ts-prune prints one line per unused export; ignore "(used in module)" re-exports.
	COUNT=$("$_TP" 2>"$_err" | grep -v '(used in module)' | grep -c ':' || true)
else
	log_warn "knip: no dead-code tool found (node_modules/.bin/knip or ts-prune); leaving '$OUTPUT' absent (tool unavailable). Install with 'npm i -D knip' or 'npm i -D ts-prune'."
	exit 0
fi

case "$COUNT" in
	'' | *[!0-9]*) log_warn "knip: could not derive a dead-code count; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."; exit 0 ;;
esac

jq -n --argjson n "$COUNT" '
	{ tool:"dead-code",
	  status: (if $n > 0 then "findings" else "pass" end),
	  dead_code_count: $n, violations: $n }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "knip: wrote $OUTPUT (dead_code_count=$COUNT)."
	rm -f "$_err" "$_dir/knip.json" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "knip: could not write normalized report; leaving '$OUTPUT' absent."
exit 0
