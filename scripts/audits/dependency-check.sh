#!/bin/sh
# Sentinel Shield audit wrapper — OWASP Dependency-Check (v0.1.21). SLOW — scheduled/nightly
# (recommended) / main-gate (optional); NEVER PR-fast. Disabled by default.
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE     disabled (default) | enabled
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE    NVD data dir (default .sentinel-shield/cache/dependency-check)
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE    container image (used if no local binary; digest-pin in prod)
#   SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT  optional wall-clock cap (e.g. 30m); applied FOREGROUND
#                                             via `timeout` if that binary is present. No detached
#                                             containers — a `docker run -d` would ignore step timeouts.
# First run downloads the full NVD dataset (slow, hundreds of MB) into the cache dir; reuse it
# across runs (actions/cache, monthly key — see docs/dependency-check-nightly-strategy.md). Findings
# may DUPLICATE OSV/Trivy/Grype (overlapping CVE sources) — that is expected.
#
# Honest contract (v0.1.21):
#   disabled                         -> unavailable, NO file (never fake-clean).
#   enabled + no binary/container    -> unavailable, NO file.
#   enabled + valid JSON produced    -> keep reports/raw/dependency-check.json (even on non-zero exit;
#                                       the collector/gate decides pass/fail).
#   enabled + tool exits w/o JSON    -> unavailable with reason; remove any partial/empty/invalid
#                                       file so the collector reports `unavailable` (NEVER fake-clean).
set -eu
OUT="${1:-reports/raw/dependency-check.json}"
mkdir -p "$(dirname "$OUT")"
MODE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE:-disabled}"
CACHE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE:-.sentinel-shield/cache/dependency-check}"
IMAGE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE:-}"
DC_TIMEOUT="${SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT:-}"

unavailable() { echo "[sentinel-shield] dependency-check unavailable: $1 (no report written)." >&2; exit 0; }

# remove a partial/empty/invalid output so a half-written file can never look clean.
discard_partial() { [ -f "$OUT" ] && rm -f "$OUT" 2>/dev/null || true; }

# valid_json <path> — true if the file is non-empty and parses. Uses jq if present (the collector
# requires jq anyway); otherwise a minimal structural check so the audit stays jq-optional.
valid_json() {
	[ -s "$1" ] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -e . "$1" >/dev/null 2>&1
	else
		# best-effort: first non-space byte is '{' or '['.
		case "$(tr -d '[:space:]' < "$1" | cut -c1)" in '{'|'[') return 0 ;; *) return 1 ;; esac
	fi
}

# timeout_prefix — echo a `timeout <dur>` prefix when requested and available; else nothing.
timeout_prefix() {
	[ -n "$DC_TIMEOUT" ] || return 0
	if command -v timeout >/dev/null 2>&1; then
		printf 'timeout %s' "$DC_TIMEOUT"
	else
		echo "[sentinel-shield] dependency-check: SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT set but 'timeout' not found; running without a cap." >&2
	fi
}

[ "$MODE" = enabled ] || unavailable "disabled by default (set SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled; slow, scheduled/nightly recommended)"
mkdir -p "$CACHE"
OUTDIR=$(CDPATH= cd -- "$(dirname "$OUT")" && pwd)
TO=$(timeout_prefix)

# Run FOREGROUND so the step timeout/`timeout` actually applies. `|| true` keeps a valid JSON report
# even when the tool exits non-zero (findings). We validate the output afterward.
rc=0
if command -v dependency-check >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check: scanning . (cache=$CACHE; first run downloads NVD — slow)" >&2
	# shellcheck disable=SC2086
	$TO dependency-check --scan . --format JSON --out "$OUT" --data "$CACHE" || rc=$?
elif [ -n "$IMAGE" ] && command -v docker >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check (container $IMAGE): scanning . (cache mounted, foreground)" >&2
	CACHE_ABS=$(CDPATH= cd -- "$CACHE" && pwd)
	# shellcheck disable=SC2086
	$TO docker run --rm -v "$PWD:/src" -v "$CACHE_ABS:/usr/share/dependency-check/data" -v "$OUTDIR:/report" "$IMAGE" \
		--scan /src --format JSON --out /report/"$(basename "$OUT")" --data /usr/share/dependency-check/data || rc=$?
else
	unavailable "no local 'dependency-check' binary and no SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE+docker"
fi

# Decide: keep valid JSON (even on non-zero exit), else discard partial and report unavailable.
if valid_json "$OUT"; then
	[ "$rc" -eq 0 ] || echo "[sentinel-shield] dependency-check exited $rc but produced valid JSON — kept for the collector/gate to decide." >&2
	echo "[sentinel-shield] dependency-check: report written -> $OUT" >&2
	exit 0
fi
discard_partial
unavailable "tool exited ${rc} without valid JSON (timed out, NVD download incomplete, or crashed) — no fake-clean report"
