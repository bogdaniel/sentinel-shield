# shellcheck shell=sh
# Sentinel Shield — per-scanner evidence contracts (#96-#105, #135-#137, #184-#185).
#
# TOOL SEMANTICS LIVE HERE; MECHANICS LIVE IN scanner-transaction.sh.
#
# Every function below answers a question only the specific tool can answer: what its exit codes
# mean, which report shapes are real, what proves the scan actually completed, and what target it
# claims to have examined.
#
# THE PRODUCER AND THE CONSUMER READ THE SAME CONTRACT. The wrapper validates before publishing
# and the collector validates before trusting, from these same functions -- so the two can no
# longer disagree about what a valid report is, which is exactly the gap between #96/#135,
# #99/#136, #104/#137 and #105/#184.
#
# THERE IS DELIBERATELY NO GENERIC VALIDATOR. "Parses as JSON" is what allowed `{}` to stand as an
# SBOM (#135) and `{"matches":[]}` to read as a clean vulnerability scan (#137). Each validator
# below names the fields that make its report meaningful and rejects anything else.

[ -n "${SS_SCANNER_CONTRACTS_SH:-}" ] && return 0
SS_SCANNER_CONTRACTS_SH=1
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "${SS_LIB_DIR:-scripts/lib}/sentinel-shield-common.sh"

_sc_jq() { command_exists jq || return 1; jq -e "$1" "$2" >/dev/null 2>&1; }
_sc_parses() { command_exists jq || return 1; jq -e . "$1" >/dev/null 2>&1; }

# ===========================================================================
# SYFT  (#96 producer, #135 consumer)
#
# A zero-package SBOM is legitimate -- a project really can have no dependencies -- so emptiness
# alone proves nothing either way. What distinguishes a real empty inventory from the forged `{}`
# is DOCUMENT METADATA: an SPDX version, a creation record, and a named source. All three are
# required whether the package array is empty or not.
# ===========================================================================
sc_syft_validate() { # sc_syft_validate <report>
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	# Native Syft JSON carries .artifacts + .source + .descriptor; SPDX carries .spdxVersion +
	# .creationInfo + .name. Both are accepted; anything carrying neither shape is not an SBOM.
	if _sc_jq 'has("spdxVersion")' "$1"; then
		_sc_jq '(.spdxVersion | type == "string") and (.spdxVersion | startswith("SPDX-"))' "$1" \
			|| { SC_REASON="spdxVersion missing or not an SPDX- version"; return 1; }
		_sc_jq '(.creationInfo | type == "object") and (.creationInfo.created | type == "string")' "$1" \
			|| { SC_REASON="creationInfo.created missing — no proof the document was produced by a run"; return 1; }
		_sc_jq '(.name | type == "string") and (.name | length > 0)' "$1" \
			|| { SC_REASON="document name (target identity) missing"; return 1; }
		_sc_jq 'has("packages") and (.packages | type == "array")' "$1" \
			|| { SC_REASON="packages is missing or not an array"; return 1; }
		SC_SHAPE="spdx"; SC_COUNT=$(jq -r '.packages | length' "$1" 2>/dev/null || printf '0'); return 0
	fi
	if _sc_jq 'has("artifacts")' "$1"; then
		_sc_jq '(.artifacts | type == "array")' "$1" || { SC_REASON="artifacts is not an array"; return 1; }
		_sc_jq '(.source | type == "object")' "$1" || { SC_REASON="source (target identity) missing"; return 1; }
		_sc_jq '(.descriptor.name | type == "string")' "$1" || { SC_REASON="descriptor.name missing — no producing tool recorded"; return 1; }
		SC_SHAPE="syft-native"; SC_COUNT=$(jq -r '.artifacts | length' "$1" 2>/dev/null || printf '0'); return 0
	fi
	SC_REASON="neither a native Syft document nor SPDX — an object without SBOM structure"
	return 1
}

# ===========================================================================
# TRIVY  (#99 producer, #136 consumer)
#
# Trivy reports findings through a non-zero exit when --exit-code is set, so exit status alone
# cannot separate "found vulnerabilities" from "database download failed". The report itself must
# prove an applicable scan ran: SchemaVersion plus a Results array, and NO report-level error.
# ===========================================================================
sc_trivy_validate() { # sc_trivy_validate <report>
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'has("SchemaVersion")' "$1" || { SC_REASON="SchemaVersion missing — not a Trivy report"; return 1; }
	# A schema this contract has never seen is not one it may reinterpret. Trivy has changed field
	# meanings across major schema revisions, so guessing at an unknown version risks reading a
	# future document with today's assumptions and reporting a confident wrong answer (#136-AC6).
	_sc_jq '(.SchemaVersion) as $v | ($v == 2 or $v == "2")' "$1" \
		|| { SC_REASON="unsupported Trivy SchemaVersion — this contract reads version 2"; return 1; }
	_sc_jq 'has("Results") or has("results")' "$1" || { SC_REASON="Results missing — the scan produced no result set"; return 1; }
	# A report-level error means a PARTIAL scan. Trivy still emits a document, and without this
	# check a database failure reads as a clean result (#136).
	if _sc_jq '((.Results // .results // []) | map(select(.Class == "error" or (.Type // "") == "error")) | length) > 0' "$1"; then
		SC_REASON="the report carries a result-level error — the scan is partial"; return 1
	fi
	# A REPORT-level error says the same thing about the whole document. Only the per-result form
	# was checked, so a scan that announced its own failure at the top level still read as clean.
	if _sc_jq '((.Error // .error // "") | tostring) != ""' "$1"; then
		SC_REASON="the report carries a report-level error — the scan is partial"; return 1
	fi
	SC_SHAPE="trivy"; return 0
}

