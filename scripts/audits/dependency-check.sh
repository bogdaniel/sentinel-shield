#!/bin/sh
# Sentinel Shield audit wrapper — OWASP Dependency-Check (v0.1.19). SLOW — main-gate (optional) /
# scheduled (recommended); NEVER PR-fast. Disabled by default.
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE   disabled (default) | enabled
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE  NVD data dir (default .sentinel-shield/cache/dependency-check)
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE  container image (used if no local binary)
# First run downloads the full NVD dataset (slow, hundreds of MB) into the cache dir; reuse it
# across runs. Findings may DUPLICATE OSV/Trivy/Grype (overlapping CVE sources) — that is expected.
# Missing tool / disabled -> unavailable (exit 0, NO file written, never fake-clean).
set -eu
OUT="${1:-reports/raw/dependency-check.json}"
mkdir -p "$(dirname "$OUT")"
MODE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE:-disabled}"
CACHE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE:-.sentinel-shield/cache/dependency-check}"
IMAGE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE:-}"

unavailable() { echo "[sentinel-shield] dependency-check unavailable: $1 (no report written)." >&2; exit 0; }

[ "$MODE" = enabled ] || unavailable "disabled by default (set SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled; slow, scheduled/nightly recommended)"
mkdir -p "$CACHE"
OUTDIR=$(CDPATH= cd -- "$(dirname "$OUT")" && pwd)

if command -v dependency-check >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check: scanning . (cache=$CACHE; first run downloads NVD — slow)" >&2
	dependency-check --scan . --format JSON --out "$OUT" --data "$CACHE" || true
elif [ -n "$IMAGE" ] && command -v docker >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check (container $IMAGE): scanning . (cache mounted)" >&2
	CACHE_ABS=$(CDPATH= cd -- "$CACHE" && pwd)
	docker run --rm -v "$PWD:/src" -v "$CACHE_ABS:/usr/share/dependency-check/data" -v "$OUTDIR:/report" "$IMAGE" \
		--scan /src --format JSON --out /report/"$(basename "$OUT")" || true
else
	unavailable "no local 'dependency-check' binary and no SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE+docker"
fi
exit 0
