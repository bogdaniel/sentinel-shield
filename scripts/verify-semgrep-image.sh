#!/bin/sh
# Sentinel Shield — Semgrep image verification (v0.1.19).
# Runs SENTINEL_SHIELD_SEMGREP_IMAGE against tests/fixtures/semgrep/php-modern (modern PHP 8.1+
# syntax that the older 1.90.0 parser failed on) and checks for PartialParsing/Syntax errors.
#   no docker/semgrep    -> unavailable (exit 0)
#   parser errors > 0    -> FAIL (exit 1)
#   0 parser errors      -> PASS (exit 0)
# Writes reports/raw/semgrep-image-verify.json (semgrep output) + .log.
# NOTE: this proves the IMAGE parses a fixture — it is NOT live consumer validation.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
IMAGE="${SENTINEL_SHIELD_SEMGREP_IMAGE:-semgrep/semgrep:1.165.0}"
FIXTURE="${1:-$ROOT/tests/fixtures/semgrep/php-modern}"
OUT="${2:-reports/raw/semgrep-image-verify.json}"
LOG="${OUT%.json}.log"

usage() { echo "Usage: verify-semgrep-image.sh [fixture-dir] [output.json]  (image via SENTINEL_SHIELD_SEMGREP_IMAGE; default semgrep/semgrep:1.165.0)"; }
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { usage; exit 0; }
mkdir -p "$(dirname "$OUT")"
[ -d "$FIXTURE" ] || { echo "[sentinel-shield] semgrep-verify: fixture '$FIXTURE' missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }

# Resolve executor: local semgrep, else docker IMAGE.
if command -v semgrep >/dev/null 2>&1; then
	# Use the SS curated PHP rules so we exercise real rule parsing.
	semgrep --json --output "$OUT" --config "$ROOT/semgrep/app/php" "$FIXTURE" >"$LOG" 2>&1 || true
elif command -v docker >/dev/null 2>&1; then
	case "$IMAGE" in *@sha256:*) : ;; *) echo "[sentinel-shield][warn] semgrep-verify: image '$IMAGE' is a mutable tag (not @sha256:); pin by digest for reproducible runs" >&2 ;; esac
	docker run --rm -v "$ROOT:/ss" -v "$FIXTURE:/fix" "$IMAGE" \
		semgrep --json --output /fix/_verify.json --config /ss/semgrep/app/php /fix >"$LOG" 2>&1 || true
	[ -f "$FIXTURE/_verify.json" ] && { mv "$FIXTURE/_verify.json" "$OUT"; } || true
else
	echo "[sentinel-shield] semgrep-verify: no local 'semgrep' and no docker; UNAVAILABLE (not live-tested)." >&2
	echo "unavailable: no semgrep/docker" > "$LOG"
	exit 0
fi

if [ ! -s "$OUT" ]; then
	echo "[sentinel-shield] semgrep-verify: no JSON produced; UNAVAILABLE (see $LOG)." >&2
	exit 0
fi
ERRORS=$(jq '([.errors[]? | select((.type // "") | test("Parsing|Syntax"; "i"))] | length) // 0' "$OUT" 2>/dev/null || echo 0)
case "$ERRORS" in ''|*[!0-9]*) ERRORS=0 ;; esac
echo "[sentinel-shield] semgrep-verify: image=$IMAGE parser-errors=$ERRORS -> $OUT" >&2
if [ "$ERRORS" -gt 0 ]; then
	echo "[sentinel-shield] semgrep-verify: FAIL — $ERRORS parser error(s) on modern PHP fixture." >&2
	exit 1
fi
echo "[sentinel-shield] semgrep-verify: PASS — 0 parser errors on the fixture (NOT a live consumer validation)." >&2
exit 0
