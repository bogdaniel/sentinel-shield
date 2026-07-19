#!/bin/sh
# Sentinel Shield runner — Behat at ACCEPTANCE level (ATDD producer, v2.2.0).
#
# Same binary as scripts/runners/behat.sh, different CONTRACT: this run targets the acceptance
# suite and emits the normalized acceptance-tests report, so BDD scenario evidence and ATDD
# acceptance evidence stay two separate, independently-gated channels
# (docs/bdd-atdd-evidence.md, docs/acceptance-test-evidence.md).
#
# Honest statuses (never a faked clean run):
#   ATDD disabled in policy        -> "disabled"
#   binary absent                  -> "unavailable"
#   no config / no acceptance path -> "not-configured"
#   ran, no valid report           -> "execution-error"
#   ran                            -> normalized acceptance-tests contract via the JUnit adapter
#
# Suite selection order: --suite, then the first existing testing_discipline.atdd.acceptance_paths
# entry, then the conventional `acceptance` suite name.
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
SUITE=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: behat-acceptance.sh [--output <path>] [--config <path>] [--policy <path>] [--suite <name>]
Run the Behat ACCEPTANCE suite and write the normalized acceptance-tests report. Emits an
honest unavailable / not-configured / execution-error report instead of a faked clean result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--suite) SUITE="${2:?--suite requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_require_jq
ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> — honest non-evidence report, then exit 0.
write_status() {
	td_write_status "$OUT" "acceptance-tests" "behat-acceptance" "$1" "$2" '{"missing_acceptance_evidence":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.atdd.enabled false)" != "true" ]; then
	write_status "disabled" "ATDD evidence disabled in $POLICY (testing_discipline.atdd.enabled=false)"
fi

BIN=""
if [ -x vendor/bin/behat ]; then BIN="vendor/bin/behat"
elif command_exists behat; then BIN="behat"
fi
[ -n "$BIN" ] || write_status "unavailable" "behat binary not found (vendor/bin/behat or global behat)"

if [ -n "$CONFIG" ]; then
	[ -f "$CONFIG" ] || write_status "not-configured" "configured behat config not found: $CONFIG"
else
	for _c in behat.yml behat.yaml behat.yml.dist behat.yaml.dist; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	[ -n "$CONFIG" ] || write_status "not-configured" "no behat config found (behat.yml | behat.yaml | *.dist)"
fi

# Acceptance target: an explicit suite wins; otherwise use the first declared acceptance path
# that exists on disk; otherwise fall back to the conventional `acceptance` suite name.
ACCEPT_PATH=""
if [ -z "$SUITE" ]; then
	for _d in $(td_list testing_discipline.atdd.acceptance_paths) tests/Acceptance; do
		if [ -d "$_d" ]; then ACCEPT_PATH="$_d"; break; fi
	done
	[ -n "$ACCEPT_PATH" ] || SUITE="acceptance"
fi

TMPDIR_JUNIT=$(mktemp -d 2>/dev/null || mktemp -d -t ssbehatacc)
# Behat exits non-zero when scenarios FAIL — that is evidence, not an error.
set -- --config "$CONFIG" --format junit --out "$TMPDIR_JUNIT"
[ -n "$SUITE" ] && set -- "$@" --suite "$SUITE"
[ -n "$ACCEPT_PATH" ] && set -- "$@" "$ACCEPT_PATH"
"$BIN" "$@" >/dev/null 2>&1 || true

JUNIT=$(find "$TMPDIR_JUNIT" -name '*.xml' -type f 2>/dev/null | head -n1 || true)
if [ -z "$JUNIT" ] || [ ! -s "$JUNIT" ]; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "behat acceptance suite ran but produced no JUnit report"
fi

command_exists php || { rm -rf -- "$TMPDIR_JUNIT"; write_status "execution-error" "php not found; cannot convert the Behat JUnit report"; }
if ! php "$SCRIPT_DIR/../adapters/junit-to-acceptance-tests.php" "$JUNIT" "$OUT" >/dev/null 2>&1; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "could not convert the Behat JUnit report to the acceptance-tests contract"
fi
rm -rf -- "$TMPDIR_JUNIT"

log_info "behat-acceptance: acceptance-tests report written to $OUT (config=$CONFIG, suite=${SUITE:-<path>} ${ACCEPT_PATH})"
exit 0
