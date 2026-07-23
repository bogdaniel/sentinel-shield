#!/bin/sh
# Sentinel Shield prod test — tool-wiring referential integrity.
#
# Two sources of truth wire the same tools: profile manifests declare a per-tool `runner` and
# `report`, while build-security-summary.sh's TOOL_TABLE maps a raw report to its collector.
# Drift is silent — a dangling runner/collector path only surfaces at runtime. This asserts
# every referenced script actually exists on disk.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BSS="$ROOT/scripts/build-security-summary.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq required"; exit 1; }
[ -f "$BSS" ] || { fail "missing $BSS"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss275)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

# (a) every manifest `runner` path exists on disk.
for m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
	[ -f "$m" ] || continue
	jq -r '(.tools // {}) | to_entries[] | (.value.runner // empty)' "$m" 2>/dev/null
done | sort -u > "$WORK/runners"
: > "$WORK/miss-runners"
while IFS= read -r r; do
	[ -n "$r" ] || continue
	[ -f "$ROOT/$r" ] || { printf 'FAIL: manifest runner does not exist: %s\n' "$r"; echo x >> "$WORK/miss-runners"; }
done < "$WORK/runners"
if [ ! -s "$WORK/miss-runners" ]; then pass "all manifest runner paths exist"; else fail "$(wc -l < "$WORK/miss-runners") manifest runner path(s) missing (see above)"; fi

# (b) every TOOL_TABLE collector-script (3rd column) exists in scripts/collectors/.
# Extract the TOOL_TABLE assignment: lines of  key|raw|collector|emit.
awk "/^TOOL_TABLE='/{f=1} f{print} /'\$/{if(f)exit}" "$BSS" | tr -d "'" | grep '|' > "$WORK/tt"
: > "$WORK/miss-collectors"
while IFS='|' read -r _k _raw _col _emit; do
	case "$_col" in ''|TOOL_TABLE*) continue ;; esac
	[ -f "$ROOT/scripts/collectors/$_col" ] || { printf 'FAIL: TOOL_TABLE collector missing: %s (row %s)\n' "$_col" "$_k"; echo x >> "$WORK/miss-collectors"; }
done < "$WORK/tt"
if [ ! -s "$WORK/miss-collectors" ]; then pass "all TOOL_TABLE collector scripts exist"; else fail "$(wc -l < "$WORK/miss-collectors") TOOL_TABLE collector(s) missing (see above)"; fi
_tt=$(cat "$WORK/tt")

# Sanity: TOOL_TABLE was actually parsed (guards against a format change silently emptying it).
_rows=$(printf '%s\n' "$_tt" | grep -c '|' || true)
[ "$_rows" -ge 10 ] && pass "TOOL_TABLE parsed ($_rows rows)" \
	|| fail "TOOL_TABLE parse yielded only $_rows rows — parser likely broke"

[ "$FAILED" -eq 0 ] && printf '\n275-tool-wiring-integrity: 0 failure(s)\nAll tool-wiring integrity assertions passed.\n' || {
	printf '\n275-tool-wiring-integrity: FAILURES above.\n'; exit 1; }
