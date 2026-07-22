#!/bin/sh
# Sentinel Shield audit wrapper — osv-scanner. Runs the tool if installed and writes
# reports/raw/osv-scanner.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
#
# PROVENANCE (v2 hardening): alongside the raw report this wrapper writes a sidecar
# reports/raw/osv-scanner.provenance.json recording the resolved source / version /
# platform, so the collector can tell 'scanner did not run' (source=unresolved) from
# 'scanner ran, empty report'. Best-effort: skipped only if jq is unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/isolated-tools.sh
. "$SCRIPT_DIR/../lib/isolated-tools.sh"
# shellcheck source=scripts/lib/bounded-process.sh
. "$SCRIPT_DIR/../lib/bounded-process.sh"

BP_TMP_OUT=$(mktemp); BP_TMP_ERR=$(mktemp)
trap 'rm -f "$BP_TMP_OUT" "$BP_TMP_ERR"' EXIT INT TERM

OUT="${1:-reports/raw/osv-scanner.json}"
mkdir -p "$(dirname "$OUT")"
PROV="${OUT%.json}.provenance.json"
PLATFORM=$(isolated_tool_platform)

write_prov() { # write_prov <source> <version> <binpath>
	command_exists jq || { log_warn "osv-scanner: jq unavailable; provenance sidecar not written"; return 0; }
	isolated_tool_provenance_record "osv-scanner" "$1" "$2" "" "" "$3" "" "" "" "" "$PLATFORM" > "$PROV" \
		|| log_warn "osv-scanner: could not write provenance sidecar '$PROV'"
}

if ! command -v osv-scanner >/dev/null 2>&1; then
	echo "[sentinel-shield] osv-scanner not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	write_prov "unresolved" "" ""
	exit 0
fi
BINPATH=$(command -v osv-scanner)
# BOUNDED version probe (scripts/lib/bounded-process.sh): a hung binary cannot stall the
# wrapper. SENTINEL_SHIELD_OSV_SCANNER_TIMEOUT_SECONDS overrides the version-probe cap.
VTO=$(bp_timeout scanner-version SENTINEL_SHIELD_OSV_SCANNER_TIMEOUT_SECONDS) || VTO=30
if bp_run scanner-version "$VTO" "$BP_TMP_OUT" "$BP_TMP_ERR" -- osv-scanner --version; then
	VER=$(head -n1 "$BP_TMP_OUT" 2>/dev/null) || VER=""
else
	[ "${BP_STATUS:-}" = "timed-out" ] && log_warn "osv-scanner: version probe exceeded ${VTO}s; recording unknown version"
	VER=""
fi
write_prov "local-binary" "$VER" "$BINPATH"
# BOUNDED scan (not only the version probe): a wedged scan must not stall the wrapper.
STO=$(bp_timeout scanner-run SENTINEL_SHIELD_OSV_SCANNER_SCAN_TIMEOUT_SECONDS) || STO=900
bp_run scanner-run "$STO" "$BP_TMP_OUT" "$BP_TMP_ERR" -- osv-scanner --format json --output "$OUT" -r . || true
[ "${BP_STATUS:-}" = "timed-out" ] && log_warn "osv-scanner: scan exceeded ${STO}s; report may be absent (collector reports unavailable)"
exit 0
