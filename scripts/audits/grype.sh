#!/bin/sh
# Sentinel Shield audit wrapper — Grype (v0.1.19). Main-gate / nightly only (never PR-fast).
# Modes (SENTINEL_SHIELD_GRYPE_MODE): sbom (default) | fs.
#   sbom: scan an existing Syft SBOM (SENTINEL_SHIELD_GRYPE_SBOM_PATH, default reports/sbom.spdx.json).
#         If the SBOM is missing this is UNAVAILABLE (no fake) — set MODE=fs to scan the tree instead.
#   fs:   scan the project root (explicit opt-in).
# Executor: local `grype` binary if present, else a Docker image (SENTINEL_SHIELD_GRYPE_IMAGE).
# Missing binary AND no usable image -> unavailable (exit 0, NO file written, never fake-clean).
# Output: reports/raw/grype.json (Grype native JSON; collector maps severities).
#
# PROVENANCE (v2 hardening): alongside the raw report this wrapper writes a sidecar
# reports/raw/grype.provenance.json recording the resolved source (local-binary vs
# docker-image), version, image ref/digest and platform, so the collector can tell
# 'scanner did not run' from 'scanner ran, empty report'. When the Docker path is used
# the image ref (and digest, if @sha256: pinned) is recorded. Best-effort: skipped only
# if jq is unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/isolated-tools.sh
. "$SCRIPT_DIR/../lib/isolated-tools.sh"
# shellcheck source=scripts/lib/bounded-process.sh
. "$SCRIPT_DIR/../lib/bounded-process.sh"

BP_TMP_OUT=$(mktemp); BP_TMP_ERR=$(mktemp)
trap 'rm -f "$BP_TMP_OUT" "$BP_TMP_ERR"' EXIT INT TERM

OUT="${1:-reports/raw/grype.json}"
mkdir -p "$(dirname "$OUT")"
PROV="${OUT%.json}.provenance.json"
PLATFORM=$(isolated_tool_platform)

MODE="${SENTINEL_SHIELD_GRYPE_MODE:-sbom}"
SBOM="${SENTINEL_SHIELD_GRYPE_SBOM_PATH:-reports/sbom.spdx.json}"
IMAGE="${SENTINEL_SHIELD_GRYPE_IMAGE:-}"

write_prov() { # write_prov <source> <version> <binpath> <imageref> <imagedigest>
	command_exists jq || { log_warn "grype: jq unavailable; provenance sidecar not written"; return 0; }
	isolated_tool_provenance_record "grype" "$1" "$2" "$4" "$5" "$3" "" "" "" "" "$PLATFORM" > "$PROV" \
		|| log_warn "grype: could not write provenance sidecar '$PROV'"
}

unavailable() { echo "[sentinel-shield] grype unavailable: $1 (no report written; collector reports unavailable)." >&2; write_prov "unresolved" "" "" "" ""; exit 0; }

# Resolve executor. The version probe and the docker-inspect digest resolution are BOUNDED
# (scripts/lib/bounded-process.sh): a hung binary or a wedged Docker daemon can no longer
# stall the scan indefinitely. SENTINEL_SHIELD_GRYPE_TIMEOUT_SECONDS overrides the version
# probe cap; SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS the docker inspect cap.
if command -v grype >/dev/null 2>&1; then
	EXEC="grype"
	_gbin=$(command -v grype)
	_gvto=$(bp_timeout scanner-version SENTINEL_SHIELD_GRYPE_TIMEOUT_SECONDS) || _gvto=30
	if bp_run scanner-version "$_gvto" "$BP_TMP_OUT" "$BP_TMP_ERR" -- grype version; then
		_gver=$(awk '/[Vv]ersion:/{print $2; exit}' "$BP_TMP_OUT") || _gver=""
	else
		[ "${BP_STATUS:-}" = "timed-out" ] && log_warn "grype: version probe exceeded ${_gvto}s; recording unknown version"
		_gver=""
	fi
	write_prov "local-binary" "$_gver" "$_gbin" "" ""
elif [ -n "$IMAGE" ] && command -v docker >/dev/null 2>&1; then
	EXEC="docker run --rm -v $PWD:/src -w /src $IMAGE"
	case "$IMAGE" in
		*@sha256:*) _gdig="sha256:${IMAGE##*@sha256:}" ;;
		*) _gpto=$(bp_timeout docker-probe) || _gpto=15
		   if bp_run docker-probe "$_gpto" "$BP_TMP_OUT" "$BP_TMP_ERR" -- \
				docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE"; then
				_gdig=$(head -n1 "$BP_TMP_OUT" 2>/dev/null) || _gdig=""
		   else
				[ "${BP_STATUS:-}" = "timed-out" ] && log_warn "grype: docker inspect exceeded ${_gpto}s (daemon unreachable); image digest unresolved"
				_gdig=""
		   fi
		   case "$_gdig" in *@sha256:*) _gdig="sha256:${_gdig##*@sha256:}" ;; *) _gdig="" ;; esac ;;
	esac
	write_prov "docker-image" "" "" "$IMAGE" "$_gdig"
else
	unavailable "no local 'grype' binary and no SENTINEL_SHIELD_GRYPE_IMAGE+docker"
fi

case "$MODE" in
	sbom)
		if [ ! -s "$SBOM" ]; then
			unavailable "SBOM '$SBOM' not found (run Syft first, or set SENTINEL_SHIELD_GRYPE_MODE=fs)"
		fi
		echo "[sentinel-shield] grype: scanning SBOM $SBOM -> $OUT" >&2
		# shellcheck disable=SC2086
		$EXEC sbom:"$SBOM" -o json --file "$OUT" || true
		;;
	fs)
		echo "[sentinel-shield] grype: filesystem scan (.) -> $OUT" >&2
		# shellcheck disable=SC2086
		$EXEC dir:. -o json --file "$OUT" || true
		;;
	*) unavailable "invalid SENTINEL_SHIELD_GRYPE_MODE='$MODE' (use sbom|fs)" ;;
esac
exit 0
