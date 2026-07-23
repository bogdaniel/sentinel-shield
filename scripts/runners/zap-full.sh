#!/bin/sh
# Sentinel Shield — OWASP ZAP FULL (active) runner. CONTROLLED/MANUAL.
# Enforces the DAST safety guard, then runs zap-full-scan.py if available, writing
# reports/raw/zap-full.json (default OUT). If ZAP is absent it does NOT fake a scan —
# emits nothing and exits 0 (the collector then reports 'unavailable'). NEVER scans
# arbitrary targets.
#
# Collect the FULL report with the matching collector invocation:
#   scripts/collectors/zap.sh --input reports/raw/zap-full.json
# The collector auto-detects the "zap-full" basename and labels dast_findings under the
# distinct "zap-full" tool (or pass --report-kind full explicitly).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/dast-guard.sh"
OUT="${1:-reports/raw/zap-full.json}"
rc=0; ss_dast_check || rc=$?
[ "$rc" -eq 10 ] && exit 0      # no target -> skip cleanly
[ "$rc" -ne 0 ] && exit "$rc"   # allowlist violation -> fail closed
mkdir -p "$(dirname "$OUT")"
rm -f -- "$OUT" 2>/dev/null || true   # never leave a stale report as evidence for this run
if ! command -v zap-full-scan.py >/dev/null 2>&1; then
	echo "[sentinel-shield][dast] zap-full-scan.py not installed locally; run via the sentinel-shield-dast.yml workflow (zaproxy container). No scan run." >&2
	exit 0
fi
echo "[sentinel-shield][dast] running ZAP FULL (active) scan against $SENTINEL_SHIELD_DAST_TARGET_URL" >&2
zap-full-scan.py -t "$SENTINEL_SHIELD_DAST_TARGET_URL" -J "$OUT" || true
exit 0
