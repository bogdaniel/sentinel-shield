#!/bin/sh
# Sentinel Shield runner — PHPMD (complexity) -> reports/raw/php-complexity.json.
#
# Detects vendor/bin/phpmd, runs it over the source tree with the 'codesize' ruleset
# (Cyclomatic/NPath complexity, excessive length), and normalizes the JSON report: the
# number of codesize violations becomes complexity_violations. max/average complexity are
# informational and reported only when derivable from the violation messages (else 0).
#
# Contract: tool ABSENT or no valid JSON -> leave report ABSENT + EXIT 0 + log_warn (builder
# marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on missing jq.
#
# Env: SENTINEL_SHIELD_PHPMD_BIN (default: vendor/bin/phpmd), SENTINEL_SHIELD_PHPMD_PATHS
# Usage: phpmd-complexity.sh [--output reports/raw/php-complexity.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/php-complexity.json"
POLICY=".sentinel-shield/quality-policy.yaml"  # reserved (PHPMD ruleset owns the threshold)
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: phpmd-complexity.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "phpmd-complexity: jq is required."; exit 2; }
command_exists php || { log_warn "phpmd-complexity: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

BIN="${SENTINEL_SHIELD_PHPMD_BIN:-}"
if [ -z "$BIN" ]; then
	if [ -x vendor/bin/phpmd ]; then BIN="vendor/bin/phpmd"
	elif command_exists phpmd; then BIN="phpmd"
	fi
fi
[ -n "$BIN" ] || { log_warn "phpmd-complexity: not found (vendor/bin/phpmd); leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

# Source paths: explicit env, else src/ and/or app/, else the project root.
PATHS="${SENTINEL_SHIELD_PHPMD_PATHS:-}"
if [ -z "$PATHS" ]; then
	for _d in src app; do [ -d "$_d" ] && PATHS="${PATHS:+$PATHS,}$_d"; done
	[ -n "$PATHS" ] || PATHS="."
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_json="$_dir/phpmd.json"
_err="$_dir/phpmd.stderr.log"
rm -f "$_json" 2>/dev/null || true

log_info "phpmd-complexity: $BIN $PATHS json codesize"
# PHPMD exits non-zero when violations are found — that is a FINDING, not a runner failure.
"$BIN" "$PATHS" json codesize >"$_json" 2>"$_err" || true

# Require the PHPMD report SHAPE (a .files array), not merely "an object": a bare `{}` or an
# unrelated JSON blob must not normalize to a clean 0. A genuine clean run emits {"files":[]}.
if ! jq -e '(.files | type) == "array"' "$_json" >/dev/null 2>&1; then
	log_warn "phpmd-complexity: no valid PHPMD JSON report (missing .files array); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
	exit 0
fi

# complexity_violations = number of codesize violations across files.
# max_complexity best-effort: largest "Complexity of N" integer in any violation message.
jq '
	def msgs: [ (.files // [])[] | (.violations // [])[] | (.description // "") ];
	def nums: [ msgs[] | (capture("Complexity of (?<n>[0-9]+)")? | .n | tonumber) ];
	((.files // []) | map((.violations // []) | length) | add // 0) as $v
	| (nums) as $ns
	| { tool:"complexity",
	    status: (if $v > 0 then "findings" else "pass" end),
	    max_complexity: (if ($ns|length) > 0 then ($ns|max) else 0 end),
	    average_complexity: (if ($ns|length) > 0 then (($ns|add) / ($ns|length)) else 0 end),
	    violations: $v }' "$_json" > "$OUTPUT" 2>>"$_err" || true

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "phpmd-complexity: wrote $OUTPUT."
	rm -f "$_json" "$_err" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "phpmd-complexity: could not normalize PHPMD JSON; leaving '$OUTPUT' absent. Debug: $_json, $_err."
exit 0
