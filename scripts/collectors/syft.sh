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
# A ZERO-PACKAGE SBOM IS STILL LEGITIMATE -- a repository really can have no resolved
# dependencies. What is NOT legitimate is `{}`. The two were indistinguishable here: a forged
# empty object fell through to a package count of 0 and emitted status "pass", so two bytes of
# JSON satisfied a gate that five profiles wire as `missing_behavior: fail` (#135).
#
# The difference is DOCUMENT METADATA, not package count: an spdxVersion, a creation record and a
# named source prove a run produced the document, whatever it found. sc_syft_validate requires
# them, and ce_bind separately proves the document belongs to THIS run.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/collector-evidence.sh
. "$SCRIPT_DIR/../lib/collector-evidence.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SCRIPT_DIR/../lib/scanner-contracts.sh"

TOOL="syft"
INPUT="reports/raw/syft.json"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: syft.sh [--input <path>] [--tool-name <name>] [--producer-key <key>]
Emit a Sentinel Shield collector object (stdout) for a Syft SBOM report.
Reports package inventory size; contributes 0 to all vulnerability counters.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--tool-name) TOOL="${2:?--tool-name requires a value}"; shift 2 ;;
		--producer-key) PRODUCER="${2:?--producer-key requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_collector_guard "$TOOL" "$INPUT"

# EVIDENCE BINDING FIRST, before a single field is read. A report with no provenance, a digest that
# does not match, a producer that is not syft, or a completion state that carries no scan result is
# refused here -- and a refused run reports execution-error rather than inheriting the previous
# run's success.
if ! ce_bind "$INPUT" "syft" "${SENTINEL_SHIELD_SYFT_SUBJECT:-}"; then
	log_error "$TOOL: evidence rejected — ${CE_REASON:-unbound}"
	REPORT=$(jq -n --arg r "${CE_REASON:-unbound}" '{status:"execution-error", packages:0, gated:false, reason:$r}')
	ss_emit_collector "$TOOL" "execution-error" "$REPORT" '{}'
	exit 0
fi

# STRUCTURE SECOND, through the same contract the producer validated against, so producer and
# consumer cannot disagree about what an SBOM is.
if ! sc_syft_validate "$INPUT"; then
	log_error "$TOOL: not a valid SBOM — ${SC_REASON:-unknown}"
	REPORT=$(jq -n --arg r "${SC_REASON:-unknown}" '{status:"execution-error", health:"invalid-output", packages:0, gated:false, reason:$r}')
	ss_emit_collector "$TOOL" "execution-error" "$REPORT" '{}'
	exit 0
fi

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

# AN INVENTORY, NOT A VERDICT. The package count is reported and contributes zero to every
# vulnerability counter: folding a dependency list into a findings bucket would report an ordinary
# project as insecure. Judging these packages is grype/osv/trivy's work, downstream.
REPORT=$(jq -n --argjson n "$N" --arg shape "${SC_SHAPE:-unknown}" --arg state "$CE_STATE" \
	'{status:"pass", packages:$n, inventory_shape:$shape, completion:$state, gated:false}')
ss_emit_collector "$TOOL" "pass" "$REPORT" '{}'
