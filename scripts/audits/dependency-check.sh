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
# NVD API key (v0.1.26): raises the NVD rate limit so the first full dataset pull COMPLETES
# instead of HTTP 429. The key is NEVER logged, NEVER written to the report, NEVER committed.
# It is handed to Dependency-Check through a 0600 `--propertyfile` (NOT a CLI argument), so it
# never appears in the process list either. Env var name is fixed by the v0.1.26 Lane A spec.
NVD_API_KEY_VALUE="${SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY:-}"
PROPDIR=""
cleanup_secret() { [ -n "$PROPDIR" ] && rm -rf "$PROPDIR" 2>/dev/null || true; }
trap cleanup_secret EXIT INT TERM

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

# Build a propertyfile carrying the NVD API key, if one was provided. This keeps the key OFF the
# command line (no process-list exposure) and out of every log line. Paths produced by `mktemp -d`
# contain no spaces, so the SC2086-disabled unquoted expansions below are safe.
#
# v0.1.29: the file MUST be readable by the Dependency-Check CONTAINER, which runs as a different
# UID than the host. A 0600 file in a 0700 dir is unreadable inside the container on Linux Docker/CI
# (`FileNotFoundException ... Permission denied`) — that is why DC never ran in the v0.1.28 CI run.
# We relax to a world-readable file in a traversable mktemp dir so the container user can read it.
# The key stays OFF the command line / logs / report / commits; the only relaxation is that the key
# is local-readable for the (short) life of an EPHEMERAL temp dir that is removed on exit (trap).
DC_SECRET_ARG=""            # local-binary path: `--propertyfile <host-path>`
DC_SECRET_MOUNT=""          # docker path: read-only bind mount `host:container:ro`
DC_SECRET_CONTAINER_ARG=""  # docker path: `--propertyfile <container-path>`
if [ -n "$NVD_API_KEY_VALUE" ]; then
	PROPDIR=$(mktemp -d 2>/dev/null) || unavailable "could not create temp dir for the NVD API key"
	printf 'nvd.api.key=%s\n' "$NVD_API_KEY_VALUE" > "$PROPDIR/dependency-check.properties"
	# Container-readable (different UID): traversable dir + readable file. Ephemeral, removed on exit.
	chmod 755 "$PROPDIR"
	chmod 644 "$PROPDIR/dependency-check.properties"
	DC_SECRET_ARG="--propertyfile $PROPDIR/dependency-check.properties"
	DC_SECRET_MOUNT="$PROPDIR:/ss-secret:ro"
	DC_SECRET_CONTAINER_ARG="--propertyfile /ss-secret/dependency-check.properties"
	echo "[sentinel-shield] dependency-check: NVD API key provided — using the authenticated NVD rate limit (key redacted via propertyfile)." >&2
else
	echo "[sentinel-shield] dependency-check: no NVD API key (SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY unset) — open NVD rate limit; the first full dataset pull may HTTP 429." >&2
fi

# Run FOREGROUND so the step timeout/`timeout` actually applies. `|| true` keeps a valid JSON report
# even when the tool exits non-zero (findings). We validate the output afterward.
rc=0
if command -v dependency-check >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check: scanning . (cache=$CACHE; first run downloads NVD — slow)" >&2
	# shellcheck disable=SC2086
	$TO dependency-check --scan . --format JSON --out "$OUT" --data "$CACHE" $DC_SECRET_ARG || rc=$?
elif [ -n "$IMAGE" ] && command -v docker >/dev/null 2>&1; then
	echo "[sentinel-shield] dependency-check (container $IMAGE): scanning . (cache mounted, foreground)" >&2
	CACHE_ABS=$(CDPATH= cd -- "$CACHE" && pwd)
	# shellcheck disable=SC2086
	$TO docker run --rm -v "$PWD:/src" -v "$CACHE_ABS:/usr/share/dependency-check/data" -v "$OUTDIR:/report" \
		${DC_SECRET_MOUNT:+-v} ${DC_SECRET_MOUNT:+$DC_SECRET_MOUNT} "$IMAGE" \
		--scan /src --format JSON --out /report/"$(basename "$OUT")" --data /usr/share/dependency-check/data $DC_SECRET_CONTAINER_ARG || rc=$?
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
