#!/bin/sh
# Sentinel Shield runner — Cypress (ATDD acceptance-evidence producer, v2.2.0).
#
# Cypress is ONE producer of the normalized acceptance-tests contract. Passing acceptance tests
# are evidence that declared acceptance criteria still hold in a browser — they are NOT
# product-owner acceptance (docs/acceptance-test-evidence.md).
#
# Honest statuses (never a faked clean run):
#   ATDD disabled in policy      -> "disabled"
#   no node_modules/.bin binary  -> "unavailable"
#   no cypress config            -> "not-configured"
#   ran, no valid report         -> "execution-error"
#   ran                          -> normalized acceptance-tests contract via the JUnit adapter
#
# Cypress is driven with the JUnit reporter (not its own JSON) because JUnit is the shape both
# the PHP and JS acceptance adapters already understand.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/acceptance-tests.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
CONFIG=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: cypress.sh [--output <path>] [--policy <path>] [--config <path>]
Run Cypress and write the normalized acceptance-tests report. Emits an honest unavailable /
not-configured / execution-error report instead of a faked clean result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_require_jq
ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> — honest non-evidence report, then exit 0.
write_status() {
	td_write_status "$OUT" "acceptance-tests" "cypress" "$1" "$2" '{"missing_acceptance_evidence":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.atdd.enabled false)" != "true" ]; then
	write_status "disabled" "ATDD evidence disabled in $POLICY (testing_discipline.atdd.enabled=false)"
fi

[ -x node_modules/.bin/cypress ] \
	|| write_status "unavailable" "cypress not found (node_modules/.bin/cypress)"

if [ -n "$CONFIG" ]; then
	[ -f "$CONFIG" ] || write_status "not-configured" "configured cypress config not found: $CONFIG"
else
	for _c in cypress.config.ts cypress.config.js cypress.config.mjs cypress.json; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	[ -n "$CONFIG" ] || write_status "not-configured" "no cypress config found (cypress.config.{ts,js,mjs} | cypress.json)"
fi

PM=$(td_pkg_manager)
EXEC=$(td_pkg_exec "$PM")
TMPDIR_JUNIT=$(mktemp -d 2>/dev/null || mktemp -d -t sscypress)
# Cypress exits non-zero when tests FAIL — that is evidence, not an error.
# shellcheck disable=SC2086  # EXEC is an intentional multi-word command prefix
$EXEC cypress run --config-file "$CONFIG" --reporter junit \
	--reporter-options "mochaFile=$TMPDIR_JUNIT/results-[hash].xml,toConsole=false" >/dev/null 2>&1 || true

JUNIT=$(find "$TMPDIR_JUNIT" -name '*.xml' -type f 2>/dev/null | head -n1 || true)
if [ -z "$JUNIT" ] || [ ! -s "$JUNIT" ]; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "cypress ran but produced no JUnit report"
fi

command_exists node || { rm -rf -- "$TMPDIR_JUNIT"; write_status "execution-error" "node not found; cannot convert the Cypress JUnit report"; }
if ! node "$SCRIPT_DIR/../adapters/junit-to-acceptance-tests.mjs" "$JUNIT" "$OUT" >/dev/null 2>&1; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "could not convert the Cypress JUnit report to the acceptance-tests contract"
fi
rm -rf -- "$TMPDIR_JUNIT"

log_info "cypress: acceptance-tests report written to $OUT (config=$CONFIG, pm=$PM)"
exit 0
