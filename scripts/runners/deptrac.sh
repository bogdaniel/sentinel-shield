#!/bin/sh
# Sentinel Shield runner — Deptrac architecture (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/deptrac.json}"
mkdir -p "$(dirname "$OUT")"
if ! [ -x vendor/bin/deptrac ]; then
  echo "[sentinel-shield] deptrac not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
vendor/bin/deptrac analyse --formatter=json --output="$OUT" 2>/dev/null || true
exit 0
