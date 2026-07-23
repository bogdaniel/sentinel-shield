#!/bin/sh
# Sentinel Shield runner — ESLint architecture-boundary rules (JS/TS producer, v2.1.0).
#
# Runs ESLint over the source tree and counts ONLY architecture-boundary rules
# (boundaries/*, import/no-restricted-paths, no-restricted-imports), so general lint
# findings stay in their own channel and are never double-counted as architecture.
#
# Package manager is detected from the LOCKFILE; npx is never forced on pnpm/yarn projects.
# Honest statuses: unavailable / not-configured / execution-error / pass / findings.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"
# shellcheck source=scripts/lib/architecture-policy.sh
. "$SCRIPT_DIR/../lib/architecture-policy.sh"

OUT="reports/raw/eslint-boundaries.json"
CONFIG=""
POLICY=".sentinel-shield/architecture-policy.yaml"
PATHS=""
BOUNDARY_RULES='^boundaries/|^import/no-restricted-paths$|^no-restricted-imports$'

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: eslint-boundaries.sh [--output <path>] [--config <path>] [--policy <path>]
                            [--paths "<dir> <dir>"] [<output>]
Run ESLint and write a normalized architecture report counting only boundary rules.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--paths) PATHS="${2:?--paths requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		--*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
		*) OUT="$1"; shift ;;
	esac
done

ensure_dir "$(dirname -- "$OUT")"

ap_load "$POLICY"
if ap_present; then
	if ! ap_enabled; then arch_write_status "$OUT" eslint-boundaries disabled "architecture governance disabled in $POLICY"; exit 0; fi
	if ! ap_tool_enabled eslint_boundaries true; then arch_write_status "$OUT" eslint-boundaries disabled "eslint_boundaries disabled in $POLICY"; exit 0; fi
	[ -n "$CONFIG" ] || CONFIG=$(ap_get architecture.tools.eslint_boundaries.config)
fi

PM=$(arch_pkg_manager)
if [ -x node_modules/.bin/eslint ]; then
	RUN="node_modules/.bin/eslint"
elif command_exists eslint; then
	RUN="eslint"
elif [ -d node_modules ] && command_exists "$PM"; then
	RUN="$(arch_pkg_exec "$PM") eslint"
else
	arch_write_status "$OUT" eslint-boundaries unavailable "eslint not found (node_modules/.bin/eslint, global eslint, or $PM exec)"
	exit 0
fi

if [ -n "$CONFIG" ]; then
	if [ ! -f "$CONFIG" ]; then
		arch_write_status "$OUT" eslint-boundaries not-configured "configured eslint config not found: $CONFIG"; exit 0
	fi
else
	for _c in eslint.config.js eslint.config.mjs eslint.config.cjs .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	if [ -z "$CONFIG" ]; then
		arch_write_status "$OUT" eslint-boundaries not-configured "no eslint config found (eslint.config.* | .eslintrc*)"; exit 0
	fi
fi

if [ -z "$PATHS" ]; then
	for _d in src app lib; do
		[ -d "$_d" ] && PATHS="$PATHS $_d"
	done
	PATHS=${PATHS# }
fi
if [ -z "$PATHS" ]; then
	arch_write_status "$OUT" eslint-boundaries not-configured "no source directory to lint (looked for src, app, lib)"; exit 0
fi

TMP="$OUT.tmp"
_err="$OUT.stderr.log"
# ESLint exits non-zero when it reports problems — validity of the JSON decides evidence.
# Keep stderr as a debug artifact so an execution-error carries diagnostics.
# shellcheck disable=SC2086  # RUN and PATHS are intentionally word-split argument lists
$RUN $PATHS --format json > "$TMP" 2>"$_err" || true

if [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	arch_write_status "$OUT" eslint-boundaries execution-error "eslint ran but produced no valid JSON report (see $_err)"
	exit 0
fi

# Normalize: ONLY boundary rules become architecture violations; each distinct boundary rule
# id observed counts toward rule_count (informational).
jq --arg re "$BOUNDARY_RULES" '
	[ .[]?.messages[]? as $m | $m | select((.ruleId // "") | test($re)) ] as $b
	| { tool:"architecture", producer:"eslint-boundaries",
	    status: (if ($b | length) > 0 then "findings" else "pass" end),
	    violations: ($b | length),
	    rule_count: ([ $b[].ruleId ] | unique | length),
	    context_count: 0,
	    failures: [ $b[] | { rule: (.ruleId // ""), message: (.message // "") } ] }' "$TMP" > "$OUT" 2>/dev/null || {
	rm -f "$TMP"
	arch_write_status "$OUT" eslint-boundaries execution-error "eslint report could not be normalized (unexpected shape; see $_err)"
	exit 0
}
rm -f "$TMP" "$_err"
log_info "eslint-boundaries: violations=$(jq -r '.violations' "$OUT") -> $OUT (config=$CONFIG)"
exit 0
