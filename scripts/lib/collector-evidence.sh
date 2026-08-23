# shellcheck shell=sh
# Sentinel Shield — collector evidence binding (#135, #136, #137, #184, #185).
#
# THE CONSUMER HALF OF THE PRODUCER/CONSUMER CONTRACT.
#
# scripts/lib/scanner-transaction.sh publishes a report and its provenance together. This file is
# what makes that guarantee worth something: before a collector interprets a single field, it
# checks that the report in front of it is the one this run produced.
#
# WHAT WAS WRONG. Collectors trusted FILE EXISTENCE and JSON parseability. `{}` satisfied the Syft
# collector; `{"matches":[]}` read as a clean Grype scan; `{"results":[]}` read as a clean OSV
# scan. None of those documents proves a scanner ran, and a stale report from last week satisfies
# all three checks exactly as well as a fresh one.
#
# WHAT IS CHECKED HERE, once, for every collector:
#
#   1. provenance exists and is a scanner-transaction record;
#   2. the recorded digest is the digest of THE REPORT ON DISK -- not a report, this one;
#   3. the completion state is a state that may carry evidence at all;
#   4. the producer identity matches the collector reading it;
#   5. the subject/target is the one that was requested, where the caller knows it.
#
# Tool semantics stay in scanner-contracts.sh. This file never inspects findings.

[ -n "${SS_COLLECTOR_EVIDENCE_SH:-}" ] && return 0
SS_COLLECTOR_EVIDENCE_SH=1
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "${SS_LIB_DIR:-scripts/lib}/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/normalized-evidence.sh
. "${SS_LIB_DIR:-scripts/lib}/normalized-evidence.sh"

CE_CONTRACT="sentinel-shield/scanner-transaction@1"

# ce_provenance_path <report> — the sidecar the transaction publishes beside a report.
ce_provenance_path() { printf '%s' "${1%.json}.provenance.json"; }

# ce_bind <report> <expected-tool> [expected-subject]
#
# Returns 0 only when the report is bound to a current, completed, matching scan.
# CE_STATE / CE_REASON / CE_SUBJECT / CE_DIGEST are set for the caller.
ce_bind() {
	_ce_report=${1:?ce_bind: report path required}
	_ce_tool=${2:?ce_bind: expected tool required}
	_ce_subject=${3:-}
	CE_STATE=""; CE_REASON=""; CE_SUBJECT=""; CE_DIGEST=""

	command_exists jq || { CE_REASON="jq unavailable; evidence cannot be bound"; return 1; }
	[ -f "$_ce_report" ] || { CE_REASON="no report at '$_ce_report'"; return 1; }

	_ce_prov=$(ce_provenance_path "$_ce_report")
	# MISSING PROVENANCE IS NOT A MINOR OMISSION. A report with no provenance is exactly the
	# forgeable artifact this batch exists to reject: two bytes of plausible JSON and no evidence
	# that any scanner ran.
	[ -f "$_ce_prov" ] || { CE_REASON="no provenance beside '$_ce_report' — nothing proves a scan produced it"; return 1; }
	jq -e --arg c "$CE_CONTRACT" '.contract == $c' "$_ce_prov" >/dev/null 2>&1 \
		|| { CE_REASON="provenance is not a scanner-transaction record"; return 1; }

	# IDENTITY. A Grype report cannot satisfy a Trivy contract, and a filesystem scan cannot
	# satisfy an image contract, however well-formed either is.
	_ce_ptool=$(jq -r '.tool // ""' "$_ce_prov" 2>/dev/null) || _ce_ptool=""
	[ "$_ce_ptool" = "$_ce_tool" ] \
		|| { CE_REASON="provenance names producer '$_ce_ptool', not '$_ce_tool'"; return 1; }

	# DIGEST BINDING. This is what separates "a report" from "this report": a stale document left
	# beside fresh provenance, or fresh provenance beside a swapped report, both fail here.
	CE_DIGEST=$(jq -r '.report.sha256 // ""' "$_ce_prov" 2>/dev/null) || CE_DIGEST=""
	[ -n "$CE_DIGEST" ] || { CE_REASON="provenance records no report digest"; return 1; }
	_ce_actual=$(ne_sha256 "$_ce_report" 2>/dev/null) || _ce_actual=""
	[ "$CE_DIGEST" = "$_ce_actual" ] \
		|| { CE_REASON="report digest does not match provenance — the report is stale, swapped or forged"; return 1; }

	# COMPLETION STATE. unavailable, not-applicable, timeout and execution-error are truthful
	# answers, and none of them may be read as a scan result.
	CE_STATE=$(jq -r '.completion.state // ""' "$_ce_prov" 2>/dev/null) || CE_STATE=""
	case "$CE_STATE" in
	completed-clean|completed-findings|completed-no-targets) : ;;
	"") CE_REASON="provenance records no completion state"; return 1 ;;
	*)  CE_REASON="completion state '$CE_STATE' does not carry scan evidence"; return 1 ;;
	esac

	CE_SUBJECT=$(jq -r '.target.identity // ""' "$_ce_prov" 2>/dev/null) || CE_SUBJECT=""
	if [ -n "$_ce_subject" ]; then
		[ "$CE_SUBJECT" = "$_ce_subject" ] \
			|| { CE_REASON="provenance describes subject '$CE_SUBJECT', not the requested '$_ce_subject'"; return 1; }
	fi
	return 0
}

# ce_target_mode <report> — the producer's declared target mode, so a collector can refuse
# evidence from the wrong scan type (a filesystem contract must not accept an image scan).
ce_target_mode() {
	_ce_p=$(ce_provenance_path "$1")
	[ -f "$_ce_p" ] || { printf ''; return 1; }
	jq -r '.target.mode // ""' "$_ce_p" 2>/dev/null || printf ''
}
