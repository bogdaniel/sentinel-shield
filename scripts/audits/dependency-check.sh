#!/bin/sh
# Sentinel Shield audit wrapper — dependency-check. Runs the tool if installed and writes
# reports/raw/dependency-check.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
set -eu
OUT="${1:-reports/raw/dependency-check.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v dependency-check >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	exit 0
fi
dependency-check --scan . --format JSON --out "$OUT" || true
exit 0
