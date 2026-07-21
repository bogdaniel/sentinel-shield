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
# _dc_mode_of <path> — octal mode of a path, portable across GNU and BSD stat. Empty when it
# cannot be read, in which case no restore is attempted.
_dc_mode_of() {
	[ -e "$1" ] || return 0
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# _dc_restore_perms — put the bind-mounted dirs back the way they were found. Called from the
# EXIT trap so an interrupted or failed scan cannot leave reports/raw world-writable.
#
# DEFINED BEFORE cleanup_secret ON PURPOSE: the trap is registered immediately below and fires
# on EVERY exit path, including the early `unavailable()` returns near the top of this script.
# Defining these helpers further down made the trap call an undefined function on those paths,
# which exits 127 and was reported by the main-gate harness as a wrapper failure.
_dc_restore_perms() {
	# NOT `chmod -R "$mode"`: the captured mode is the ROOT DIRECTORY's (e.g. 755), and
	# applying it recursively would mark every FILE inside executable and overwrite its real
	# permissions — corrupting the cache to undo a relaxation. Restore the root itself
	# directly, then strip ONLY the `other`-write bit the relaxation added.
	[ -n "${DC_MODE_CACHE:-}" ] && [ -n "${CACHE_ABS:-}" ] && chmod "$DC_MODE_CACHE" "$CACHE_ABS" 2>/dev/null || true
	[ -n "${DC_MODE_OUT:-}" ] && [ -n "${OUTDIR:-}" ] && chmod "$DC_MODE_OUT" "$OUTDIR" 2>/dev/null || true
	if [ "${SENTINEL_SHIELD_DC_RELAX_PERMS:-0}" = "1" ]; then
		# `o-w` undoes the security-relevant part of `a+rwX`: WORLD-writable reports, which
		# is the actual defect (the summary builder trusts reports/raw, so a world-writable
		# report dir lets any local user forge evidence between scan and build).
		# Residual, stated rather than hidden: per-file modes were not captured before the
		# relaxation, so a file that was 0644 comes back 0664 — the GROUP-write bit can
		# survive. Stripping `g-w` unconditionally would break a legitimately
		# group-writable shared cache, which is a real CI setup. This path is opt-in and
		# unnecessary in the default configuration (the container runs as the host user),
		# so the narrow undo is the right trade.
		[ -n "${CACHE_ABS:-}" ] && chmod -R o-w "$CACHE_ABS" 2>/dev/null || true
		[ -n "${OUTDIR:-}" ] && chmod -R o-w "$OUTDIR" 2>/dev/null || true
	fi
	return 0
}

cleanup_secret() {
	[ -n "$PROPDIR" ] && rm -rf "$PROPDIR" 2>/dev/null || true
	_dc_restore_perms
}
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
# v0.1.30: clear STALE H2/update lock files left by a previous run that was killed mid-update
# (CI timeout, cancelled job, or a restored partial cache). A stale `odc.update.lock` or H2 `*.lock`
# makes Dependency-Check fail with "Unable to obtain an exclusive lock on the H2 database". This only
# removes LOCK files — never the NVD data itself (full cache reset is the workflow's job, see
# docs/dependency-check-ci-cache.md). Safe no-op when the cache is clean or absent.
find "$CACHE" -type f \( -name '*.lock' -o -name 'odc.update.lock' \) -delete 2>/dev/null || true
OUTDIR=$(CDPATH= cd -- "$(dirname "$OUT")" && pwd)
TO=$(timeout_prefix)

# Build a propertyfile carrying the NVD API key, if one was provided. This keeps the key OFF the
# command line (no process-list exposure) and out of every log line. Paths produced by `mktemp -d`
# contain no spaces, so the SC2086-disabled unquoted expansions below are safe.
#
# v0.1.29: the file MUST be readable by the Dependency-Check CONTAINER, which runs as a different
# UID than the host. A 0600 file in a 0700 dir is unreadable inside the container on Linux Docker/CI
# (`FileNotFoundException ... Permission denied`) — that is why DC never ran in the v0.1.28 CI run.
# The key file is 0600 inside a 0700 mktemp dir and is NEVER relaxed: the container is run as
# the HOST user (--user "$(id -u):$(id -g)"), so it can read the mount without the file being
# readable by every other local user. The key stays OFF the command line / logs / report /
# commits, and the temp dir is removed on exit (trap).
DC_SECRET_ARG=""            # local-binary path: `--propertyfile <host-path>`
DC_SECRET_MOUNT=""          # docker path: read-only bind mount `host:container:ro`
DC_SECRET_CONTAINER_ARG=""  # docker path: `--propertyfile <container-path>`
if [ -n "$NVD_API_KEY_VALUE" ]; then
	PROPDIR=$(mktemp -d 2>/dev/null) || unavailable "could not create temp dir for the NVD API key"
	# 0600 under a 0700 dir. This previously relaxed to 755/644 so a DIFFERENT container UID
	# could read it — publishing a live credential to every local user for the duration of a
	# documented "slow, hundreds of MB" NVD download. The container is instead run as the
	# HOST user (--user below), so the default private mode is sufficient and no other user
	# on the machine can read the key.
	umask 077
	printf 'nvd.api.key=%s\n' "$NVD_API_KEY_VALUE" > "$PROPDIR/dependency-check.properties"
	chmod 700 "$PROPDIR"
	chmod 600 "$PROPDIR/dependency-check.properties"
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
	# v0.1.30: the Dependency-Check container runs as a NON-ROOT user, but the bind-mounted NVD data
	# dir and report dir are owned by the host UID. Without write access the container cannot create
	# or lock the H2 database — it fails with "Unable to obtain an exclusive lock on the H2 database"
	# / "No documents exist" (the v0.1.29/30 CI failure) even on a fresh cache. Make both dirs
	# container-writable (NVD data + reports are not secret; the key lives only in the propertyfile).
	# The container needs write access to the bind-mounted cache and report dirs. Two things
	# changed here:
	#   * it runs as the HOST user (--user below), so no permission relaxation is needed for
	#     the common case at all; and
	#   * when a relaxation IS still applied as a fallback, the ORIGINAL modes are captured
	#     and RESTORED on exit. The previous code left `reports/raw` world-writable
	#     PERMANENTLY. Those reports are integrity-critical — the summary builder trusts
	#     them — so any local user could rewrite a scanner report between the scan and the
	#     build. "Reports are not secret" was true about confidentiality and irrelevant to
	#     the actual risk.
	DC_MODE_CACHE=$(_dc_mode_of "$CACHE_ABS")
	DC_MODE_OUT=$(_dc_mode_of "$OUTDIR")
	if [ "${SENTINEL_SHIELD_DC_RELAX_PERMS:-0}" = "1" ]; then
		chmod -R a+rwX "$CACHE_ABS" "$OUTDIR" 2>/dev/null || true
	fi
	# shellcheck disable=SC2086
	$TO docker run --rm --user "$(id -u):$(id -g)" \
		-v "$PWD:/src" -v "$CACHE_ABS:/usr/share/dependency-check/data" -v "$OUTDIR:/report" \
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
