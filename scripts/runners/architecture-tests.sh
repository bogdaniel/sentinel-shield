#!/bin/sh
# Sentinel Shield runner — architecture tests (v0.1.14). Runs the project's architecture test
# command from $SENTINEL_SHIELD_ARCH_TEST_CMD (e.g. "vendor/bin/pest --group=arch"). If unset,
# reports unavailable (no fake). Maps pass->0 / fail->violations:1 via reports/raw/architecture-tests.json.
set -eu
OUT="${1:-reports/raw/architecture-tests.json}"
mkdir -p "$(dirname "$OUT")"
CMD="${SENTINEL_SHIELD_ARCH_TEST_CMD:-}"
if [ -z "$CMD" ]; then
  echo "[sentinel-shield] SENTINEL_SHIELD_ARCH_TEST_CMD not set; architecture tests unavailable." >&2
  exit 0
fi
if sh -c "$CMD" >/tmp/ss-arch.log 2>&1; then V=0; else V=1; fi
jq -n --argjson v "$V" '{violations:$v}' > "$OUT"
echo "[sentinel-shield] architecture-tests: violations=$V -> $OUT" >&2
exit 0
