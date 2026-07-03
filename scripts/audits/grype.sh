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

# Resolve executor.
if command -v grype >/dev/null 2>&1; then
	EXEC="grype"
	_gbin=$(command -v grype)
	_gver=$(grype version 2>/dev/null | awk '/[Vv]ersion:/{print $2; exit}') || _gver=""
	write_prov "local-binary" "$_gver" "$_gbin" "" ""
elif [ -n "$IMAGE" ] && command -v docker >/dev/null 2>&1; then
	EXEC="docker run --rm -v $PWD:/src -w /src $IMAGE"
	case "$IMAGE" in
		*@sha256:*) _gdig="sha256:${IMAGE##*@sha256:}" ;;
		*) _gdig=$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || true)
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
