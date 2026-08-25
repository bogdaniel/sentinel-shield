#!/bin/sh
# Sentinel Shield test library — provenance for collector inputs.
#
# ce_bind is ABSOLUTE: a collector reads no field until provenance exists, its digest matches THIS
# report, the completion state carries evidence, and the producer identity matches. There is no
# fixture exemption, by owner decision, because an exemption is exactly the hole a forged report
# would use.
#
# The consequence is that any suite feeding a collector a hand-written report must also produce the
# provenance a real scanner transaction would have written. Suites whose subject is something else
# entirely -- severity mapping, fail-closed arithmetic -- should not each reinvent that sidecar, so
# it lives here once. This is the same remedy applied to the e2e fixtures: supply what the binding
# requires, never relax the binding to accommodate a test.
#
# cp_write <report> <collector-basename> [state] [target-mode] [subject]

cp_tool_for() { # the identity the collector will demand of its producer
	case "${1%.sh}" in
	trivy)        printf 'trivy-fs' ;;
	osv-scanner)  printf 'osv-scanner' ;;
	grype)        printf 'grype' ;;
	syft)         printf 'syft' ;;
	*)            printf '%s' "${1%.sh}" ;;
	esac
}

cp_write() {
	_cp_rep="$1"; _cp_tool=$(cp_tool_for "$2")
	_cp_state="${3:-completed-clean}"; _cp_mode="${4:-filesystem}"; _cp_sub="${5:-}"
	_cp_dig=$(ne_sha256 "$_cp_rep") || _cp_dig=""
	jq -n --arg t "$_cp_tool" --arg d "$_cp_dig" --arg s "$_cp_state" \
		--arg m "$_cp_mode" --arg sub "$_cp_sub" \
		'{contract:"sentinel-shield/scanner-transaction@1", tool:$t, completion:{state:$s},
		  report:{sha256:$d}, target:{identity:$sub, mode:$m}}' > "${_cp_rep%.json}.provenance.json"
}
