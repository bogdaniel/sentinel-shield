#!/bin/sh
# Sentinel Shield runner — Deptrac (PHP structural-boundary producer, v2.1.0).
#
# Deptrac is ONE architecture producer, not the whole capability: it detects dependency-
# boundary violations between declared layers. It does not prove Clean Architecture or DDD
# correctness (docs/architecture-governance.md).
#
# Honest statuses (never a faked clean run):
#   binary absent                      -> status "unavailable"
#   binary present, no config          -> status "not-configured"
#   binary present, no valid JSON out  -> status "execution-error"
#   ran                                -> Deptrac's native JSON, preserved as-is
#
# Config detection order: --config, then architecture-policy
# (.sentinel-shield/architecture-policy.yaml -> architecture.tools.deptrac.config), then
# deptrac.yaml / deptrac.yml / deptrac.php.
# Binary detection order: vendor/bin/deptrac, then a global `deptrac` on PATH.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-policy.sh
. "$SCRIPT_DIR/../lib/architecture-policy.sh"

OUT="reports/raw/deptrac.json"
CONFIG=""
POLICY=".sentinel-shield/architecture-policy.yaml"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: deptrac.sh [--output <path>] [--config <path>] [--policy <path>] [<output>]
Run Deptrac and write its report. Emits an honest unavailable / not-configured /
execution-error report instead of a faked clean result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		--*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
		*) OUT="$1"; shift ;;   # positional output path (back-compat with v0.1.14)
	esac
done

ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> — emit the normalized architecture contract with an
# honest non-evidence status. Never writes violations from a run that did not happen.
write_status() {
	jq -n --arg s "$1" --arg m "$2" \
		'{tool:"architecture", producer:"deptrac", status:$s, violations:0, failures:[], message:$m}' > "$OUT"
	log_warn "deptrac: $2 (status=$1)"
	exit 0
}

# Architecture policy (optional): an explicitly disabled Deptrac reports "disabled".
ap_load "$POLICY"
if ap_present; then
	if ! ap_enabled; then write_status "disabled" "architecture governance disabled in $POLICY"; fi
	if ! ap_tool_enabled deptrac true; then write_status "disabled" "deptrac disabled in $POLICY"; fi
	[ -n "$CONFIG" ] || CONFIG=$(ap_get architecture.tools.deptrac.config)
fi

# Binary: project-local first, then global.
BIN=""
if [ -x vendor/bin/deptrac ]; then BIN="vendor/bin/deptrac"
elif command_exists deptrac; then BIN="deptrac"
fi
[ -n "$BIN" ] || write_status "unavailable" "deptrac binary not found (vendor/bin/deptrac or global deptrac)"

# Config: an explicit/policy value must exist; otherwise probe the canonical names.
if [ -n "$CONFIG" ]; then
	[ -f "$CONFIG" ] || write_status "not-configured" "configured deptrac config not found: $CONFIG"
else
	for _c in deptrac.yaml deptrac.yml deptrac.php; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	[ -n "$CONFIG" ] || write_status "not-configured" "no deptrac config found (deptrac.yaml | deptrac.yml | deptrac.php)"
fi

VERSION=$("$BIN" --version 2>/dev/null | head -n1 || true)
TMP="$OUT.tmp"
# Deptrac exits non-zero when it FINDS violations — a non-zero exit is not an error here;
# the report's validity is what decides evidence vs execution-error.
"$BIN" analyse --config-file="$CONFIG" --formatter=json --output="$TMP" >/dev/null 2>&1 || true

if [ ! -f "$TMP" ] || [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	write_status "execution-error" "deptrac ran but produced no valid JSON report"
fi

# Preserve the NATIVE report verbatim, annotated with producer/config/version metadata
# (the collector reads either the native shape or the normalized contract).
jq --arg c "$CONFIG" --arg v "$VERSION" \
	'if type=="object" then . + {producer:"deptrac", config:$c, tool_version:$v} else . end' "$TMP" > "$OUT" 2>/dev/null \
	|| mv "$TMP" "$OUT"
rm -f "$TMP"
log_info "deptrac: report written to $OUT (config=$CONFIG)"
exit 0
