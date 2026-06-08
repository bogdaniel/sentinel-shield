#!/bin/sh
# Sentinel Shield runner — ESLint (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/eslint.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v npx >/dev/null 2>&1; then
  echo "[sentinel-shield] eslint not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
npx --no-install eslint . -f json -o "$OUT" 2>/dev/null || true
exit 0
