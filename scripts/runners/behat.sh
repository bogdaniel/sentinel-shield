#!/bin/sh
# Sentinel Shield runner — Behat (PHP BDD behavior-spec producer, v2.2.0).
#
# Behat is ONE producer of the normalized behavior-specs contract, not the whole capability.
# It executes Gherkin scenarios; it does not judge whether those scenarios describe the right
# behavior. Sentinel Shield does not guarantee BDD quality (docs/bdd-atdd-evidence.md).
#
# Honest statuses (never a faked clean run):
#   BDD disabled in policy         -> "disabled"
#   binary absent                  -> "unavailable"
#   binary present, no behat.yml   -> "not-configured"
#   ran, no valid report           -> "execution-error"
#   ran                            -> normalized behavior-specs contract via the JUnit adapter
#
# Binary detection order: vendor/bin/behat, then a global `behat` on PATH.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/behat-specs.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
CONFIG=""
SUITE=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: behat.sh [--output <path>] [--config <path>] [--policy <path>] [--suite <name>]
Run Behat and write the normalized behavior-specs report. Emits an honest unavailable /
not-configured / execution-error report instead of a faked clean result.
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
	td_write_status "$OUT" "behavior-specs" "behat" "$1" "$2" '{"missing_behavior_specification":true}'
	exit 0
}

td_load "$POLICY"
if td_present && ! td_enabled; then
	write_status "disabled" "testing discipline governance disabled in $POLICY"
fi
if td_present && [ "$(td_bool testing_discipline.bdd.enabled false)" != "true" ]; then
	write_status "disabled" "BDD evidence disabled in $POLICY (testing_discipline.bdd.enabled=false)"
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

TMPDIR_JUNIT=$(mktemp -d 2>/dev/null || mktemp -d -t ssbehat)
# Behat exits non-zero when scenarios FAIL — that is evidence, not an error. Only the absence
# of a readable report makes this an execution-error.
set -- --config "$CONFIG" --format junit --out "$TMPDIR_JUNIT"
[ -n "$SUITE" ] && set -- "$@" --suite "$SUITE"
"$BIN" "$@" >/dev/null 2>&1 || true

JUNIT=$(find "$TMPDIR_JUNIT" -name '*.xml' -type f 2>/dev/null | head -n1 || true)
if [ -z "$JUNIT" ] || [ ! -s "$JUNIT" ]; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "behat ran but produced no JUnit report"
fi

command_exists php || { rm -rf -- "$TMPDIR_JUNIT"; write_status "execution-error" "php not found; cannot convert the Behat JUnit report"; }
if ! php "$SCRIPT_DIR/../adapters/behat-junit-to-behavior-specs.php" "$JUNIT" "$OUT" >/dev/null 2>&1; then
	rm -rf -- "$TMPDIR_JUNIT"
	write_status "execution-error" "could not convert the Behat JUnit report to the behavior-specs contract"
fi
rm -rf -- "$TMPDIR_JUNIT"

log_info "behat: behavior-specs report written to $OUT (config=$CONFIG)"
exit 0
