#!/bin/sh
# Sentinel Shield runner — actionlint (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/actionlint.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v actionlint >/dev/null 2>&1; then
  echo "[sentinel-shield] actionlint not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
actionlint -format "{{json .}}" .github/workflows/*.yml > "$OUT" 2>/dev/null || true
exit 0
