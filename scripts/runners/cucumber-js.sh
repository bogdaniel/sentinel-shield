#!/bin/sh
# Sentinel Shield runner — Cucumber.js (JS/TS BDD behavior-spec producer, v2.2.0).
#
# Cucumber.js is ONE producer of the normalized behavior-specs contract. It executes Gherkin
# scenarios; it does not judge whether those scenarios describe the right behavior
# (docs/bdd-atdd-evidence.md).
#
# Honest statuses (never a faked clean run):
#   BDD disabled in policy       -> "disabled"
#   no node_modules/.bin binary  -> "unavailable"
#   no feature directory         -> "not-configured"
#   ran, no valid report         -> "execution-error"
#   ran                          -> normalized behavior-specs contract via the JSON adapter
#
# Package manager (npm / pnpm / yarn) is detected from the lockfile — never forces npx on a
# pnpm/yarn project.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/cucumber-specs.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
SPEC_DIR=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: cucumber-js.sh [--output <path>] [--policy <path>] [--spec-dir <path>]
Run Cucumber.js and write the normalized behavior-specs report. Emits an honest unavailable /
not-configured / execution-error report instead of a faked clean result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--spec-dir) SPEC_DIR="${2:?--spec-dir requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_require_jq
ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> — honest non-evidence report, then exit 0.
write_status() {
	td_write_status "$OUT" "behavior-specs" "cucumber-js" "$1" "$2" '{"missing_behavior_specification":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.bdd.enabled false)" != "true" ]; then
	write_status "disabled" "BDD evidence disabled in $POLICY (testing_discipline.bdd.enabled=false)"
fi

[ -x node_modules/.bin/cucumber-js ] \
	|| write_status "unavailable" "cucumber-js not found (node_modules/.bin/cucumber-js)"

# Spec directory: explicit, then the policy's spec_paths, then the conventional `features/`.
if [ -z "$SPEC_DIR" ]; then
	for _d in $(td_list testing_discipline.bdd.spec_paths) features; do
		if [ -d "$_d" ]; then SPEC_DIR="$_d"; break; fi
	done
fi
[ -n "$SPEC_DIR" ] && [ -d "$SPEC_DIR" ] \
	|| write_status "not-configured" "no BDD feature directory found (checked testing_discipline.bdd.spec_paths and features/)"

PM=$(td_pkg_manager)
EXEC=$(td_pkg_exec "$PM")
TMP="$OUT.cucumber.json"
# Cucumber exits non-zero when scenarios FAIL — that is evidence, not an error.
# shellcheck disable=SC2086  # EXEC is an intentional multi-word command prefix
$EXEC cucumber-js "$SPEC_DIR" --format json:"$TMP" >/dev/null 2>&1 || true

if [ ! -f "$TMP" ] || [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "cucumber-js ran but produced no valid JSON report"
fi

command_exists node || { rm -f "$TMP"; write_status "execution-error" "node not found; cannot convert the Cucumber report"; }
if ! node "$SCRIPT_DIR/../adapters/cucumber-json-to-behavior-specs.mjs" "$TMP" "$OUT" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "could not convert the Cucumber report to the behavior-specs contract"
fi
rm -f "$TMP"

log_info "cucumber-js: behavior-specs report written to $OUT (specs=$SPEC_DIR, pm=$PM)"
exit 0
