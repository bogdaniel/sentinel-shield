#!/bin/sh
# Sentinel Shield audit wrapper — Trivy image scan (v0.1.14). Runs the tool if installed, else reports
# unavailable (no fake). Prefer the pinned GitHub Action in CI (see templates/workflows/).
set -eu
OUT="${1:-reports/raw/trivy.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v trivy >/dev/null 2>&1; then
  echo "[sentinel-shield] trivy not installed; skipping (collector reports unavailable)." >&2
  exit 0
fi
trivy image --format json --output "$OUT" --severity CRITICAL,HIGH,MEDIUM "${SENTINEL_SHIELD_IMAGE:?set SENTINEL_SHIELD_IMAGE to the built image ref}" || true
exit 0
