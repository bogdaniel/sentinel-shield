#!/bin/sh
# Sentinel Shield runner — Psalm static analysis (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/psalm.json}"
mkdir -p "$(dirname "$OUT")"
if ! [ -x vendor/bin/psalm ]; then
  echo "[sentinel-shield] psalm not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
vendor/bin/psalm --output-format=json > "$OUT" 2>/dev/null || true
exit 0
