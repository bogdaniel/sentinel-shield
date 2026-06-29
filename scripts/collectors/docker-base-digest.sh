#!/bin/sh
# Sentinel Shield collector — Docker base-image digest audit.
#   un-digested base images -> unsafe_docker
# Input: reports/raw/docker-base-digest.json — array of findings from
# scripts/audit-docker-base-digest.sh ([{file,line,image,code,reason}, ...]).
# Distinct from Hadolint DL3018; the builder SUMS unsafe_docker across both collectors.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="docker_base_digest"
INPUT="reports/raw/docker-base-digest.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: docker-base-digest.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object for the Docker base-image digest audit.
Input: array of un-digested base findings. Count -> unsafe_docker.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_collector_guard "$TOOL" "$INPUT"

N=$(jq 'if type == "array" then length else 0 end' "$INPUT")
if [ "$N" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(jq -n --arg s "$STATUS" --argjson n "$N" '{status: $s, undigested: $n}')
OV=$(jq -n --argjson n "$N" '{unsafe_docker: $n}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
