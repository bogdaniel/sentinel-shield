#!/bin/sh
# Sentinel Shield audit wrapper — Trivy filesystem scan (v0.1.14). Runs the tool if installed, else reports
# unavailable (no fake). Prefer the pinned GitHub Action in CI (see templates/workflows/).
set -eu
OUT="${1:-reports/raw/trivy.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v trivy >/dev/null 2>&1; then
  echo "[sentinel-shield] trivy not installed; skipping (collector reports unavailable)." >&2
  exit 0
fi
trivy fs --format json --output "$OUT" --severity CRITICAL,HIGH,MEDIUM . || true
exit 0
