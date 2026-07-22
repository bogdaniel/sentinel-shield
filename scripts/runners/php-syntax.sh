#!/bin/sh
# Sentinel Shield runner — PHP syntax check (php -l). Writes reports/raw/php-syntax.json
# {errors:N, files:[bad...]}. Absent php -> report left ABSENT (collector reports 'unavailable'),
# never a fake clean report.
#
# Usage: php-syntax.sh [--output <path>]   (bare positional path also accepted, back-compat)
# Exit:  0 ran or honest unavailable; 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/php-syntax.json"
while [ $# -gt 0 ]; do case "$1" in
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	-h | --help) printf 'Usage: php-syntax.sh [--output <path>]\n'; exit 0 ;;
	--*) log_error "php-syntax: unknown argument: $1"; exit 2 ;;
	*) OUTPUT="$1"; shift ;;
esac; done

ensure_dir "$(dirname "$OUTPUT")"
rm -f -- "$OUTPUT" 2>/dev/null || true
command_exists jq || { log_error "php-syntax: jq is required."; exit 2; }

if ! command_exists php; then
	log_warn "php-syntax: php not installed; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

# Only scan dirs that exist: `find` errors (non-zero) on a missing operand, which under set -e
# would abort the whole runner — most repos lack some of these dirs.
_dirs=""
for _d in app src Modules routes config database; do [ -d "$_d" ] && _dirs="$_dirs $_d"; done
if [ -z "$_dirs" ]; then
	log_warn "php-syntax: no PHP source dirs (app/src/Modules/routes/config/database); leaving '$OUTPUT' absent (not applicable)."
	exit 0
fi
# -exec per file (no word-splitting): a path with spaces stays one argument, so php -l is not
# run on filename fragments (which inflated php_syntax_errors with false positives).
# shellcheck disable=SC2086
BAD=$(find $_dirs -name '*.php' 2>/dev/null \
	-exec sh -c 'php -l "$1" >/dev/null 2>&1 || printf "%s\n" "$1"' _ {} \; || true)
ERRORS=$(printf '%s' "$BAD" | grep -c . || true)
printf '%s' "$BAD" | jq -R -s --argjson e "${ERRORS:-0}" 'split("\n")|map(select(length>0)) as $f | {errors:$e, files:$f}' > "$OUTPUT"
log_info "php-syntax: $ERRORS error(s) -> $OUTPUT."
exit 0
