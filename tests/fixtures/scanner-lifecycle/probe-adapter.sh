#!/bin/sh
# FIXTURE for tests/prod/308 — a MINIMAL adapter that exercises the shared lifecycle directly.
#
# It stands in for the ten real adapters so Layer 1 can prove the mechanics once, without any
# tool's semantics in the way. Behaviour is chosen by SS_PROBE_MODE; the validator is
# deliberately trivial and explicit, so a rejection here is a LIFECYCLE rejection, never a
# disagreement about a report shape.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="${SS_PROBE_LIB:-$SCRIPT_DIR/../../../scripts/lib}"
# shellcheck source=/dev/null
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=/dev/null
. "$SS_LIB_DIR/scanner-transaction.sh"

OUT="${1:?probe-adapter: output path required}"
st_begin probe "$OUT" || exit 1
ST_TARGET="probe-target"; ST_TARGET_MODE="probe"; ST_EXECUTOR="fake"; ST_VERSION="9.9.9"

case "${SS_PROBE_MODE:-clean}" in
missing-binary) st_fail "$ST_STATE_UNAVAILABLE" "no probe binary"; exit 0 ;;
esac

command -v ss-probe-tool >/dev/null 2>&1 || { st_fail "$ST_STATE_UNAVAILABLE" "no ss-probe-tool on PATH"; exit 0 ;}
st_execute scanner-run ss-probe-tool
case "$ST_EXIT" in
timeout) st_fail "$ST_STATE_TIMEOUT" "probe exceeded its bounded runtime"; exit 0 ;;
0)       : ;;
*)       st_fail "$ST_STATE_ERROR" "probe exited $ST_EXIT"; exit 0 ;;
esac
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "probe produced no report"; exit 0; }

# The tool-specific contract, made explicit and minimal: a report must be an object carrying
# .probe_ok. Anything else is a validator rejection.
if ! jq -e 'type == "object" and has("probe_ok")' "$(st_report_path)" >/dev/null 2>&1; then
	st_fail "$ST_STATE_ERROR" "probe report failed validation"
	exit 0
fi
case "${SS_PROBE_PUBLISH_AS:-clean}" in
findings)   st_publish "$ST_STATE_FINDINGS" ;;
no-targets) st_publish "$ST_STATE_NOTARGETS" ;;
refuse)     st_publish "$ST_STATE_ERROR" ;;
*)          st_publish "$ST_STATE_CLEAN" ;;
esac
exit 0
