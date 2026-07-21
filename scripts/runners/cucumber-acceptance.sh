#!/bin/sh
# Sentinel Shield runner — Cucumber.js at ACCEPTANCE level (ATDD producer, v2.2.0).
#
# Same binary as scripts/runners/cucumber-js.sh, different CONTRACT: this run targets the
# acceptance feature tree and emits the normalized acceptance-tests report, so BDD scenario
# evidence and ATDD acceptance evidence stay two separate, independently-gated channels
# (docs/bdd-atdd-evidence.md, docs/acceptance-test-evidence.md).
#
# Honest statuses (never a faked clean run):
#   ATDD disabled in policy      -> "disabled"
#   no node_modules/.bin binary  -> "unavailable"
#   no acceptance feature path   -> "not-configured"
#   ran, no valid report         -> "execution-error"
#   ran                          -> normalized acceptance-tests contract
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/cucumber-acceptance.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
ACCEPT_PATH=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: cucumber-acceptance.sh [--output <path>] [--policy <path>] [--acceptance-dir <path>]
Run the Cucumber.js ACCEPTANCE features and write the normalized acceptance-tests report.
Emits an honest unavailable / not-configured / execution-error report instead of a faked clean
result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--acceptance-dir) ACCEPT_PATH="${2:?--acceptance-dir requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_require_jq
ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> — honest non-evidence report, then exit 0.
write_status() {
	td_write_status "$OUT" "acceptance-tests" "cucumber-acceptance" "$1" "$2" '{"missing_acceptance_evidence":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.atdd.enabled false)" != "true" ]; then
	write_status "disabled" "ATDD evidence disabled in $POLICY (testing_discipline.atdd.enabled=false)"
fi

[ -x node_modules/.bin/cucumber-js ] \
	|| write_status "unavailable" "cucumber-js not found (node_modules/.bin/cucumber-js)"

if [ -z "$ACCEPT_PATH" ]; then
	for _d in $(td_list testing_discipline.atdd.acceptance_paths) e2e features/acceptance; do
		if [ -d "$_d" ]; then ACCEPT_PATH="$_d"; break; fi
	done
fi
[ -n "$ACCEPT_PATH" ] && [ -d "$ACCEPT_PATH" ] \
	|| write_status "not-configured" "no acceptance feature directory found (checked testing_discipline.atdd.acceptance_paths, e2e/, features/acceptance/)"

PM=$(td_pkg_manager)
EXEC=$(td_pkg_exec "$PM")
TMP="$OUT.cucumber.json"
# Cucumber exits non-zero when scenarios FAIL — that is evidence, not an error.
# shellcheck disable=SC2086  # EXEC is an intentional multi-word command prefix
$EXEC cucumber-js "$ACCEPT_PATH" --format json:"$TMP" >/dev/null 2>&1 || true

if [ ! -f "$TMP" ] || [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "cucumber-js acceptance run produced no valid JSON report"
fi

# Cucumber's JSON is scenario-shaped; map it onto the acceptance contract here (tests =
# scenarios executed, failures = scenarios with a failed step) rather than inventing a third
# adapter for the same document.
if ! jq -e '
	def scenarios: [ .[]? | (.elements // [])[] | select((.type // "") != "background") ];
	{ tool:"acceptance-tests", producer:"cucumber-acceptance",
	  tests: (scenarios | length),
	  failures: ([ scenarios[]
	               | select(any((.steps // [])[];
	                   (.result.status // "") | IN("failed","undefined","pending","ambiguous"))) ] | length),
	  skipped: ([ scenarios[] | select(all((.steps // [])[]; (.result.status // "") == "skipped")) ] | length) }
	| . + { status: (if .failures > 0 then "findings" else "pass" end),
	        missing_acceptance_evidence: (.tests == 0) }' "$TMP" > "$OUT" 2>/dev/null; then
	rm -f "$TMP"
	write_status "execution-error" "could not convert the Cucumber acceptance report to the acceptance-tests contract"
fi
rm -f "$TMP"

log_info "cucumber-acceptance: acceptance-tests report written to $OUT (path=$ACCEPT_PATH, pm=$PM)"
exit 0
