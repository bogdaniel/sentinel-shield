#!/bin/sh
# Sentinel Shield audit wrapper — grype. Runs the tool if installed and writes
# reports/raw/grype.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
set -eu
OUT="${1:-reports/raw/grype.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v grype >/dev/null 2>&1; then
	echo "[sentinel-shield] grype not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	exit 0
fi
grype dir:. -o json --file "$OUT" || true
exit 0
