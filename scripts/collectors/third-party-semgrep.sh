#!/bin/sh
# Sentinel Shield collector — THIRD-PARTY suspicious-code Semgrep.
#
# Parses a SEPARATE Semgrep run over dependency/vendored code
# (reports/raw/third-party-semgrep.json) using the supply-chain rules under
# semgrep/supply-chain/third-party/. It does NOT read the normal app scan (reports/raw/semgrep.json)
# and its findings are kept in their own summary keys — they never mix into the
# app-code *_vulnerabilities buckets.
#
# Mapping is by rule metadata.sentinel_shield_category:
#   third_party_install_script_risk | third_party_obfuscation | third_party_network_behavior
# Any other/missing category falls back to: third_party_suspicious_code
#
# This is heuristic supply-chain triage, NOT a replacement for Trivy / composer audit
# / npm audit / Gitleaks / SBOM (those still handle dependency CVEs and secrets).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

TOOL="third_party_semgrep"
INPUT="reports/raw/third-party-semgrep.json"

usage() {
	cat <<'EOF'
Usage: third-party-semgrep.sh [--input <path>] [--tool-name <name>]
Emit a Sentinel Shield collector object for a third-party suspicious-code Semgrep
report (.results[]), counting by metadata.sentinel_shield_category.
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

# Missing/empty input -> unavailable (counts 0); invalid JSON -> exit 2 (fail safe).
ss_collector_guard "$TOOL" "$INPUT"

OV=$(jq '
	[ .results[]?
	  | (.extra.metadata.sentinel_shield_category // "")
	  | if (. == "third_party_install_script_risk"
	        or . == "third_party_obfuscation"
	        or . == "third_party_network_behavior")
	    then . else "third_party_suspicious_code" end
	] as $cat
	| {
		third_party_suspicious_code:     ([ $cat[] | select(. == "third_party_suspicious_code") ]     | length),
		third_party_install_script_risk: ([ $cat[] | select(. == "third_party_install_script_risk") ] | length),
		third_party_obfuscation:         ([ $cat[] | select(. == "third_party_obfuscation") ]         | length),
		third_party_network_behavior:    ([ $cat[] | select(. == "third_party_network_behavior") ]    | length)
	}' "$INPUT")

TOTAL=$(printf '%s' "$OV" | jq '[.[]] | add // 0')
if [ "$TOTAL" -gt 0 ]; then STATUS="fail"; else STATUS="pass"; fi
REPORT=$(printf '%s' "$OV" | jq --arg s "$STATUS" '{
	status: $s,
	suspicious_code: .third_party_suspicious_code,
	install_script_risk: .third_party_install_script_risk,
	obfuscation: .third_party_obfuscation,
	network_behavior: .third_party_network_behavior
}')
ss_emit_collector "$TOOL" "$STATUS" "$REPORT" "$OV"
