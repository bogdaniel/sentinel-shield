#!/bin/sh
# Sentinel Shield — Nuclei controlled runner. CONTROLLED/MANUAL.
# Enforces the DAST safety guard (target URL + allowlisted host), then runs nuclei if
# available, writing reports/raw/nuclei.json. Never fakes a scan; never scans an
# un-allowlisted/arbitrary target.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/dast-guard.sh"
OUT="${1:-reports/raw/nuclei.json}"
# Host/target safety first (no-target -> skip; non-http/no-allowlist/mismatch -> 3).
rc=0; ss_dast_check || rc=$?
[ "$rc" -eq 10 ] && exit 0
[ "$rc" -ne 0 ] && exit "$rc"
# Controlled template-path guard (missing/traversal/remote/absent -> 3).
rc=0; ss_nuclei_template_check || rc=$?
[ "$rc" -ne 0 ] && exit "$rc"
mkdir -p "$(dirname "$OUT")"
if ! command -v nuclei >/dev/null 2>&1; then
	echo "[sentinel-shield][dast] nuclei not installed locally; run via sentinel-shield-dast.yml. No scan run." >&2
	exit 0
fi
echo "[sentinel-shield][dast] running nuclei against $SENTINEL_SHIELD_DAST_TARGET_URL with curated templates $SENTINEL_SHIELD_NUCLEI_TEMPLATES" >&2
# -je (JSON array), NOT -jle (JSONL): the collector reads one JSON document and exits 2
# on multi-doc input, hard-erroring the gate exactly when >=2 findings exist.
nuclei -u "$SENTINEL_SHIELD_DAST_TARGET_URL" -t "$SENTINEL_SHIELD_NUCLEI_TEMPLATES" -je "$OUT" -severity medium,high,critical || true
exit 0
