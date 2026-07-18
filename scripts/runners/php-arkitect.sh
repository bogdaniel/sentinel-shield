#!/bin/sh
# Sentinel Shield runner — PHPArkitect (optional PHP architecture-rule producer, v2.1.0).
#
# PHPArkitect expresses architecture rules as PHP code (phparkitect.php) — "Domain must not
# depend on Infrastructure", "Application may depend on Domain only", and so on. It detects
# dependency-boundary violations; it does not prove domain-modelling quality.
#
# Honest statuses: unavailable (binary absent) / not-configured (no rule file) /
# execution-error (ran but unreadable) / pass / findings. Never a faked clean run.
#
# ponytail: PHPArkitect has no stable machine-readable formatter across versions, so the
# violation COUNT is parsed from its CLI output. A non-zero exit with no parseable violation
# line is reported as 1 violation (something failed — never 0). If a future PHPArkitect ships
# a JSON formatter, emit the normalized contract directly and delete the text parsing.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"
# shellcheck source=scripts/lib/architecture-policy.sh
. "$SCRIPT_DIR/../lib/architecture-policy.sh"

OUT="reports/raw/php-arkitect.json"
CONFIG=""
POLICY=".sentinel-shield/architecture-policy.yaml"

usage() {
	cat <<'EOF'
Usage: php-arkitect.sh [--output <path>] [--config <path>] [--policy <path>] [<output>]
Run PHPArkitect and write a normalized architecture report.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		--*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
		*) OUT="$1"; shift ;;
	esac
done

ensure_dir "$(dirname -- "$OUT")"

ap_load "$POLICY"
if ap_present; then
	if ! ap_enabled; then arch_write_status "$OUT" php-arkitect disabled "architecture governance disabled in $POLICY"; exit 0; fi
	# PHPArkitect is OPT-IN: absent policy (or an absent key) leaves it off, so a project that
	# never asked for it is reported unavailable rather than silently expected.
	if ! ap_tool_enabled php_arkitect false; then arch_write_status "$OUT" php-arkitect disabled "php_arkitect disabled in $POLICY"; exit 0; fi
	[ -n "$CONFIG" ] || CONFIG=$(ap_get architecture.tools.php_arkitect.config)
fi

BIN=""
if [ -x vendor/bin/phparkitect ]; then BIN="vendor/bin/phparkitect"
elif command_exists phparkitect; then BIN="phparkitect"
fi
if [ -z "$BIN" ]; then
	arch_write_status "$OUT" php-arkitect unavailable "phparkitect binary not found (vendor/bin/phparkitect or global phparkitect)"
	exit 0
fi

if [ -n "$CONFIG" ]; then
	if [ ! -f "$CONFIG" ]; then
		arch_write_status "$OUT" php-arkitect not-configured "configured phparkitect rule file not found: $CONFIG"; exit 0
	fi
else
	for _c in phparkitect.php arkitect.php; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	if [ -z "$CONFIG" ]; then
		arch_write_status "$OUT" php-arkitect not-configured "no phparkitect rule file found (phparkitect.php | arkitect.php)"; exit 0
	fi
fi

VERSION=$("$BIN" --version 2>/dev/null | head -n1 || true)
LOG=$(mktemp 2>/dev/null || mktemp -t ss-arkitect)
RC=0
"$BIN" check --config="$CONFIG" --no-interaction > "$LOG" 2>&1 || RC=$?

# Count reported violations; "ERRORS!"/violation lines are the stable markers across versions.
V=$(grep -Ec '^[[:space:]]*(-[[:space:]]+)?.*(violat|depends on|should not depend|must not depend)' "$LOG" 2>/dev/null || true)
case "$V" in '' | *[!0-9]*) V=0 ;; esac
if [ "$RC" -ne 0 ] && [ "$V" -eq 0 ]; then V=1; fi          # non-zero exit is never a clean 0
if [ "$RC" -eq 0 ]; then V=0; fi                             # clean exit is authoritative

if [ "$V" -gt 0 ]; then STATUS="findings"; else STATUS="pass"; fi
jq -n --arg s "$STATUS" --argjson v "$V" --arg c "$CONFIG" --arg ver "$VERSION" \
	'{tool:"architecture", producer:"php-arkitect", status:$s, violations:$v,
	  rule_count:0, context_count:0, failures:[], config:$c, tool_version:$ver}' > "$OUT"
rm -f "$LOG"
log_info "php-arkitect: violations=$V -> $OUT (config=$CONFIG)"
exit 0
