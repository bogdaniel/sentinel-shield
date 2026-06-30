#!/bin/sh
# Sentinel Shield — security-summary fallback policy.
#
# Decides whether enforcement may proceed given the resolved adoption mode and
# whether a REAL security-summary.json is present. The all-zero example template is
# NOT acceptable evidence in baseline/strict/regulated.
#
# Rule:
#   report-only            : real summary used if present; otherwise the example is
#                            copied in as a clearly-marked NON-PRODUCTION fallback.
#   baseline/strict/regulated : a real summary MUST be present, else fail (exit 1).
#
# "Real" = the summary file exists, is valid JSON, and is NOT byte-identical (after
# canonicalization) to templates/security-summary.example.json. A real builder run
# always differs (generated_at/source/evidence), so the only way to look like the
# example is to literally use the example — which is exactly what we reject.
#
# Exit codes: 0 proceed, 1 missing-real-summary in a strict-enough mode, 2 config.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

die_cfg() { log_error "$*"; exit 2; }

SUMMARY="reports/security-summary.json"
EXAMPLE="templates/security-summary.example.json"
GATES_ENV="reports/sentinel-shield-gates.env"
MODE=""
VALID_MODES="report-only baseline strict regulated"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: select-security-summary.sh [options]

Apply the security-summary fallback policy for the resolved adoption mode.

Options:
  --summary <path>     Real/expected summary (default: reports/security-summary.json)
  --example <path>     Example template (default: templates/security-summary.example.json)
  --gates-env <path>   Read mode from here if --mode is absent
                       (default: reports/sentinel-shield-gates.env)
  --mode <mode>        Force mode: report-only | baseline | strict | regulated
  -h, --help           Show this help

Exit: 0 proceed (summary in place), 1 real summary required but missing, 2 config.
Requires jq.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
		--example) EXAMPLE="${2:?--example requires a value}"; shift 2 ;;
		--gates-env) GATES_ENV="${2:?--gates-env requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; die_cfg "unknown argument: $1" ;;
	esac
done

command_exists jq || die_cfg "jq is required but was not found."

# Resolve mode: explicit flag wins, else read SENTINEL_SHIELD_MODE from the gates env
# (validated, not sourced).
if [ -z "$MODE" ]; then
	if [ -f "$GATES_ENV" ]; then
		_line=$(grep -E '^SENTINEL_SHIELD_MODE=[A-Za-z0-9._-]+$' "$GATES_ENV" | head -n1 || true)
		MODE=${_line#SENTINEL_SHIELD_MODE=}
	fi
fi
[ -n "$MODE" ] || die_cfg "cannot determine mode (pass --mode or provide $GATES_ENV)"

_ok=0
for _m in $VALID_MODES; do [ "$_m" = "$MODE" ] && _ok=1; done
[ "$_ok" -eq 1 ] || die_cfg "invalid mode '$MODE' (expected one of: $VALID_MODES)"

# Determine whether a REAL summary is present.
real=false
if [ -f "$SUMMARY" ] && jq -e . "$SUMMARY" >/dev/null 2>&1; then
	if [ -f "$EXAMPLE" ] && [ "$(jq -S -c . "$SUMMARY")" = "$(jq -S -c . "$EXAMPLE")" ]; then
		real=false
		log_warn "provided summary is byte-identical to the example template (treated as NOT real)"
	else
		real=true
	fi
fi

case "$MODE" in
	report-only)
		if [ "$real" = "true" ]; then
			log_info "report-only: using provided security-summary.json"
		else
			log_warn "NON-PRODUCTION FALLBACK: no real security-summary found."
			log_warn "report-only mode: using the all-zero EXAMPLE. This is NOT evidence."
			ensure_dir "$(dirname -- "$SUMMARY")"
			cp "$EXAMPLE" "$SUMMARY" || die_cfg "could not stage example summary at $SUMMARY"
		fi
		exit 0
		;;
	baseline | strict | regulated)
		if [ "$real" = "true" ]; then
			log_info "$MODE: real security-summary.json present."
			exit 0
		fi
		log_error "mode '$MODE' requires a REAL security-summary.json produced from scanner"
		log_error "artifacts. The all-zero example is not acceptable evidence. Failing the gate."
		exit 1
		;;
esac
