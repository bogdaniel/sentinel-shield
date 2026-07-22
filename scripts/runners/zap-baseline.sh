#!/bin/sh
# Sentinel Shield — OWASP ZAP baseline (passive) runner. CONTROLLED/MANUAL.
# Enforces the DAST safety guard, then runs zap-baseline.py if available, writing
# reports/raw/zap.json. If ZAP is absent it does NOT fake a scan — emits nothing and
# exits 0 (the collector then reports 'unavailable'). NEVER scans arbitrary targets.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/dast-guard.sh"
OUT="${1:-reports/raw/zap.json}"
rc=0; ss_dast_check || rc=$?
[ "$rc" -eq 10 ] && exit 0      # no target -> skip cleanly
[ "$rc" -ne 0 ] && exit "$rc"   # allowlist violation -> fail closed
mkdir -p "$(dirname "$OUT")"
# Invoke whichever ZAP entrypoint is actually installed. Accepting zap.sh in the
# availability check but only ever calling zap-baseline.py made hosts with just zap.sh
# log "running ZAP baseline" then silently no-op via `|| true`.
ZAP_BIN=""
if command -v zap-baseline.py >/dev/null 2>&1; then ZAP_BIN="zap-baseline.py"
elif command -v zap.sh >/dev/null 2>&1; then ZAP_BIN="zap.sh"
fi
if [ -z "$ZAP_BIN" ]; then
	echo "[sentinel-shield][dast] ZAP not installed locally; run via the sentinel-shield-dast.yml workflow (zaproxy container). No scan run." >&2
	exit 0
fi
echo "[sentinel-shield][dast] running ZAP baseline ($ZAP_BIN) against $SENTINEL_SHIELD_DAST_TARGET_URL" >&2
"$ZAP_BIN" -t "$SENTINEL_SHIELD_DAST_TARGET_URL" -J "$OUT" || true
exit 0
