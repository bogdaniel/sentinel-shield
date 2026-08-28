#!/bin/sh
# Sentinel Shield audit wrapper — Terrascan IaC policy (#102).
#
# Terrascan's confusing case is the UNSUPPORTED PROVIDER: pointed at a tree with no recognised IaC,
# it exits non-zero having evaluated nothing. The stub reported that identically to a clean scan.
# Applicability is now explicit — nothing to scan is not-applicable, never a pass.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/terrascan.json}"
st_begin terrascan "$OUT" || exit 1
ST_TARGET="${SENTINEL_SHIELD_TERRASCAN_TARGET:-.}"
ST_TARGET_MODE="iac-directory"

command_exists terrascan || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'terrascan' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v terrascan)
ST_VERSION=$(st_probe_version terrascan version)

st_execute scanner-run terrascan scan -o json -d "$ST_TARGET"
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "terrascan exceeded its bounded runtime"; exit 0; }
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "terrascan produced no report on stdout"; exit 0; }
# 0 = no violations, 3 = violations found. 1/4/5 are parser, configuration or internal failures.
case "$ST_EXIT" in
0|3) : ;;
*)   st_fail "$ST_STATE_ERROR" "terrascan exited $ST_EXIT — parser, configuration or internal failure"; exit 0 ;;
esac
sc_terrascan_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "terrascan report rejected: ${SC_REASON:-unknown}"; exit 0; }

# Applicability: a scan summary that examined no file evaluated nothing, whatever the exit said.
_ts_scanned=$(jq -r '(.results.scan_summary["file/folder"] // "") | tostring' "$(st_report_path)" 2>/dev/null) || _ts_scanned=""
[ -n "$_ts_scanned" ] || { st_fail "$ST_STATE_NOTAPPLICABLE" "no IaC target was evaluated — unsupported provider or empty tree"; exit 0; }
if [ "$ST_EXIT" = "3" ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
