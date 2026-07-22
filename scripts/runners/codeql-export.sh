#!/bin/sh
# Sentinel Shield runner — CodeQL SARIF export (v0.1.14). CodeQL itself runs via the
# github/codeql-action; this copies the produced SARIF to reports/raw/codeql.json for the
# collector. Never fakes: if no SARIF is found, writes nothing and exits 0 (unavailable).
set -eu
OUT="reports/raw/codeql.json"; SARIF=""
while [ $# -gt 0 ]; do case "$1" in
  --sarif) SARIF="${2:?--sarif requires a value}"; shift 2 ;;
  --output) OUT="${2:?--output requires a value}"; shift 2 ;;
  -h | --help) printf 'Usage: codeql-export.sh [--sarif <path>] [--output <path>]\n'; exit 0 ;;
  *) echo "[sentinel-shield] codeql-export: unknown argument: $1" >&2; exit 2 ;;
esac; done
mkdir -p "$(dirname "$OUT")"
# Search only the codeql-action output dir, NOT the whole repo: a stray/fixture *.sarif
# anywhere in a PR checkout could otherwise be exported as the CodeQL evidence.
[ -z "$SARIF" ] && SARIF=$(find codeql-results "${RUNNER_TEMP:-/nonexistent}/codeql_databases" -name '*.sarif' 2>/dev/null | head -1)
if [ -z "$SARIF" ] || [ ! -f "$SARIF" ]; then
  echo "[sentinel-shield] no CodeQL SARIF found; skipping (collector reports unavailable)." >&2
  exit 0
fi
cp "$SARIF" "$OUT"
echo "[sentinel-shield] codeql: exported $SARIF -> $OUT" >&2
exit 0
