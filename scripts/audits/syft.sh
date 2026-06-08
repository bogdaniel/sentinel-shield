#!/bin/sh
# Sentinel Shield audit wrapper — Syft SBOM (SPDX JSON) (v0.1.14). Runs the tool if installed, else reports
# unavailable (no fake). Prefer the pinned GitHub Action in CI (see templates/workflows/).
set -eu
OUT="${1:-reports/sbom.spdx.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v syft >/dev/null 2>&1; then
  echo "[sentinel-shield] syft not installed; skipping (collector reports unavailable)." >&2
  exit 0
fi
syft dir:. -o spdx-json="$OUT" || true
exit 0
