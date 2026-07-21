#!/bin/sh
# Sentinel Shield collector — Syft (SBOM generation).
#
# Syft is a PRODUCER, not a scanner: it inventories packages, it does not judge them. So
# this collector contributes ZERO to every vulnerability counter. The tools that judge an
# SBOM (grype, osv-scanner, trivy) have their own collectors and their own channels;
# folding a package count into a vulnerability bucket would report an ordinary dependency
# list as findings.
#
# What this DOES enforce: syft.json must exist and parse. Five profiles wire syft as
# `missing_behavior: fail`, so its ABSENCE was already gated — but its contents were read
# by nothing, because syft.json had no TOOL_TABLE row. The file's presence was proven and
# its validity was not.
#
# An SBOM with zero packages is reported, not failed: the e2e fixtures legitimately ship
# `{}` placeholders, and a repo with no resolved dependencies is a real (if unusual) state.
# Failing on it would make this collector reject honest input.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="syft"
INPUT="reports/raw/syft.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: syft.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object (stdout) for a Syft SBOM report.
Reports package inventory size; contributes 0 to all vulnerability counters.
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

# Syft native JSON uses .artifacts[]; SPDX uses .packages[]. Accept either, default 0.
# NOT `(.artifacts|length)? // (.packages|length)?`: jq evaluates `null|length` to 0, and 0
# is not empty for `//`, so an SPDX report would short-circuit to 0 and silently report an
# EMPTY SBOM for a populated one. Test `has()` explicitly.
N=$(jq '
	if (type == "object") and has("artifacts") and (.artifacts | type == "array") then (.artifacts | length)
	elif (type == "object") and has("packages") and (.packages | type == "array") then (.packages | length)
	else 0 end | floor' "$INPUT" 2>/dev/null || printf 'x')
case "$N" in '' | *[!0-9]*)
	log_error "$TOOL: could not read a package count from '$INPUT'"
	exit 2 ;;
esac

REPORT=$(jq -n --argjson n "$N" '{status:"pass", packages:$n, gated:false}')
ss_emit_collector "$TOOL" "pass" "$REPORT" '{}'
