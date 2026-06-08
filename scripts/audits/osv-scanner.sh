#!/bin/sh
# Sentinel Shield audit wrapper — osv-scanner. Runs the tool if installed and writes
# reports/raw/osv-scanner.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
set -eu
OUT="${1:-reports/raw/osv-scanner.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v osv-scanner >/dev/null 2>&1; then
	echo "[sentinel-shield] osv-scanner not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	exit 0
fi
osv-scanner --format json --output "$OUT" -r . || true
exit 0
