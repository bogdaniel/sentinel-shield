#!/bin/sh
# Sentinel Shield runner — PHP syntax check (php -l). Writes reports/raw/php-syntax.json
# {errors:N, files:[bad...]}. Safe when php is missing (logs unavailable, exits 0 — no fake).
set -eu
OUT="${1:-reports/raw/php-syntax.json}"
mkdir -p "$(dirname "$OUT")"
if ! command -v php >/dev/null 2>&1; then
	echo "[sentinel-shield] php not installed; skipping php-syntax (collector reports unavailable)." >&2
	exit 0
fi
ERRORS=0; BAD=""
for f in $(find app src Modules routes config database -name '*.php' 2>/dev/null); do
	if ! php -l "$f" >/dev/null 2>&1; then ERRORS=$((ERRORS+1)); BAD="$BAD$f
"; fi
done
printf '%s' "$BAD" | jq -R -s --argjson e "$ERRORS" 'split("\n")|map(select(length>0)) as $f | {errors:$e, files:$f}' > "$OUT"
echo "[sentinel-shield] php-syntax: $ERRORS error(s) -> $OUT" >&2
exit 0
