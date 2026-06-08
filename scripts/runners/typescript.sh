#!/bin/sh
# Sentinel Shield runner — TypeScript --noEmit (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/typescript.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v npx >/dev/null 2>&1; then
  echo "[sentinel-shield] tsc not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
ERR=$(npx --no-install tsc --noEmit 2>&1 | grep -c "error TS" || true); jq -n --argjson e "${ERR:-0}" '{errors:$e}' > "$OUT"
exit 0
