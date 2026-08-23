#!/bin/sh
# Sentinel Shield audit wrapper — OSV-Scanner dependency vulnerabilities (#105).
#
# `{"results":[]}` is emitted BOTH when nothing was scanned and when everything scanned was clean.
# The report alone cannot tell those apart, which is why this adapter records how many SOURCES were
# discovered and publishes no-targets rather than clean when that count is zero (#184 consumes it).
#
# PROVENANCE IS FINALIZED ONLY AFTER VALIDATION — the transaction guarantees it. Previously the
# sidecar could be written beside a report that had never been checked, so a failed scan could
# leave a fresh-looking provenance next to stale results.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/osv-scanner.json}"
st_begin osv-scanner "$OUT" || exit 1
ST_TARGET="${SENTINEL_SHIELD_OSV_TARGET:-.}"
ST_TARGET_MODE="recursive-lockfile-discovery"

command_exists osv-scanner || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'osv-scanner' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v osv-scanner)
ST_VERSION=$(osv-scanner --version 2>/dev/null | awk 'NR==1{print $NF}') || ST_VERSION=""

st_execute scanner-run osv-scanner --format json --recursive "$ST_TARGET"
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "osv-scanner exceeded its bounded runtime"; exit 0; }
case "$ST_EXIT" in
0|1) : ;;
*)   st_fail "$ST_STATE_ERROR" "osv-scanner exited $ST_EXIT — network, database, parser or internal failure"; exit 0 ;;
esac
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "osv-scanner produced no report on stdout"; exit 0; }
sc_osv_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "osv-scanner report rejected: ${SC_REASON:-unknown}"; exit 0; }

# DISCOVERY IS THE EVIDENCE. Zero sources means no lockfile was found: a truthful no-targets, not a
# clean bill of health. One or more sources with zero vulnerabilities is a genuine clean scan, and
# the two are published as different states.
if [ "${SC_SOURCES:-0}" -eq 0 ]; then
	st_publish "$ST_STATE_NOTARGETS"
elif [ "${SC_COUNT:-0}" -gt 0 ]; then
	st_publish "$ST_STATE_FINDINGS"
else
	st_publish "$ST_STATE_CLEAN"
fi
exit 0
