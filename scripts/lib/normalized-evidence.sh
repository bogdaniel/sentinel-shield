# shellcheck shell=sh
# Sentinel Shield — the normalized-evidence envelope (#182).
#
# THE DEFECT THIS REMOVES
#
# Four collectors (codeql, dependency-check, grype, osv-scanner) accepted a bare
# `{critical, high, medium}` object as an alternative to native scanner output. File presence
# plus three numbers became gate evidence:
#
#     $ echo '{"critical":0,"high":0,"medium":0}' > reports/raw/grype.json
#     $ sh scripts/collectors/grype.sh --input reports/raw/grype.json
#     { "status": "pass", "tool_report": { "status": "pass", "health": "ok", ... } }
#
# `health: "ok"` is the part that matters. The shortcut did not merely bypass parsing — it
# manufactured a POSITIVE ASSERTION that the scanner ran and found nothing. Any process that
# could write the raw-report path could assert clean counts for every gated scanner.
#
# THE TRUST MODEL
#
#   native scanner artifact -> Sentinel collector -> normalized Sentinel evidence
#
# Sentinel controls the normalization step, so for the production path the scanner does not
# have to sign anything. What must be impossible is:
#
#   arbitrary process -> {"critical":0,...} -> claims to be normalized evidence -> pass
#
# So there are exactly three production outcomes:
#
#   native report + Sentinel normalization   -> accepted, trust produced INTERNALLY
#   authenticated signed external envelope   -> not implemented; therefore
#   anything else                            -> REJECTED
#
# CRITICAL PROPERTY: `trust.type = "sentinel-native-normalization"` is STAMPED BY THIS
# LIBRARY while it processes native source. It is never read from, or honoured in, raw input.
# An input document that *claims* that trust type is an external assertion and is rejected —
# `ne_classify` treats a self-declared envelope as external no matter what it says about
# itself. A document cannot authorise itself; this is the same principle
# `verify-source-attestation.sh` applies to the security summary.
#
# WHY EXTERNAL ENVELOPES ARE REJECTED RATHER THAN DIGEST-CHECKED
#
# A SHA-256 proves the integrity of bytes, not who produced them. Accepting an external
# envelope on a digest plus self-declared execution provenance would reproduce exactly the
# defect this issue exists to eliminate, one layer up. The repository has no general-purpose
# producer-signing primitive today — `verify-source-attestation.sh` is specific to the
# security summary and anchored on `gh attestation verify` — so external pre-normalized
# production evidence is refused outright. An unsafe feature is not worth preserving because
# an integration might one day want it.
#
# GENERIC BY DESIGN (#204)
#
# The core is deliberately evidence-kind-agnostic: producer identity, source identity +
# digest, target identity, execution completion, normalizer identity, trust classification.
# Vulnerability counts sit ABOVE that core as a payload. #204 needs the same core for
# engineering-quality evidence (producer, target/scope/configuration, checksum, completion,
# timing) and should extend this primitive with a different payload rather than inventing a
# second envelope with subtly different rules.

NE_CONTRACT="sentinel-shield/normalized-evidence@1"
NE_NORMALIZER="sentinel-shield"
# Bumped when the normalization SEMANTICS change, so evidence produced by an older
# normalizer is identifiable rather than silently comparable.
NE_NORMALIZER_VERSION="1"

# Trust classifications. Only the first is acceptable for gated production evidence.
NE_TRUST_NATIVE="sentinel-native-normalization"
NE_TRUST_FIXTURE="fixture"

# ne_sha256 <file> — print the file's sha256, or nothing if it cannot be computed.
ne_sha256() {
	[ -f "$1" ] || return 0
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" 2>/dev/null | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
	fi
}

# ne_target_json — {repository, commit} for the artifact under scan.
#
# Read from the CI event environment, and validated: a commit must be 40 hex. A malformed
# value becomes null rather than being carried into evidence as if it were an identity —
# binding evidence to "not-a-commit" is worse than binding it to nothing, because the field
# looks populated.
ne_target_json() {
	_ne_repo=${SENTINEL_SHIELD_TARGET_REPOSITORY:-${GITHUB_REPOSITORY:-}}
	_ne_sha=${SENTINEL_SHIELD_TARGET_COMMIT:-${GITHUB_SHA:-}}
	case "$_ne_sha" in
	*[!0-9a-fA-F]* | "") _ne_sha="" ;;
	*) [ "${#_ne_sha}" -eq 40 ] || _ne_sha="" ;;
	esac
	jq -n --arg r "$_ne_repo" --arg c "$_ne_sha" \
		'{repository: (if $r == "" then null else $r end),
		  commit:     (if $c == "" then null else ($c | ascii_downcase) end)}'
}

# ne_envelope <tool> <source-path> <source-format> <trust-type> <payload-json>
#
# Build the envelope. The trust type is supplied by the CALLER — and the only caller that may
# pass NE_TRUST_NATIVE is a collector that has just parsed native source itself.
ne_envelope() {
	_ne_tool=$1
	_ne_src=$2
	_ne_fmt=$3
	_ne_trust=$4
	_ne_payload=$5
	jq -n \
		--arg contract "$NE_CONTRACT" \
		--arg tool "$_ne_tool" \
		--arg normalizer "$NE_NORMALIZER" \
		--arg nver "$NE_NORMALIZER_VERSION" \
		--arg fmt "$_ne_fmt" \
		--arg path "$_ne_src" \
		--arg digest "$(ne_sha256 "$_ne_src")" \
		--argjson target "$(ne_target_json)" \
		--arg trust "$_ne_trust" \
		--argjson payload "$_ne_payload" '
		{
			envelope: $contract,
			producer: { tool: $tool, normalizer: $normalizer, normalizer_version: $nver },
			source:   { format: $fmt, path: $path,
			            sha256: (if $digest == "" then null else $digest end) },
			target:   $target,
			execution: { completed: true, exit_code: 0 },
			trust:    { type: $trust }
		} + $payload'
}

