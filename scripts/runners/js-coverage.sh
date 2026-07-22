#!/bin/sh
# Sentinel Shield runner — JS coverage (Istanbul/Vitest/Jest) -> reports/raw/js-coverage.json.
#
# Detects the package manager (pnpm/yarn/npm via lockfile), runs a coverage script
# (test:coverage, then coverage) when one is declared, then normalizes the standard
# coverage/coverage-summary.json via scripts/adapters/istanbul-summary-to-coverage-json.mjs
# using the thresholds/baseline from .sentinel-shield/quality-policy.yaml.
#
# Contract (matches jest.sh/vitest.sh): detect deterministically; no project mutation beyond
# reports/ + the tool's own coverage/ dir; tool/report ABSENT -> leave report ABSENT + EXIT 0 +
# log_warn (builder marks 'unavailable'); NEVER write a fake clean report; EXIT 2 only on bad
# invocation / missing jq.
#
# Env: SENTINEL_SHIELD_JS_COVERAGE_SUMMARY (default: coverage/coverage-summary.json)
# Usage: js-coverage.sh [--output reports/raw/js-coverage.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/js-coverage.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: js-coverage.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "js-coverage: jq is required."; exit 2; }
command_exists node || { log_warn "js-coverage: node not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/istanbul-summary-to-coverage-json.mjs"
[ -f "$ADAPTER" ] || { log_error "js-coverage: adapter not found: $ADAPTER"; exit 2; }

[ -f package.json ] || { log_warn "js-coverage: no package.json; leaving '$OUTPUT' absent (not a Node project)."; exit 0; }

qp_load "$POLICY"
if [ "$(qp_bool quality.coverage.enabled true)" = "false" ]; then
	log_warn "js-coverage: disabled in quality policy (quality.coverage.enabled: false); leaving '$OUTPUT' absent."
	exit 0
fi

SUMMARY="${SENTINEL_SHIELD_JS_COVERAGE_SUMMARY:-coverage/coverage-summary.json}"

# Detect the package manager from the lockfile (deterministic).
PM=""
if [ -f pnpm-lock.yaml ]; then PM="pnpm"
elif [ -f yarn.lock ]; then PM="yarn"
elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then PM="npm"
elif command_exists npm; then PM="npm"
fi

# Detect a coverage script (test:coverage preferred, then coverage).
COV_SCRIPT=""
for _s in test:coverage coverage; do
	if jq -e --arg s "$_s" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then COV_SCRIPT="$_s"; break; fi
done

# Create the report dir BEFORE running coverage: the run-log redirection below writes into
# it, and a missing dir would abort the coverage run (masked by `|| true`) and silently fall
# back to a stale/absent summary.
ensure_dir "$(dirname "$OUTPUT")"

# Run the coverage script when we can (best-effort; findings are the signal, not the rc).
if [ -n "$COV_SCRIPT" ] && [ -n "$PM" ] && command_exists "$PM"; then
	log_info "js-coverage: $PM run $COV_SCRIPT"
	# Clear any stale summary FIRST: if this run fails or emits a different reporter, a
	# previous run's coverage-summary.json must not be normalized as current evidence.
	rm -f -- "$SUMMARY" 2>/dev/null || true
	case "$PM" in
		yarn) yarn "$COV_SCRIPT" >"$(dirname "$OUTPUT")/js-coverage.run.log" 2>&1 || true ;;
		*)    "$PM" run "$COV_SCRIPT" >"$(dirname "$OUTPUT")/js-coverage.run.log" 2>&1 || true ;;
	esac
elif [ -z "$COV_SCRIPT" ]; then
	log_warn "js-coverage: no 'test:coverage' or 'coverage' script in package.json; relying on a pre-existing $SUMMARY if present."
fi

if [ ! -s "$SUMMARY" ]; then
	log_warn "js-coverage: no coverage summary at '$SUMMARY' (coverage did not run or emits a different reporter). Leaving '$OUTPUT' absent (tool 'unavailable'). Configure the 'json-summary' Istanbul reporter. NOT writing a fake clean report."
	exit 0
fi

_err="$(dirname "$OUTPUT")/js-coverage.stderr.log"

set -- "$SUMMARY" \
	--line-min "$(qp_num quality.coverage.line_min 80)" \
	--branch-min "$(qp_num quality.coverage.branch_min 60)" \
	--method-min "$(qp_num quality.coverage.method_min 0)" \
	--class-min "$(qp_num quality.coverage.class_min 0)" \
	--fail-on-decrease "$(qp_bool quality.coverage.fail_on_decrease false)"
_baseline=$(qp_get quality.coverage.baseline_file)
[ -n "$_baseline" ] && set -- "$@" --baseline "$_baseline"
set -- "$@" --output "$OUTPUT"

if node "$ADAPTER" "$@" 2>>"$_err" && jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "js-coverage: wrote $OUTPUT."
	rm -f "$_err" 2>/dev/null || true
	exit 0
fi

rm -f "$OUTPUT" 2>/dev/null || true
log_warn "js-coverage: adapter could not normalize '$SUMMARY'; leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_err."
exit 0
