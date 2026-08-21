#!/bin/sh
# Sentinel Shield audit wrapper — Checkov IaC (#97).
#
# Checkov signals FINDINGS through a non-zero exit, so exit status alone cannot separate
# "misconfigurations found" from "the parser failed" or "the config file was invalid". The report
# shape decides: both documented shapes (a single object, or a list of per-framework objects) are
# accepted explicitly, and anything else is rejected rather than guessed at.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/checkov.json}"
st_begin checkov "$OUT" || exit 1
ST_TARGET_MODE="directory"
ST_TARGET="${SENTINEL_SHIELD_CHECKOV_TARGET:-.}"

command -v checkov >/dev/null 2>&1 || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'checkov' binary"; exit 0; }
ST_EXECUTOR="local-binary"
ST_BINPATH=$(command -v checkov)
ST_VERSION=$(checkov --version 2>/dev/null | head -1) || ST_VERSION=""

st_execute scanner-run checkov -d "$ST_TARGET" -o json --quiet
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "checkov exceeded its bounded runtime"; exit 0; }
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "checkov produced no report on stdout"; exit 0; }

# Checkov's own vocabulary: 0 = no findings, 1 = findings. Anything else is operational.
case "$ST_EXIT" in
0|1) : ;;
*)   st_fail "$ST_STATE_ERROR" "checkov exited $ST_EXIT — operational or configuration failure, not findings"; exit 0 ;;
esac
sc_checkov_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "checkov report rejected: ${SC_REASON:-unknown}"; exit 0; }
if [ "$ST_EXIT" = "1" ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
