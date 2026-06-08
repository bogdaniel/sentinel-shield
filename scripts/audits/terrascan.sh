#!/bin/sh
# Sentinel Shield audit wrapper — terrascan. Runs the tool if installed and writes
# reports/raw/terrascan.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
set -eu
OUT="${1:-reports/raw/terrascan.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v terrascan >/dev/null 2>&1; then
	echo "[sentinel-shield] terrascan not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	exit 0
fi
terrascan scan -o json > "$OUT" 2>/dev/null || true
exit 0
