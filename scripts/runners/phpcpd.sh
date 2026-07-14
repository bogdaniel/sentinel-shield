#!/bin/sh
# Sentinel Shield runner — PHPCPD (copy/paste detection) -> reports/raw/php-duplication.json.
#
# Detects vendor/bin/phpcpd, runs it over the source tree, parses the "N% duplicated lines"
# summary, and thresholds it against quality.duplication.max_percentage from the policy.
#
# Contract: tool ABSENT or unparseable output -> leave report ABSENT + EXIT 0 + log_warn
# (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Env: SENTINEL_SHIELD_PHPCPD_BIN (default: vendor/bin/phpcpd), SENTINEL_SHIELD_PHPCPD_PATHS
# Usage: phpcpd.sh [--output reports/raw/php-duplication.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/php-duplication.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpcpd.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "phpcpd: jq is required."; exit 2; }
command_exists php || { log_warn "phpcpd: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

BIN="${SENTINEL_SHIELD_PHPCPD_BIN:-}"
if [ -z "$BIN" ]; then
	if [ -x vendor/bin/phpcpd ]; then BIN="vendor/bin/phpcpd"
	elif command_exists phpcpd; then BIN="phpcpd"
	fi
fi
[ -n "$BIN" ] || { log_warn "phpcpd: not found (vendor/bin/phpcpd); leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

PATHS="${SENTINEL_SHIELD_PHPCPD_PATHS:-}"
if [ -z "$PATHS" ]; then
	for _d in src app; do [ -d "$_d" ] && PATHS="${PATHS:+$PATHS }$_d"; done
	[ -n "$PATHS" ] || PATHS="."
fi

qp_load "$POLICY"
THRESH=$(qp_num quality.duplication.max_percentage 5)

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_out="$_dir/phpcpd.stdout.log"
_err="$_dir/phpcpd.stderr.log"

log_info "phpcpd: $BIN $PATHS"
# shellcheck disable=SC2086
"$BIN" $PATHS >"$_out" 2>"$_err" || true

# Parse "X.XX% duplicated lines"; PHPCPD prints "0.00% duplicated lines out of ..." on clean.
PCT=$(grep -Eo '[0-9]+(\.[0-9]+)?% duplicated lines' "$_out" 2>/dev/null | grep -Eo '^[0-9]+(\.[0-9]+)?' | head -n1)
if [ -z "$PCT" ]; then
	log_warn "phpcpd: could not parse a duplication percentage; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_out, $_err."
	exit 0
fi

jq -n --argjson pct "$PCT" --argjson thr "$THRESH" '
	{ tool:"duplication",
	  status: (if $pct > $thr then "findings" else "pass" end),
	  duplication_percent: $pct, threshold: $thr,
	  violations: (if $pct > $thr then 1 else 0 end) }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "phpcpd: wrote $OUTPUT (duplication=$PCT%, threshold=$THRESH%)."
	rm -f "$_out" "$_err" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "phpcpd: could not write normalized report; leaving '$OUTPUT' absent."
exit 0
