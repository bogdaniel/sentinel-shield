#!/bin/sh
# Sentinel Shield runner — zizmor (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/zizmor.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v zizmor >/dev/null 2>&1; then
  echo "[sentinel-shield] zizmor not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
zizmor --format json .github/workflows > "$OUT" 2>/dev/null || true
exit 0