# ne_is_envelope <input-file> — true when the raw input declares itself an envelope.
#
# Used to tell "someone handed us a pre-normalized document" from "someone handed us
# something we do not recognise at all". Both are refused on the production path; they are
# distinguished only so the refusal can say something useful.
ne_is_envelope() {
	jq -e --arg c "$NE_CONTRACT" '(type == "object") and (.envelope? == $c)' "$1" >/dev/null 2>&1
}

# ne_declared_trust <input-file> — the trust type the raw input CLAIMS, for diagnostics only.
# Never used to grant trust.
ne_declared_trust() { jq -r '.trust.type? // ""' "$1" 2>/dev/null; }

# ne_release_context — 0 (true) when this looks like a release/tag build.
#
# Fixture evidence must not be constructible in a release context even if every other
# condition is satisfied.
ne_release_context() {
	[ -n "${SENTINEL_SHIELD_RELEASE_CONTEXT:-}" ] && return 0
	case "${GITHUB_REF:-}" in refs/tags/*) return 0 ;; esac
	[ "${GITHUB_REF_TYPE:-}" = "tag" ] && return 0
	return 1
}

# ne_gate_input <tool> <input> <native-recognizer-jq> <summary-overrides> <fixture-flag>
#
# The single production decision, shared by every migrated collector so the rule cannot exist
# in four slightly different versions. Sets the global NE_KIND to one of:
#
#   native    the input is a real scanner report this collector understands
#   fixture   explicitly-invoked, explicitly-labelled, non-release fixture evidence
#
# Returns 0 when the caller may proceed. On refusal it emits the execution-error report on
# stdout and returns 1; every caller MUST spell the invocation:
#
#     ne_gate_input ... || exit 0
#
# IT DOES NOT RUN IN A SUBSHELL, AND MUST NOT BE CALLED IN ONE. The first version of this
# function printed its decision and called `exit` on refusal, so callers wrote
# `NE_KIND=$(ne_gate_input ...)`. Command substitution is a subshell: the `exit` terminated
# the subshell and the collector carried on, so a forged `{critical:0,high:0,medium:0}` still
# produced status=pass health=ok. The refusal path existed, was correct, and never fired.
# `scripts/lib/compatibility-policy.sh` documents the same trap for CP_PROBE_TIMEOUT.
#
# Note the ordering: the native recognizer is tried FIRST. A document that satisfies the
# native shape is normalized by us regardless of anything it claims about itself, and a
# document that does not is refused regardless of how convincingly it is dressed up.
ne_gate_input() {
	_ng_tool=$1
	_ng_in=$2
	_ng_rec=$3
	_ng_ov=${4:-'{}'}
	_ng_fix=${5:-0}

	NE_KIND=""
	if jq -e "$_ng_rec" "$_ng_in" >/dev/null 2>&1; then
		NE_KIND=native
		return 0
	fi

	if ne_is_envelope "$_ng_in"; then
		_ng_claim=$(ne_declared_trust "$_ng_in")
		if [ "$_ng_claim" = "$NE_TRUST_FIXTURE" ] && ne_fixture_allowed "$_ng_fix"; then
			NE_KIND=fixture
			return 0
		fi
		# Every other envelope is an EXTERNAL ASSERTION. This includes one claiming
		# `sentinel-native-normalization`: that trust state is produced here while parsing
		# native source, never accepted as an input claim. A document cannot authorise itself.
		log_warn "$_ng_tool: refusing a pre-normalized evidence envelope claiming trust.type='${_ng_claim:-none}'. Production evidence must be a NATIVE $_ng_tool report that Sentinel normalizes itself, or a cryptographically authenticated external envelope (not implemented). status=execution-error"
		ss_emit_collector "$_ng_tool" "execution-error" \
			"$(jq -n --arg t "$_ng_tool" --arg c "${_ng_claim:-none}" \
				'{status:"execution-error", health:"untrusted-evidence",
				  reason:("refused pre-normalized " + $t + " evidence claiming trust.type=" + $c),
				  critical:0, high:0, medium:0}')" \
			"$_ng_ov"
		return 1
	fi

	# The bare-count shortcut lands here: `{"critical":0,"high":0,"medium":0}` is not a native
	# report and not an envelope. It used to be accepted and reported health=ok.
	log_warn "$_ng_tool: input is neither a native $_ng_tool report nor an authenticated envelope. Bare count objects are not evidence of scanner execution. status=execution-error"
	ss_emit_collector "$_ng_tool" "execution-error" \
		"$(jq -n --arg t "$_ng_tool" \
			'{status:"execution-error", health:"untrusted-evidence",
			  reason:("unrecognized " + $t + " report shape; bare count objects are not evidence"),
			  critical:0, high:0, medium:0}')" \
		"$_ng_ov"
	return 1
}

# ne_fixture_allowed <explicit-flag> — 0 (true) only when EVERY independent condition holds.
#
# Three conditions, deliberately independent, because any single one is too easy to inherit
# by accident:
#   1. the caller passed an explicit per-invocation flag (not an inherited environment value)
#   2. the document itself declares trust.type = fixture (checked by the caller)
#   3. the run is not a release context
ne_fixture_allowed() {
	[ "${1:-0}" = "1" ] || return 1
	ne_release_context && return 1
	return 0
}
