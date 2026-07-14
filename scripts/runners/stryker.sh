#!/bin/sh
# Sentinel Shield runner — StrykerJS (JS/TS mutation testing) -> reports/raw/js-mutation.json.
#
# Detects node_modules/.bin/stryker (or npx stryker), runs it with the JSON reporter, and
# computes the mutation score from the mutant statuses in reports/mutation/mutation.json:
#   score = (Killed + Timeout) / (Killed + Timeout + Survived + NoCoverage) * 100
# then thresholds it against quality.mutation.min_score. Mutation testing is SLOW —
# profiles keep this optional.
#
# Contract: tool ABSENT or no valid report -> leave report ABSENT + EXIT 0 + log_warn
# (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Env: SENTINEL_SHIELD_STRYKER_REPORT (default: reports/mutation/mutation.json)
# Usage: stryker.sh [--output reports/raw/js-mutation.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/js-mutation.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: stryker.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "stryker: jq is required."; exit 2; }
command_exists node || { log_warn "stryker: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

BIN=""
if [ -x node_modules/.bin/stryker ]; then BIN="node_modules/.bin/stryker"
elif command_exists stryker; then BIN="stryker"
fi
[ -n "$BIN" ] || { log_warn "stryker: not found (node_modules/.bin/stryker); leaving '$OUTPUT' absent (tool unavailable). Install with 'npm i -D @stryker-mutator/core'."; exit 0; }

qp_load "$POLICY"
MIN=$(qp_num quality.mutation.min_score 70)
REPORT="${SENTINEL_SHIELD_STRYKER_REPORT:-reports/mutation/mutation.json}"

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_err="$_dir/stryker.stderr.log"
rm -f "$REPORT" 2>/dev/null || true

log_info "stryker: $BIN run --reporters json"
"$BIN" run --reporters json >"$_dir/stryker.stdout.log" 2>"$_err" || true

if ! jq -e 'type=="object"' "$REPORT" >/dev/null 2>&1; then
	log_warn "stryker: no valid JSON report at '$REPORT'; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

# Mutation score from mutant statuses; NoCoverage counts against the score.
jq --argjson min "$MIN" '
	[ (.files // {}) | to_entries[] | .value.mutants[]? | .status ] as $st
	| ([ $st[] | select(. == "Killed" or . == "Timeout") ] | length) as $killed
	| ([ $st[] | select(. == "Killed" or . == "Timeout" or . == "Survived" or . == "NoCoverage") ] | length) as $total
	| (if $total > 0 then (($killed / $total) * 1000 | round) / 10 else 0 end) as $score
	| { tool:"mutation",
	    status: (if $score < $min then "findings" else "pass" end),
	    score_percent: $score, min_score: $min,
	    violations: (if ($total > 0 and $score < $min) then 1 else 0 end) }' "$REPORT" > "$OUTPUT" 2>>"$_err" || true

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "stryker: wrote $OUTPUT (min=$MIN)."
	rm -f "$_err" "$_dir/stryker.stdout.log" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "stryker: could not normalize the mutation report; leaving '$OUTPUT' absent."
exit 0
