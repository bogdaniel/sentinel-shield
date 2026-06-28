#!/bin/sh
# Sentinel Shield runner — Laravel Pint (check only) -> reports/raw/pint.json.
#
# Runs `pint --test --format=json` which reports style violations WITHOUT mutating files
# (--test is dry-run). Pint exits non-zero when violations exist — that is FINDINGS, not a
# runner failure, so we keep going and EXIT 0; the JSON report is the signal.
#
# Contract (matches laravel-phpstan.sh): detect exe deterministically (vendor/bin/pint then
# pint on PATH); no project mutation; validated normalized report; tool ABSENT or no valid
# JSON -> leave report ABSENT + EXIT 0 + log_warn (builder marks 'unavailable'); NEVER write
# a fake clean report; EXIT 2 only on bad invocation / missing jq.
#
# Env: SENTINEL_SHIELD_PINT_BIN (default: vendor/bin/pint, then pint)
# Usage: pint.sh [--output reports/raw/pint.json]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/pint.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: pint.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "pint: jq is required."; exit 2; }

PINT_BIN="${SENTINEL_SHIELD_PINT_BIN:-}"
if [ -z "$PINT_BIN" ]; then
	if [ -x vendor/bin/pint ]; then PINT_BIN="vendor/bin/pint"
	elif command_exists pint; then PINT_BIN="pint"
	fi
fi
if [ -z "$PINT_BIN" ]; then
	log_warn "pint: Laravel Pint not found (vendor/bin/pint or pint); leaving '$OUTPUT' absent (tool unavailable). Run 'composer install' first."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/pint.stdout.raw"
_err="$_dir/pint.stderr.log"

log_info "pint: $PINT_BIN --test --format=json"
_rc=0
"$PINT_BIN" --test --format=json >"$_raw" 2>"$_err" || _rc=$?

if jq -e . "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"
	log_info "pint: wrote $OUTPUT (exit ${_rc:-0})."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi

log_warn "pint: produced no valid JSON on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
