#!/bin/sh
# Sentinel Shield audit wrapper — Dockle (v0.1.19). Scans a BUILT image; never builds one.
#   SENTINEL_SHIELD_IMAGE         REQUIRED — the built image ref to scan (no default).
#   SENTINEL_SHIELD_DOCKLE_IMAGE  container image to run Dockle from (used if no local binary).
#   SENTINEL_SHIELD_DOCKLE_EXIT_CODE  Dockle's own exit code on findings (default 0 — the Sentinel
#                                 Shield gate decides; Dockle should not fail the wrapper).
# Missing SENTINEL_SHIELD_IMAGE or no Dockle -> unavailable (exit 0, NO file, never fake-clean).
# Never scans an arbitrary image silently — only the explicit SENTINEL_SHIELD_IMAGE.
set -eu
OUT="${1:-reports/raw/dockle.json}"
mkdir -p "$(dirname "$OUT")"
IMG="${SENTINEL_SHIELD_IMAGE:-}"
DOCKLE_IMG="${SENTINEL_SHIELD_DOCKLE_IMAGE:-}"
DEXIT="${SENTINEL_SHIELD_DOCKLE_EXIT_CODE:-0}"

unavailable() { echo "[sentinel-shield] dockle unavailable: $1 (no report written)." >&2; exit 0; }
[ -n "$IMG" ] || unavailable "SENTINEL_SHIELD_IMAGE not set (the built image ref to scan)"

if command -v dockle >/dev/null 2>&1; then
	echo "[sentinel-shield] dockle: scanning image $IMG -> $OUT" >&2
	dockle --exit-code "$DEXIT" -f json -o "$OUT" "$IMG" || true
elif [ -n "$DOCKLE_IMG" ] && command -v docker >/dev/null 2>&1; then
	echo "[sentinel-shield] dockle (container $DOCKLE_IMG): scanning image $IMG" >&2
	OUTDIR=$(CDPATH= cd -- "$(dirname "$OUT")" && pwd)
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$OUTDIR:/report" "$DOCKLE_IMG" \
		--exit-code "$DEXIT" -f json -o /report/"$(basename "$OUT")" "$IMG" || true
else
	unavailable "no local 'dockle' binary and no SENTINEL_SHIELD_DOCKLE_IMAGE+docker"
fi
exit 0
