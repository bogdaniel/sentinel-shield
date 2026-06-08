#!/bin/sh
# Sentinel Shield runner — CodeQL SARIF export (v0.1.14). CodeQL itself runs via the
# github/codeql-action; this copies the produced SARIF to reports/raw/codeql.json for the
# collector. Never fakes: if no SARIF is found, writes nothing and exits 0 (unavailable).
set -eu
OUT="reports/raw/codeql.json"; SARIF=""
while [ $# -gt 0 ]; do case "$1" in
  --sarif) SARIF="${2:?}"; shift 2 ;;
  --output) OUT="${2:?}"; shift 2 ;;
  *) shift ;;
esac; done
mkdir -p "$(dirname "$OUT")"
[ -z "$SARIF" ] && SARIF=$(find . codeql-results -name '*.sarif' 2>/dev/null | head -1)
if [ -z "$SARIF" ] || [ ! -f "$SARIF" ]; then
  echo "[sentinel-shield] no CodeQL SARIF found; skipping (collector reports unavailable)." >&2
  exit 0
fi
cp "$SARIF" "$OUT"
echo "[sentinel-shield] codeql: exported $SARIF -> $OUT" >&2
exit 0
