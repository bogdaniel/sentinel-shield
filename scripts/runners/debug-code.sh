#!/bin/sh
# Sentinel Shield runner — debug residue -> reports/raw/debug-code.json.
#
# Grep-based source scanner (no external tool): it is ALWAYS available, so a clean scan of
# zero is a REAL pass, not a fake one. Scans the CURRENT directory's PHP/JS/TS source for
# leftover debug calls (PHP dd(/dump(/var_dump(/print_r(/ray(/die(/exit( , JS/TS debugger/
# console.log/console.debug). Test files/dirs are EXCLUDED: debug residue matters in
# production source, not in tests.
#
# Matches use explicit POSIX-ERE word boundaries (a leading non-word char, and a trailing
# non-word char for the bare identifiers) so 'dd(' does not fire on '->add(', 'ray(' not on
# 'array(', and 'console.log' not on 'console.logger' — a plain substring scan would flood
# Laravel/JS repos with false positives. ERE boundaries are portable across BSD/GNU/ugrep;
# grep -w is NOT (it disagrees on patterns ending in '(').
#
# Contract: violations are FINDINGS, not errors -> EXIT 0 even when residue is found. EXIT 2
# only on bad invocation or missing jq.
#
# Usage: debug-code.sh [--output reports/raw/debug-code.json] [--policy <path>]
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/debug-code.json"
POLICY=".sentinel-shield/quality-policy.yaml"  # reserved (debug-code has no numeric threshold)
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: debug-code.sh [--output <path>] [--policy <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "debug-code: jq is required."; exit 2; }

# Directories excluded from every source scan (matched by name, anywhere in the tree).
EXCLUDES="--exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=reports --exclude-dir=storage --exclude-dir=cache --exclude-dir=dist --exclude-dir=build --exclude-dir=coverage --exclude-dir=generated --exclude-dir=.git"

# Word boundaries: _L = a non-word char (or line start) before the token; _R = a non-word
# char (or line end) after the bare identifiers. Call-like tokens ('dd(', ...) end in '(',
# which is already a right boundary, so they need only _L.
_L='(^|[^[:alnum:]_])'
_R='([^[:alnum:]_]|$)'

# Scan production source only: restrict to PHP/JS/TS files and drop test files/dirs.
# -o counts OCCURRENCES (not lines): grep scans left-to-right, non-overlapping, so two calls
# on one line (e.g. `dd($x); var_dump($y);`) count as two — matching the documented contract.
# shellcheck disable=SC2086
DCV=$(grep -rIoE \
	--include='*.php' --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
	--exclude-dir=tests --exclude-dir=test --exclude-dir=Test --exclude-dir=spec \
	--exclude='*.test.*' --exclude='*.spec.*' --exclude='*Test.php' --exclude='*.pest.php' \
	$EXCLUDES \
	-e "${_L}dd\(" -e "${_L}dump\(" -e "${_L}var_dump\(" -e "${_L}print_r\(" \
	-e "${_L}ray\(" -e "${_L}die\(" -e "${_L}exit\(" \
	-e "${_L}debugger${_R}" -e "${_L}console\.log${_R}" -e "${_L}console\.debug${_R}" \
	. 2>/dev/null | wc -l | tr -d '[:space:]' || true)
case "$DCV" in '' | *[!0-9]*) DCV=0 ;; esac

ensure_dir "$(dirname "$OUTPUT")"

jq -n --argjson n "$DCV" '
	{ tool:"debug-code",
	  status: (if $n > 0 then "findings" else "pass" end),
	  debug_code_violations: $n }' > "$OUTPUT"

if jq -e . "$OUTPUT" >/dev/null 2>&1; then
	log_info "debug-code: wrote $OUTPUT (debug_code_violations=$DCV)."
	exit 0
fi
rm -f "$OUTPUT" 2>/dev/null || true
log_error "debug-code: could not write '$OUTPUT'."
exit 2
