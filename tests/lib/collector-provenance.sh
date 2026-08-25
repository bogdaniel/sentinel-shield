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

# The helper derives digests with ne_sha256, so it takes responsibility for having it rather than
# leaving each caller to remember. A caller that forgot produced provenance with an EMPTY digest --
# which still fails the binding, but for a reason that looks like the collector's fault.
if ! command -v ne_sha256 >/dev/null 2>&1; then
	# shellcheck source=/dev/null
	. "${CP_LIB_DIR:-${ROOT:-.}/scripts/lib}/normalized-evidence.sh"
fi

cp_tool_for() { # the identity the collector will demand of its producer
	case "${1%.sh}" in
	trivy)        printf 'trivy-fs' ;;
	osv-scanner)  printf 'osv-scanner' ;;
	grype)        printf 'grype' ;;
	syft)         printf 'syft' ;;
	*)            printf '%s' "${1%.sh}" ;;
	esac
}

# cp__finding_count — how many findings the report carries, across the native shapes these suites
# use. Unknown shapes count zero, which keeps the default at completed-clean.
cp__finding_count() {
	jq -r '[ (.matches[]?),
	         (.results[]?.packages[]?.vulnerabilities[]?),
	         (.Results[]?.Vulnerabilities[]?), (.Results[]?.Secrets[]?),
	         (.runs[]?.results[]?), (.dependencies[]?.vulnerabilities[]?) ] | length' \
		"$1" 2>/dev/null || printf '0'
}

cp_write() {
	_cp_rep="$1"; _cp_tool=$(cp_tool_for "$2")
	_cp_mode="${4:-filesystem}"; _cp_sub="${5:-}"
	# The completion state is DERIVED from the report unless the caller states one. A real
	# transaction records completed-findings when the scanner found something, so defaulting every
	# fixture to completed-clean manufactured provenance that CONTRADICTS its own report — and the
	# collectors that check for exactly that contradiction were right to refuse it.
	if [ -n "${3:-}" ]; then
		_cp_state="$3"
	elif [ "$(cp__finding_count "$_cp_rep")" -gt 0 ] 2>/dev/null; then
		_cp_state="completed-findings"
	else
		_cp_state="completed-clean"
	fi
	_cp_dig=$(ne_sha256 "$_cp_rep") || _cp_dig=""
	# An empty digest would produce provenance that cannot bind, and a test would then be
	# debugging the collector instead of its own fixture.
	[ -n "$_cp_dig" ] || { printf '%s\n' "cp_write: could not digest $_cp_rep" >&2; return 1; }
	jq -n --arg t "$_cp_tool" --arg d "$_cp_dig" --arg s "$_cp_state" \
		--arg m "$_cp_mode" --arg sub "$_cp_sub" \
		'{contract:"sentinel-shield/scanner-transaction@1", tool:$t, completion:{state:$s},
		  report:{sha256:$d}, target:{identity:$sub, mode:$m}}' > "${_cp_rep%.json}.provenance.json"
}
