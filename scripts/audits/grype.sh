#!/bin/sh
# Sentinel Shield audit wrapper — Grype vulnerability scan (#104).
#
# This adapter had grown its own partial lifecycle: bounded probes and a provenance sidecar, but
# assembled independently of the other nine. It now uses the shared transaction, so provenance is
# finalized only AFTER the report validates rather than beside it.
#
# THE DEFECT #104 NAMES: the Docker path was built from a whitespace command string, so a project
# path containing a space, tab or shell metacharacter was split into fragments, and a hostile image
# value could inject options into the docker command line. Every execution below passes an explicit
# argument vector, and the image reference is validated as a single non-option token before it is
# used.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/grype.json}"
st_begin grype "$OUT" || exit 1
MODE="${SENTINEL_SHIELD_GRYPE_MODE:-sbom}"
SBOM="${SENTINEL_SHIELD_GRYPE_SBOM_PATH:-reports/sbom.spdx.json}"
IMAGE="${SENTINEL_SHIELD_GRYPE_IMAGE:-}"
ST_TARGET_MODE="$MODE"

case "$MODE" in
sbom)
	# A missing SBOM is UNAVAILABLE, not clean: there is nothing to scan, and st_begin has already
	# removed any previous report so nothing survives to imply otherwise.
	[ -f "$SBOM" ] || { st_fail "$ST_STATE_UNAVAILABLE" "SBOM '$SBOM' is absent — nothing to scan (set MODE=fs to scan the tree)"; exit 0; }
	ST_TARGET="$SBOM"; GRYPE_ARG="sbom:$SBOM" ;;
fs)
	ST_TARGET="${SENTINEL_SHIELD_GRYPE_TARGET:-.}"; GRYPE_ARG="dir:$ST_TARGET" ;;
*)
	st_fail "$ST_STATE_ERROR" "unknown SENTINEL_SHIELD_GRYPE_MODE '$MODE' (expected sbom|fs)"; exit 0 ;;
esac

if command_exists grype; then
	ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v grype)
	ST_VERSION=$(st_probe_version grype version)
	st_execute scanner-run grype "$GRYPE_ARG" -o json
elif [ -n "$IMAGE" ] && command_exists docker; then
	# THE IMAGE IS VALIDATED BEFORE IT REACHES A COMMAND LINE. A value carrying whitespace could
	# become several docker arguments; one beginning with '-' could become an option.
	case "$IMAGE" in
	*[[:space:]]*) st_fail "$ST_STATE_ERROR" "grype image reference contains whitespace — refusing to build a command from it"; exit 0 ;;
	-*)            st_fail "$ST_STATE_ERROR" "grype image reference begins with '-' — refusing an option-like value"; exit 0 ;;
	esac
	# THE SCANNER CONTAINER IS DIGEST-PINNED FOR GATED USE (#103-AC4), on the same terms as dockle.
	# A warning here was the same defect the dockle adapter already had: a mutable tag names
	# different bytes tomorrow, so a gated verdict cannot rest on it. Gated modes refuse before the
	# scanner runs; report-only and baseline warn and still produce evidence.
	st_require_valid_mode || exit 0
	case "$IMAGE" in
	*@sha256:*)
		_gy_dig="${IMAGE##*@sha256:}"
		case "$_gy_dig" in
		"" | *[!0-9a-f]*) st_fail "$ST_STATE_ERROR" "grype scanner image digest is malformed"; exit 0 ;;
		esac
		[ "${#_gy_dig}" -eq 64 ] || { st_fail "$ST_STATE_ERROR" "grype scanner image digest is not a 64-character sha256"; exit 0; }
		ST_IMAGE_DIGEST="${IMAGE#*@}"
		;;
	*)
		if st_gated; then
			st_fail "$ST_STATE_ERROR" "grype scanner image is a mutable tag and mode '$(st_mode)' gates releases — pin it by @sha256: digest"
			exit 0
		fi
		log_warn "grype: scanner image '$IMAGE' is a mutable tag; pin by digest before gated use"
		;;
	esac
	ST_EXECUTOR="docker-image"; ST_IMAGE="$IMAGE"
	# An explicit argument vector. The project is mounted at a fixed interior path, so a host path
	# containing spaces, tabs or Unicode never has to survive word splitting.
	_gy_host=$(CDPATH= cd -- "." && pwd)
	st_execute scanner-run docker run --rm -v "$_gy_host:/src" -w /src "$IMAGE" "$GRYPE_ARG" -o json
else
	st_fail "$ST_STATE_UNAVAILABLE" "no local 'grype' binary and no SENTINEL_SHIELD_GRYPE_IMAGE with docker"
	exit 0
fi

[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "grype exceeded its bounded runtime"; exit 0; }
case "$ST_EXIT" in
0|1) : ;;
*)   st_fail "$ST_STATE_ERROR" "grype exited $ST_EXIT — database, network, configuration or internal failure"; exit 0 ;;
esac
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "grype produced no report on stdout"; exit 0; }
sc_grype_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "grype report rejected: ${SC_REASON:-unknown}"; exit 0; }

# The report must describe the target we asked for, and the database it used is recorded so a
# clean result can be judged against the data behind it (#137 consumes both).
ST_DB_ID=$(jq -r '(.descriptor.db.built // .descriptor.db.checksum // "") | tostring' "$(st_report_path)" 2>/dev/null) || ST_DB_ID=""
# THE REPORT MUST DESCRIBE THE TARGET WE ASKED FOR. _gy_src was read and never compared, so a
# report about a different tree or SBOM satisfied the contract as long as it parsed. Comparison is
# EXACT after normalising the forms Grype legitimately emits — it echoes the scheme-qualified input
# ("dir:.", "sbom:path") in `userInput` and the bare resolved value in `source.target`. Substring
# matching is deliberately not used: "." is a substring of almost everything, and "app" of
# "app-fork".
_gy_src=$(jq -r '(.source.target // .source.userInput // "") | tostring' "$(st_report_path)" 2>/dev/null) || _gy_src=""
_gy_want="$ST_TARGET"
gy__norm() { # strip a leading grype scheme and any trailing slash, then canonicalise "./x" -> "x"
	_gn=${1#dir:}; _gn=${_gn#sbom:}; _gn=${_gn#file:}
	while [ "${_gn%/}" != "$_gn" ] && [ "$_gn" != "/" ]; do _gn=${_gn%/}; done
	case "$_gn" in ./?*) _gn=${_gn#./} ;; esac
	[ -n "$_gn" ] || _gn="."
	printf '%s' "$_gn"
}
# SCOPED TO fs MODE. There, ST_TARGET is a directory Grype echoes back as `dir:<path>` or the bare
# path, so equality is meaningful. In sbom mode `source.target` describes the SBOM's SUBJECT — the
# image or project the SBOM was made from — which is legitimately NOT the SBOM file path, so a path
# comparison there would reject correct evidence. The sbom path is bound by digest instead, through
# the provenance record the transaction already writes.
if [ "$MODE" = fs ]; then
	if [ -z "$_gy_src" ]; then
		st_fail "$ST_STATE_ERROR" "grype report records no source — it cannot be bound to the requested target"
		exit 0
	fi
	if [ "$(gy__norm "$_gy_src")" != "$(gy__norm "$_gy_want")" ]; then
		st_fail "$ST_STATE_ERROR" "grype report describes '$_gy_src', not the requested '$_gy_want'"
		exit 0
	fi
fi
_gy_matches=$(jq -r '.matches | length' "$(st_report_path)" 2>/dev/null) || _gy_matches=0
if [ "${_gy_matches:-0}" -gt 0 ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
