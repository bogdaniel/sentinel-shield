#!/bin/sh
# Sentinel Shield audit wrapper — Trivy filesystem scan (#99).
#
# Trivy signals findings through a non-zero exit when --exit-code is set, so the exit status alone
# cannot separate "vulnerabilities found" from "the vulnerability database could not be fetched" —
# and the second must never publish as a clean scan.
#
# The report decides: a real Trivy document carries SchemaVersion and Results, and a result-level
# error means the scan was PARTIAL. Database identity is recorded so a consumer can tell which
# data the verdict rests on.
#
# PATH NOTE: the output path is the one this producer already shipped. The repository currently
# carries two spellings for the filesystem report, and the canonical choice is made in one
# mechanical unification pass once every producer and consumer has been inventoried — not by
# editing paths piecemeal here.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/trivy.json}"
st_begin trivy-fs "$OUT" || exit 1
ST_TARGET="${SENTINEL_SHIELD_TRIVY_TARGET:-.}"
ST_TARGET_MODE="filesystem"

command_exists trivy || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'trivy' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v trivy)
ST_VERSION=$(trivy --version 2>/dev/null | awk 'NR==1{print $NF}') || ST_VERSION=""

st_execute scanner-run trivy fs --format json --output "$(st_report_path)" --exit-code 1 "$ST_TARGET"
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "trivy exceeded its bounded runtime"; exit 0; }
case "$ST_EXIT" in
0|1) : ;;
*)   st_fail "$ST_STATE_ERROR" "trivy exited $ST_EXIT — scanner, configuration or database failure, not findings"; exit 0 ;;
esac
sc_trivy_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "trivy report rejected: ${SC_REASON:-unknown}"; exit 0; }

# Database identity, recorded for gated evidence: a clean result is only as trustworthy as the
# data it was checked against.
ST_DB_ID=$(jq -r '(.Metadata.DB.UpdatedAt // .Metadata.DB.NextUpdate // "") | tostring' "$(st_report_path)" 2>/dev/null) || ST_DB_ID=""
if [ "$ST_EXIT" = "1" ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
