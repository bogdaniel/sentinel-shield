#!/bin/sh
# Sentinel Shield runner — Infection (PHP mutation testing) -> reports/raw/php-mutation.json.
#
# Detects vendor/bin/infection, runs it with the JSON logger, reads the mutation score
# indicator (stats.msi), and thresholds it against quality.mutation.min_score from the
# quality policy. Mutation testing is SLOW — profiles keep this optional/regulated.
#
# Contract: tool ABSENT or no valid JSON logger -> leave report ABSENT + EXIT 0 + log_warn
# (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Env: SENTINEL_SHIELD_INFECTION_BIN (default: vendor/bin/infection)
# Usage: infection.sh [--output reports/raw/php-mutation.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/php-mutation.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: infection.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "infection: jq is required."; exit 2; }
command_exists php || { log_warn "infection: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

BIN="${SENTINEL_SHIELD_INFECTION_BIN:-}"
if [ -z "$BIN" ]; then
	if [ -x vendor/bin/infection ]; then BIN="vendor/bin/infection"
	elif command_exists infection; then BIN="infection"
	fi
fi
[ -n "$BIN" ] || { log_warn "infection: not found (vendor/bin/infection); leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

qp_load "$POLICY"
MIN=$(qp_num quality.mutation.min_score 70)

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_json="$_dir/infection.json"
_err="$_dir/infection.stderr.log"
rm -f "$_json" 2>/dev/null || true

log_info "infection: $BIN --logger-json=$_json --min-msi=0 --no-progress --no-interaction"
# --min-msi=0 so Infection itself never fails the run; Sentinel Shield does the thresholding.
"$BIN" --logger-json="$_json" --min-msi=0 --no-progress --no-interaction >"$_dir/infection.stdout.raw" 2>"$_err" || true

_msi=$(jq -r 'if (.stats.msi|type)=="number" then .stats.msi else empty end' "$_json" 2>/dev/null || true)
if [ -z "$_msi" ]; then
	log_warn "infection: no valid JSON logger with stats.msi produced; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

jq -n --argjson score "$_msi" --argjson min "$MIN" '
	{ tool:"mutation",
	  status: (if $score < $min then "findings" else "pass" end),
	  score_percent: $score, min_score: $min,
	  violations: (if $score < $min then 1 else 0 end) }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "infection: wrote $OUTPUT (msi=$_msi, min=$MIN)."
	rm -f "$_json" "$_dir/infection.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "infection: could not write normalized report; leaving '$OUTPUT' absent."
exit 0
