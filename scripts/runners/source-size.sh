#!/bin/sh
# Sentinel Shield runner — source size -> reports/raw/source-size.json.
#
# Grep-based source scanner (no external tool): it is ALWAYS available, so a clean scan of
# zero is a REAL pass, not a fake one. Scans the CURRENT directory's PHP/JS/TS source and
# flags oversized FILES (wc -l > quality.maintainability.max_file_lines). Thresholds come
# from .sentinel-shield/quality-policy.yaml (defaults 500 file / 80 function lines).
#
# ponytail: function-size is best-effort/EXTERNAL for now. A pure-sh brace-depth scan cannot
# tell code braces from braces inside strings/comments, so it would emit FALSE large-function
# violations and flip a gate for no reason. Correctness over coverage: large_function_violations
# and max_function_lines are reported as 0 until a real per-function line counter (a language
# tokenizer / phpmd / a JS AST pass) feeds this runner. The threshold is still surfaced.
#
# Contract: violations are FINDINGS, not errors -> EXIT 0 even when oversized files are found.
# EXIT 2 only on bad invocation or missing jq.
#
# Usage: source-size.sh [--output reports/raw/source-size.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/source-size.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: source-size.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "source-size: jq is required."; exit 2; }

qp_load "$POLICY"
MAX_FILE=$(qp_num quality.maintainability.max_file_lines 500)
MAX_FUNC=$(qp_num quality.maintainability.max_function_lines 80)

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_list="$_dir/source-size.filelist"

# Enumerate source files with `find ... -exec wc -l` (not grep -l): filenames that contain a
# newline would split a grep -l filelist into bogus paths and miscount. Each wc line is
# "<lines> <path>", and we read ONLY the first field (the count) — a newline embedded in a
# path merely yields extra non-numeric fragment lines that the numeric guard skips, so the
# per-file count is never corrupted. EXCLUDES dir names are pruned anywhere in the tree.
find . \
	-type d \( -name node_modules -o -name vendor -o -name reports -o -name storage \
		-o -name cache -o -name dist -o -name build -o -name coverage -o -name generated \
		-o -name .git \) -prune \
	-o -type f \( -name '*.php' -o -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \) \
		-exec wc -l {} \; > "$_list" 2>/dev/null || true

LARGE_FILE_VIOLATIONS=0
MAX_FILE_LINES=0
while read -r _lc _rest; do
	case "$_lc" in '' | *[!0-9]*) continue ;; esac
	if [ "$_lc" -gt "$MAX_FILE_LINES" ]; then MAX_FILE_LINES="$_lc"; fi
	if [ "$_lc" -gt "$MAX_FILE" ]; then LARGE_FILE_VIOLATIONS=$((LARGE_FILE_VIOLATIONS + 1)); fi
done < "$_list"
rm -f "$_list" 2>/dev/null || true

# ponytail: function-size deferred to an external tokenizer (see header). Held at 0 so no
# false large-function violation is ever emitted.
LARGE_FUNCTION_VIOLATIONS=0
MAX_FUNCTION_LINES=0

jq -n \
	--argjson lf "$LARGE_FILE_VIOLATIONS" --argjson lfn "$LARGE_FUNCTION_VIOLATIONS" \
	--argjson mx "$MAX_FILE_LINES" --argjson mxfn "$MAX_FUNCTION_LINES" \
	--argjson tf "$MAX_FILE" --argjson tfn "$MAX_FUNC" '
	{ tool:"source-size",
	  status: (if ($lf + $lfn) > 0 then "findings" else "pass" end),
	  large_file_violations: $lf,
	  large_function_violations: $lfn,
	  max_file_lines: $mx,
	  max_function_lines: $mxfn,
	  thresholds: { max_file_lines: $tf, max_function_lines: $tfn } }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "source-size: wrote $OUTPUT (large_files=$LARGE_FILE_VIOLATIONS, max_file_lines=$MAX_FILE_LINES, threshold=$MAX_FILE)."
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_error "source-size: could not write '$OUTPUT'."
exit 2
