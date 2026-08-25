#!/bin/sh
# Sentinel Shield audit wrapper — Dockle container linting (#103).
#
# Dockle scans a BUILT image and never builds one. Two execution paths — a local binary, or Dockle
# itself running in a container — and the previous wrapper ran both through `|| true`, so a missing
# image, a stopped daemon and a permission denial all looked like a clean lint.
#
# The image is bound BY DIGEST where one is available: a mutable tag names a different image
# tomorrow, and evidence that cannot say which bytes it examined cannot gate a release.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/dockle.json}"
st_begin dockle "$OUT" || exit 1
IMG="${SENTINEL_SHIELD_IMAGE:-}"
DOCKLE_IMG="${SENTINEL_SHIELD_DOCKLE_IMAGE:-}"
ST_TARGET="$IMG"; ST_TARGET_MODE="container-image"

# No image is NOT-APPLICABLE: there is nothing to lint. It was exit 0 before, indistinguishable
# from a clean lint of an image that was never examined.
[ -n "$IMG" ] || { st_fail "$ST_STATE_NOTAPPLICABLE" "SENTINEL_SHIELD_IMAGE not set — no built image to scan"; exit 0; }
# The image reference must be a single token. A value carrying whitespace or a leading dash could
# otherwise inject options into the docker command line below.
case "$IMG" in
*[[:space:]]*) st_fail "$ST_STATE_ERROR" "image reference contains whitespace — refusing to build a command from it"; exit 0 ;;
-*)            st_fail "$ST_STATE_ERROR" "image reference begins with '-' — refusing an option-like target"; exit 0 ;;
esac
case "$IMG" in *@sha256:*) ST_IMAGE_DIGEST="${IMG#*@}" ;; *) ST_IMAGE_DIGEST="" ;; esac

if command_exists dockle; then
	ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v dockle)
	ST_VERSION=$(st_probe_version dockle --version)
	st_execute scanner-run dockle --exit-code 0 -f json -o "$(st_report_path)" "$IMG"
elif [ -n "$DOCKLE_IMG" ] && command_exists docker; then
	ST_EXECUTOR="docker-image"; ST_IMAGE="$DOCKLE_IMG"
	case "$DOCKLE_IMG" in *@sha256:*) : ;; *) log_warn "dockle: scanner image '$DOCKLE_IMG' is a mutable tag; pin by digest for reproducible evidence" ;; esac
	# Explicit argument vector, never a whitespace command string: the report is written inside
	# the private workspace, which is bind-mounted read-write for exactly that purpose.
	st_execute scanner-run docker run --rm \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(st_workspace):/ssreport" \
		"$DOCKLE_IMG" --exit-code 0 -f json -o /ssreport/report.json "$IMG"
else
	st_fail "$ST_STATE_UNAVAILABLE" "no local 'dockle' binary and no SENTINEL_SHIELD_DOCKLE_IMAGE with docker"
	exit 0
fi

[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "dockle exceeded its bounded runtime"; exit 0; }
case "$ST_EXIT" in
0) : ;;
*) st_fail "$ST_STATE_ERROR" "dockle exited $ST_EXIT — missing image, daemon, permission or internal failure"; exit 0 ;;
esac
sc_dockle_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "dockle report rejected: ${SC_REASON:-unknown}"; exit 0; }

_dk_fatal=$(jq -r '[.details[]? | select((.level // "") == "FATAL" or (.level // "") == "WARN")] | length' "$(st_report_path)" 2>/dev/null) || _dk_fatal=0
if [ "${_dk_fatal:-0}" -gt 0 ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
