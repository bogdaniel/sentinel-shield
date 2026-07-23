#!/bin/sh
# Sentinel Shield runner — Playwright (ATDD acceptance-evidence producer, v2.2.0).
#
# Playwright is ONE producer of the normalized acceptance-tests contract. Passing acceptance
# tests are evidence that declared acceptance criteria still hold in a browser — they are NOT
# product-owner acceptance, and Sentinel Shield never claims to replace it
# (docs/acceptance-test-evidence.md).
#
# Honest statuses (never a faked clean run):
#   ATDD disabled in policy      -> "disabled"
#   no node_modules/.bin binary  -> "unavailable"
#   no playwright config         -> "not-configured"
#   ran, no valid report         -> "execution-error"
#   ran                          -> normalized acceptance-tests contract via the JSON adapter
#
# Browser acceptance suites are slow: profiles schedule this on main/scheduled by default, not
# on every PR (docs/profile-tool-policy.md).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/playwright-acceptance.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
CONFIG=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: playwright.sh [--output <path>] [--policy <path>] [--config <path>]
Run Playwright and write the normalized acceptance-tests report. Emits an honest unavailable /
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
	td_write_status "$OUT" "acceptance-tests" "playwright" "$1" "$2" '{"missing_acceptance_evidence":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.atdd.enabled false)" != "true" ]; then
	write_status "disabled" "ATDD evidence disabled in $POLICY (testing_discipline.atdd.enabled=false)"
fi

[ -x node_modules/.bin/playwright ] \
	|| write_status "unavailable" "playwright not found (node_modules/.bin/playwright)"

if [ -n "$CONFIG" ]; then
	[ -f "$CONFIG" ] || write_status "not-configured" "configured playwright config not found: $CONFIG"
else
	for _c in playwright.config.ts playwright.config.js playwright.config.mjs playwright.config.cjs; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	[ -n "$CONFIG" ] || write_status "not-configured" "no playwright config found (playwright.config.{ts,js,mjs,cjs})"
fi

PM=$(td_pkg_manager)
EXEC=$(td_pkg_exec "$PM")
TMP="$OUT.playwright.json"
# Playwright exits non-zero when tests FAIL — that is evidence, not an error.
# shellcheck disable=SC2086  # EXEC is an intentional multi-word command prefix
PLAYWRIGHT_JSON_OUTPUT_NAME="$TMP" $EXEC playwright test --config "$CONFIG" --reporter=json >/dev/null 2>&1 || true

if [ ! -f "$TMP" ] || [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "playwright ran but produced no valid JSON report"
fi

command_exists node || { rm -f "$TMP"; write_status "execution-error" "node not found; cannot convert the Playwright report"; }
if ! node "$SCRIPT_DIR/../adapters/playwright-json-to-acceptance-tests.mjs" "$TMP" "$OUT" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "could not convert the Playwright report to the acceptance-tests contract"
fi
rm -f "$TMP"

log_info "playwright: acceptance-tests report written to $OUT (config=$CONFIG, pm=$PM)"
exit 0
