#!/bin/sh
# Sentinel Shield runner — npm/pnpm/yarn audit -> reports/raw/npm-audit.json.
#
# Detects the package manager DETERMINISTICALLY from the lockfile (never switches it):
#   package-lock.json | npm-shrinkwrap.json -> npm   audit --json
#   pnpm-lock.yaml                          -> pnpm  audit --json
#   yarn.lock                               -> yarn  npm audit --json   (Yarn Berry)
# A non-zero audit exit means vulnerabilities were FOUND — expected; we capture the JSON
# and EXIT 0 (the report is the signal, so the workflow still uploads artifacts).
#
# NEVER write a fake clean report. No lockfile, the manager absent, OR no valid JSON
# object -> leave the report ABSENT so the builder marks the tool `unavailable` (honest,
# not 0-faked). Debug artifacts (stdout/stderr) are kept on trouble.
#
# Usage: npm-audit.sh [--output reports/raw/npm-audit.json]
# Exit: 0 ran (report written) OR unavailable (no report, honest); 2 config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

OUTPUT="reports/raw/npm-audit.json"
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) printf 'Usage: npm-audit.sh [--output <path>]\n'; exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done
# (Issue 7) Clear any STALE report up-front so a direct invocation is honest even
# when the tool/runtime is absent or the run fails (run-tool-plan also clears, but a
# direct call must not inherit a previous run's valid report).
rm -f -- "$OUTPUT" 2>/dev/null || true

command_exists jq || { log_error "npm-audit: jq is required."; exit 2; }

# Detect the package manager from the lockfile (first match wins; never switch).
PM=""
if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then PM="npm"
elif [ -f pnpm-lock.yaml ]; then PM="pnpm"
elif [ -f yarn.lock ]; then PM="yarn"
fi
if [ -z "$PM" ]; then
	log_warn "npm-audit: no lockfile (package-lock.json/pnpm-lock.yaml/yarn.lock); leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi
if ! command_exists "$PM"; then
	log_warn "npm-audit: lockfile selects '$PM' but it is not on PATH; leaving '$OUTPUT' absent (tool unavailable)."
	exit 0
fi

ensure_dir "$(dirname "$OUTPUT")"
_dir=$(dirname "$OUTPUT")
_raw="$_dir/npm-audit.stdout.raw"
_err="$_dir/npm-audit.stderr.log"

# Build the audit invocation for the detected manager (each emits JSON on stdout).
case "$PM" in
	npm)  set -- audit --json ;;
	pnpm) set -- audit --json ;;
	yarn)
		# Yarn Classic (1.x): `yarn audit --json`. Yarn Berry (2+): `yarn npm audit --json`.
		_yv=$(yarn --version 2>/dev/null || echo 0)
		case "$_yv" in
			1.*) set -- audit --json ;;
			*)   set -- npm audit --json ;;
		esac ;;
esac

log_info "npm-audit: $PM $* (lockfile-detected manager)."
# Audit exits non-zero when vulnerabilities are found — expected; we keep going.
_rc=0
"$PM" "$@" >"$_raw" 2>"$_err" || _rc=$?

# Validate the JSON object before writing. NEVER fake a clean report.
if jq -e 'type == "object"' "$_raw" >/dev/null 2>&1; then
	cp "$_raw" "$OUTPUT"
	_v=$(jq '[(.metadata.vulnerabilities // {}) | .[]] | add // 0' "$OUTPUT" 2>/dev/null || echo '?')
	log_info "npm-audit: wrote $OUTPUT (vulnerabilities=$_v)."
	rm -f "$_raw" "$_err" 2>/dev/null || true
	exit 0
fi

log_warn "npm-audit: '$PM' produced no valid JSON object on stdout (exit ${_rc:-?}); leaving '$OUTPUT' absent (tool 'unavailable'). NOT writing a fake clean report. Debug: $_raw, $_err."
exit 0
