#!/bin/sh
# Sentinel Shield runner — TypeScript --noEmit (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/typescript.json}"
mkdir -p "$(dirname "$OUT")"
rm -f -- "$OUT"   # never leave a stale report as evidence for this run
if ! command -v npx >/dev/null 2>&1; then
  echo "[sentinel-shield] tsc not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
TSC_RC=0
TSC_OUT=$(npx --no-install tsc --noEmit 2>&1) || TSC_RC=$?
if [ "$TSC_RC" -ne 0 ] && ! printf '%s\n' "$TSC_OUT" | grep -q "error TS"; then
  # tsc itself failed to run (missing install, crash) — report unavailable, never a fake clean pass
  echo "[sentinel-shield] tsc failed to run (rc=$TSC_RC); skipping (collector reports unavailable)." >&2
  exit 0
fi
ERR=$(printf '%s\n' "$TSC_OUT" | grep -c "error TS" || true); jq -n --argjson e "${ERR:-0}" '{errors:$e}' > "$OUT"
exit 0
