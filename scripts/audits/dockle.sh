#!/bin/sh
# Sentinel Shield audit wrapper — dockle. Runs the tool if installed and writes
# reports/raw/dockle.json; if the binary is absent it does NOT fake a report (logs
# 'unavailable' and exits 0; the collector then reports status=unavailable).
# Many of these are better run via a pinned GitHub Action — see templates/workflows/.
set -eu
OUT="${1:-reports/raw/dockle.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v dockle >/dev/null 2>&1; then
	echo "[sentinel-shield] dockle not installed; skipping (collector will report unavailable). Prefer the pinned GitHub Action in CI." >&2
	exit 0
fi
dockle -f json -o "$OUT" "${SENTINEL_SHIELD_IMAGE:?set SENTINEL_SHIELD_IMAGE to the built image ref}" || true
exit 0
