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
# -exec per file (no word-splitting): a path with spaces stays one argument, so php -l
# is not run on filename fragments (which inflated php_syntax_errors with false positives).
BAD=$(find app src Modules routes config database -name '*.php' 2>/dev/null \
	-exec sh -c 'php -l "$1" >/dev/null 2>&1 || printf "%s\n" "$1"' _ {} \;)
ERRORS=$(printf '%s' "$BAD" | grep -c . || true)
printf '%s' "$BAD" | jq -R -s --argjson e "${ERRORS:-0}" 'split("\n")|map(select(length>0)) as $f | {errors:$e, files:$f}' > "$OUT"
echo "[sentinel-shield] php-syntax: $ERRORS error(s) -> $OUT" >&2
exit 0
