#!/bin/sh
# Sentinel Shield runner — Pint / PHP-CS-Fixer style (v0.1.14). Runs the tool if available, writes the raw report;
# if absent it does NOT fake (logs unavailable, exits 0 -> collector reports unavailable).
set -eu
OUT="${1:-reports/raw/php-style.json}"
mkdir -p "$(dirname "$OUT")"
if ! { [ -x vendor/bin/pint ] || [ -x vendor/bin/php-cs-fixer ]; }; then
  echo "[sentinel-shield] pint/php-cs-fixer not available; skipping (collector reports unavailable)." >&2
  exit 0
fi
if [ -x vendor/bin/pint ]; then vendor/bin/pint --test --format=json > "$OUT" 2>/dev/null || vendor/bin/pint --test > "$OUT.txt" 2>&1 || true; else vendor/bin/php-cs-fixer fix --dry-run --format=json > "$OUT" 2>/dev/null || true; fi
exit 0
