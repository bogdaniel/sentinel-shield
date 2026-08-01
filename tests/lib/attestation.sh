#!/bin/sh
# Test helper — build the independent source-attestation record that `regulated` requires.
#
# `regulated` has always required a verified attestation. What changed is WHERE it comes from:
# it used to be read out of the summary being gated, which meant whoever wrote that summary
# could write `verified: true` beside their own `.source` claims — the document authorising
# itself — and a summary cannot bind its own sha256 anyway, because writing the digest in
# changes it. The record therefore arrives separately, via `enforce-gates.sh --attestation`.
#
# In production that record is produced by scripts/verify-source-attestation.sh, whose anchor
# is `gh attestation verify`. Tests cannot reach that anchor offline, so they synthesise a
# record here. That is a fixture, not a bypass: the enforcer still checks the format, the
# verified flag, the bound identity, and — the part that matters — that the digest equals the
# summary it is actually enforcing, computed at enforcement time. tests/prod/296 asserts every
# way of getting that wrong is refused.
#
# ss_attestation_for <summary> <out> [jq-override]
ss_attestation_for() {
	_ssa_in="${1:?ss_attestation_for: summary required}"
	_ssa_out="${2:?ss_attestation_for: output required}"
	jq -e . "$_ssa_in" >/dev/null 2>&1 || return 1
	_ssa_d=$(sha256sum "$_ssa_in" 2>/dev/null | awk '{print $1}')
	[ -n "$_ssa_d" ] || _ssa_d=$(shasum -a 256 "$_ssa_in" 2>/dev/null | awk '{print $1}')
	[ -n "$_ssa_d" ] || return 1
	jq -n --arg d "sha256:$_ssa_d" \
		--arg r "$(jq -r '.source.repository // "example-org/example-repo"' "$_ssa_in")" \
		--arg c "$(jq -r '.source.commit // "0123456789abcdef0123456789abcdef01234567"' "$_ssa_in")" \
		'{attestation:"sentinel-shield/source-attestation@1", verified:true,
		  verifier:"test-fixture", artifact:"summary", artifact_digest:$d,
		  repository:$r, commit:$c, workflow:"sentinel-shield", run_id:"1"}' \
		| jq "${3:-.}" > "$_ssa_out" 2>/dev/null || return 1
	return 0
}

# ss_att <summary> — echo `--attestation <path>` when a record could be built for <summary>,
# or NOTHING when it could not (an unreadable or malformed summary must still reach the
# enforcer and be refused BY the enforcer, not hidden by this helper). Two tokens, so the call
# site leaves it unquoted.
#
# The record is bound to the summary AS IT IS NOW, which is why this is called at invocation
# time rather than when the fixture was built: several suites mutate the summary afterwards,
# and a record bound to the earlier bytes would be refused for attesting a different artifact —
# correct behaviour, but not what those assertions are about.
ss_att() {
	[ -n "${SS_ATT_DIR:-}" ] || SS_ATT_DIR=$(mktemp -d)
	_ssf_out="$SS_ATT_DIR/att-$$.json"
	if ss_attestation_for "$1" "$_ssf_out"; then
		printf -- '--attestation %s' "$_ssf_out"
	fi
}