# ===========================================================================
# GRYPE  (#104 producer, #137 consumer)
#
# `{"matches":[]}` is the forgeable shape: two bytes of structure and a reader concludes "clean".
# A real Grype report also carries .source (what was scanned) and .descriptor (what scanned it,
# and against which database).
# ===========================================================================
sc_grype_validate() { # sc_grype_validate <report>
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'has("matches") and (.matches | type == "array")' "$1" || { SC_REASON="matches missing or not an array"; return 1; }
	_sc_jq '(.source | type == "object")' "$1" || { SC_REASON="source missing — the report does not say what was scanned"; return 1; }
	_sc_jq '(.descriptor | type == "object") and (.descriptor.name | type == "string")' "$1" \
		|| { SC_REASON="descriptor missing — the report does not say what scanned it"; return 1; }
	SC_SHAPE="grype"; SC_COUNT=$(jq -r '.matches | length' "$1" 2>/dev/null || printf '0'); return 0
}

# ===========================================================================
# OSV  (#105 producer, #184 and #185 consumers)
#
# `{"results":[]}` is ambiguous by construction: it is emitted BOTH when nothing was scanned and
# when everything scanned was clean. The report alone cannot distinguish them, which is why #184
# requires discovery provenance rather than a richer report check.
# ===========================================================================
sc_osv_validate() { # sc_osv_validate <report>
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'has("results") and (.results | type == "array")' "$1" || { SC_REASON="results missing or not an array"; return 1; }
	SC_SHAPE="osv"
	SC_COUNT=$(jq -r '[.results[]?.packages[]?.vulnerabilities[]?] | length' "$1" 2>/dev/null || printf '0')
	# Sources scanned: the discovery evidence #184 asks for. Zero sources with zero findings is
	# no-targets; one or more sources with zero findings is a clean applicable scan.
	SC_SOURCES=$(jq -r '[.results[]?.source?.path?] | map(select(. != null)) | length' "$1" 2>/dev/null || printf '0')
	return 0
}

# ===========================================================================
# CHECKOV (#97) — documented object AND list shapes, both explicit.
# ===========================================================================
sc_checkov_validate() { # sc_checkov_validate <report>
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	if _sc_jq 'type == "array"' "$1"; then
		_sc_jq 'all(.[]; has("check_type") and (.results | type == "object"))' "$1" \
			|| { SC_REASON="list-shaped report has an element without check_type/results"; return 1; }
		SC_SHAPE="checkov-list"; return 0
	fi
	if _sc_jq 'type == "object"' "$1"; then
		_sc_jq 'has("check_type") and (.results | type == "object")' "$1" \
			|| { SC_REASON="object-shaped report lacks check_type/results"; return 1; }
		SC_SHAPE="checkov-object"; return 0
	fi
	SC_REASON="neither the documented object nor list shape"; return 1
}

# ===========================================================================
# CONFTEST (#98) — must prove policies and targets were actually evaluated.
# ===========================================================================
sc_conftest_validate() {
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'type == "array"' "$1" || { SC_REASON="not the documented array shape"; return 1; }
	_sc_jq 'all(.[]; has("filename"))' "$1" || { SC_REASON="a result carries no filename — nothing proves a target was evaluated"; return 1; }
	SC_SHAPE="conftest"; SC_COUNT=$(jq -r 'length' "$1" 2>/dev/null || printf '0'); return 0
}

# ===========================================================================
# SCORECARD (#100) — bound to repository identity, with validated score ranges.
# ===========================================================================
sc_scorecard_validate() {
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq '(.repo.name | type == "string") and (.repo.name | length > 0)' "$1" \
		|| { SC_REASON="repo.name missing — evidence is not bound to a repository"; return 1; }
	_sc_jq '(.checks | type == "array") and (.checks | length > 0)' "$1" \
		|| { SC_REASON="checks missing or empty — no check actually ran"; return 1; }
	_sc_jq 'all(.checks[]; (.score | type == "number") and .score >= -1 and .score <= 10)' "$1" \
		|| { SC_REASON="a check score is outside the documented -1..10 range"; return 1; }
	SC_SHAPE="scorecard"; return 0
}

# ===========================================================================
# TRUFFLEHOG (#101) — native NDJSON stream. Every line must be a valid finding object; a
# truncated final line is a truncated stream, not an empty result.
# ===========================================================================
sc_trufflehog_validate_stream() { # <ndjson-file>
	command_exists jq || { SC_REASON="jq unavailable"; return 1; }
	[ -s "$1" ] || { SC_SHAPE="trufflehog-ndjson"; SC_COUNT=0; return 0; }
	_sc_n=0
	while IFS= read -r _sc_line || [ -n "$_sc_line" ]; do
		[ -n "$_sc_line" ] || continue
		printf '%s' "$_sc_line" | jq -e 'type == "object"' >/dev/null 2>&1 \
			|| { SC_REASON="stream element $((_sc_n + 1)) is not a JSON object — truncated or corrupt stream"; return 1; }
		_sc_n=$((_sc_n + 1))
	done < "$1"
	SC_SHAPE="trufflehog-ndjson"; SC_COUNT=$_sc_n; return 0
}

# ===========================================================================
# TERRASCAN (#102) / DOCKLE (#103)
# ===========================================================================
sc_terrascan_validate() {
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'has("results")' "$1" || { SC_REASON="results missing — not a Terrascan report"; return 1; }
	SC_SHAPE="terrascan"; return 0
}
sc_dockle_validate() {
	_sc_parses "$1" || { SC_REASON="not parseable as JSON"; return 1; }
	_sc_jq 'has("summary") and has("details")' "$1" || { SC_REASON="summary/details missing — not a Dockle report"; return 1; }
	SC_SHAPE="dockle"; return 0
}
