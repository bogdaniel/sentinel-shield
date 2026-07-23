#!/bin/sh
# Sentinel Shield runner — focused / skipped test markers -> reports/raw/focused-tests.json.
#
# Grep-based source scanner (no external tool): it is ALWAYS available, so a clean scan of
# zero is a REAL pass, not a fake one. Scans the CURRENT directory's source for FOCUSED test
# markers (describe.only/it.only/... , PHP/Pest ->only()) and SKIPPED markers (markTestSkipped,
# describe.skip, xit(, ...). The .only/markTestSkipped tokens rarely appear outside tests, so a
# whole-repo scan (with the standard excludes) is an acceptable, low-noise approximation.
#
# Contract: violations are FINDINGS, not errors -> EXIT 0 even when markers are found. EXIT 2
# only on bad invocation or missing jq. Counts are occurrence counts (grep -o, scanned
# left-to-right non-overlapping so an overlapping pair like 'describe.only(' counts once;
# grep's no-match exit is guarded).
#
# Usage: focused-tests.sh [--output reports/raw/focused-tests.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/focused-tests.json"
POLICY=".sentinel-shield/quality-policy.yaml"  # reserved (focused-tests has no numeric threshold)
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: focused-tests.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "focused-tests: jq is required."; exit 2; }

# Directories excluded from every source scan (matched by name, anywhere in the tree).
EXCLUDES="--exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=reports --exclude-dir=storage --exclude-dir=cache --exclude-dir=dist --exclude-dir=build --exclude-dir=coverage --exclude-dir=generated --exclude-dir=.git"

# count_matches -e <pat> [-e <pat> ...] -- echo the number of matched occurrences (grep -o
# prints one line per match). grep rc: 0=matches, 1=no matches, >1=real error. A real error
# must NOT be silently counted as zero (a false clean pass), so it prints the sentinel "ERR"
# for the caller to fail on. A non-numeric count (should never happen) -> 0.
count_matches() {
	_grc=0
	# shellcheck disable=SC2086
	_out=$(grep -rIoF $EXCLUDES "$@" . 2>/dev/null) || _grc=$?
	if [ "$_grc" -gt 1 ]; then printf 'ERR'; return; fi
	[ -n "$_out" ] || { printf '0'; return; }
	_c=$(printf '%s\n' "$_out" | wc -l | tr -d '[:space:]')
	case "$_c" in '' | *[!0-9]*) _c=0 ;; esac
	printf '%s' "$_c"
}

# Focused markers: JS/TS describe.only/it.only/test.only/suite.only/context.only and the
# catch-all .only( ; PHP/Pest ->only( . (Fixed strings; a dot is literal under -F.)
FOCUSED=$(count_matches \
	-e 'describe.only' -e 'it.only' -e 'test.only' -e 'suite.only' -e 'context.only' \
	-e '.only(' -e '->only(')

# Skipped markers: PHP markTestSkipped(/markTestIncomplete( ; JS/TS describe.skip/it.skip/
# test.skip/xdescribe(/xit( .
SKIPPED=$(count_matches \
	-e 'markTestSkipped(' -e 'markTestIncomplete(' \
	-e 'describe.skip' -e 'it.skip' -e 'test.skip' -e 'xdescribe(' -e 'xit(')

# A grep hard failure must fail the runner, never masquerade as a clean zero-marker pass.
case "$FOCUSED$SKIPPED" in
	*ERR*) log_error "focused-tests: grep failed while scanning for markers; refusing to emit a possibly-false clean report."; exit 2 ;;
esac

ensure_dir "$(dirname "$OUTPUT")"

jq -n --argjson f "$FOCUSED" --argjson s "$SKIPPED" '
	{ tool:"focused-tests",
	  status: (if ($f + $s) > 0 then "findings" else "pass" end),
	  focused_test_violations: $f,
	  skipped_test_marker_violations: $s }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "focused-tests: wrote $OUTPUT (focused=$FOCUSED, skipped=$SKIPPED)."
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_error "focused-tests: could not write '$OUTPUT'."
exit 2
