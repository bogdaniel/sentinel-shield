#!/bin/sh
# Sentinel Shield audit wrapper — Syft SBOM (#96).
#
# WAS: `syft dir:. -o spdx-json="$OUT" || true; exit 0` — twelve lines that could not tell a
# produced SBOM from a crashed run, left any previous SBOM standing as current evidence, and
# exited 0 either way. A missing binary and a successful scan were indistinguishable downstream.
#
# NOW: one scanner evidence transaction. Stale output is quarantined BEFORE execution, the run is
# bounded and its exit captured exactly, the document is validated as a real SBOM (not merely as
# JSON), and report plus provenance are published together or not at all.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/sbom.spdx.json}"
st_begin syft "$OUT" || exit 1

ST_TARGET_MODE="dir"
ST_TARGET="${SENTINEL_SHIELD_SYFT_TARGET:-.}"

if ! command -v syft >/dev/null 2>&1; then
	# UNAVAILABLE, not clean. st_begin already removed any stale SBOM, so nothing survives to be
	# mistaken for this run — the first acceptance criterion of #96.
	st_fail "$ST_STATE_UNAVAILABLE" "no local 'syft' binary"
	exit 0
fi
ST_EXECUTOR="local-binary"
ST_BINPATH=$(command -v syft)
ST_VERSION=$(syft --version 2>/dev/null | awk '{print $NF; exit}') || ST_VERSION=""

st_execute scanner-run syft "scan" "dir:$ST_TARGET" -o "spdx-json=$(st_report_path)"

case "$ST_EXIT" in
timeout) st_fail "$ST_STATE_TIMEOUT" "syft exceeded its bounded runtime"; exit 0 ;;
0)       : ;;
*)       st_fail "$ST_STATE_ERROR" "syft exited $ST_EXIT without a verified complete SBOM"; exit 0 ;;
esac

if ! sc_syft_validate "$(st_report_path)"; then
	st_fail "$ST_STATE_ERROR" "SBOM rejected: ${SC_REASON:-unknown}"
	exit 0
fi
# A zero-package SBOM is a legitimate completed scan, not an error: it is published as clean,
# with the document metadata that proves it was produced by a real run (#135).
if [ "${SC_COUNT:-0}" -gt 0 ]; then st_publish "$ST_STATE_CLEAN"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
