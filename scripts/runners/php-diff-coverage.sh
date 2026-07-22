#!/bin/sh
# Sentinel Shield runner — PHP changed-lines coverage -> reports/raw/php-diff-coverage.json.
#
# Runs Pest/PHPUnit with Clover coverage, derives the set of added/changed lines from `git diff`
# against a base ref, and computes CHANGED-LINES coverage via
# scripts/adapters/clover-diff-to-coverage-json.php, thresholded by quality.coverage.changed_lines_min.
#
# Deterministic: base ref = SENTINEL_SHIELD_DIFF_BASE, else merge-base with origin/main|master,
# else HEAD~1. No git / no base / no coverage driver -> leave report ABSENT + EXIT 0 (unavailable);
# NEVER fake clean; EXIT 2 only on missing jq / bad invocation.
#
# Env: SENTINEL_SHIELD_PHP_COVERAGE_BIN (pest/phpunit), SENTINEL_SHIELD_DIFF_BASE
# Usage: php-diff-coverage.sh [--output reports/raw/php-diff-coverage.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/quality-policy.sh
. "$SCRIPT_DIR/../lib/quality-policy.sh"

OUTPUT="reports/raw/php-diff-coverage.json"
POLICY=".sentinel-shield/quality-policy.yaml"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: php-diff-coverage.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "php-diff-coverage: jq is required."; exit 2; }
command_exists php || { log_warn "php-diff-coverage: php not found; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }
command_exists git || { log_warn "php-diff-coverage: git not found; leaving '$OUTPUT' absent (cannot compute a diff)."; exit 0; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_warn "php-diff-coverage: not a git work tree; leaving '$OUTPUT' absent."; exit 0; }

ADAPTER="$SCRIPT_DIR/../adapters/clover-diff-to-coverage-json.php"
[ -f "$ADAPTER" ] || { log_error "php-diff-coverage: adapter not found: $ADAPTER"; exit 2; }

qp_load "$POLICY"
if [ "$(qp_bool quality.coverage.enabled true)" = "false" ]; then
	log_warn "php-diff-coverage: coverage disabled in quality policy; leaving '$OUTPUT' absent."; exit 0
fi
THRESH=$(qp_num quality.coverage.changed_lines_min 80)

# Resolve the diff base.
BASE="${SENTINEL_SHIELD_DIFF_BASE:-}"
if [ -z "$BASE" ]; then
	for _cand in origin/main origin/master main master; do
		if git rev-parse --verify --quiet "$_cand" >/dev/null 2>&1; then
			_mb=$(git merge-base HEAD "$_cand" 2>/dev/null || true)
			[ -n "$_mb" ] && { BASE="$_mb"; break; }
		fi
	done
	[ -z "$BASE" ] && git rev-parse --verify --quiet HEAD~1 >/dev/null 2>&1 && BASE="HEAD~1"
fi
[ -n "$BASE" ] || { log_warn "php-diff-coverage: could not resolve a diff base (set SENTINEL_SHIELD_DIFF_BASE); leaving '$OUTPUT' absent."; exit 0; }

BIN="${SENTINEL_SHIELD_PHP_COVERAGE_BIN:-}"
if [ -z "$BIN" ]; then
	if [ -x vendor/bin/pest ]; then BIN="vendor/bin/pest"
	elif [ -x vendor/bin/phpunit ]; then BIN="vendor/bin/phpunit"
	fi
fi
[ -n "$BIN" ] || { log_warn "php-diff-coverage: no pest/phpunit; leaving '$OUTPUT' absent (tool unavailable)."; exit 0; }

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_clover="$_dir/php-diff-coverage.clover.xml"
_changed="$_dir/php-diff-coverage.changed.txt"
_err="$_dir/php-diff-coverage.stderr.log"
rm -f "$_clover" "$_changed" 2>/dev/null || true

# Changed (added) PHP lines: parse `git diff --unified=0` hunks (+c,d -> lines c..c+d-1).
# --no-prefix drops the a//b/ prefix and the '+++ ' header path is taken as the WHOLE remainder
# of the line (substr from col 5), so paths containing spaces are not truncated at the first
# field. core.quotePath=false keeps non-ASCII paths verbatim rather than octal-quoted.
git -c core.quotePath=false diff --unified=0 --no-prefix "$BASE" -- '*.php' 2>>"$_err" | awk '
	/^\+\+\+ /{ f=substr($0,5); next }
	/^@@ /{ t=$3; sub(/^\+/,"",t); n=split(t,a,","); s=a[1]; c=(n>1)?a[2]:1;
		for(i=0;i<c;i++) print f ":" (s+i) }
' > "$_changed" 2>>"$_err" || true

if [ ! -s "$_changed" ]; then
	# No changed PHP lines -> diff coverage is vacuously 100 (nothing new to cover). This branch
	# ALWAYS exits: it must never fall through into a full coverage run against an empty
	# changed-lines file.
	jq -n --argjson thr "$THRESH" '{tool:"diff-coverage", status:"pass", changed_lines_coverage_percent:100, threshold:$thr, changed_executable_lines:0, covered_changed_lines:0, violations:0}' > "$OUTPUT"
	if jq -e . "$OUTPUT" >/dev/null 2>&1; then
		log_info "php-diff-coverage: no changed PHP lines vs $BASE; wrote 100% ($OUTPUT)."
		rm -f "$_err" 2>/dev/null || true
		exit 0
	fi
	rm -f "$OUTPUT" 2>/dev/null || true
	log_warn "php-diff-coverage: no changed PHP lines vs $BASE but could not write the vacuous-100 report; leaving '$OUTPUT' absent."
	exit 0
fi

log_info "php-diff-coverage: $BIN --coverage-clover $_clover (base $BASE)"
_rc=0
"$BIN" --coverage-clover "$_clover" >"$_dir/php-diff-coverage.stdout.raw" 2>>"$_err" || _rc=$?
if [ ! -s "$_clover" ]; then
	log_warn "php-diff-coverage: no Clover produced (exit ${_rc:-?}) — usually no coverage driver. Leaving '$OUTPUT' absent (tool 'unavailable'). Debug: $_err."
	exit 0
fi

if php "$ADAPTER" "$_clover" --changed-lines "$_changed" --threshold "$THRESH" --output "$OUTPUT" 2>>"$_err" \
	&& jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "php-diff-coverage: wrote $OUTPUT."
	rm -f "$_clover" "$_changed" "$_dir/php-diff-coverage.stdout.raw" "$_err" 2>/dev/null || true
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_warn "php-diff-coverage: adapter could not compute diff coverage; leaving '$OUTPUT' absent. Debug: $_clover, $_changed, $_err."
exit 0
