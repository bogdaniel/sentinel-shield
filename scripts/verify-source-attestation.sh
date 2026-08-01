#!/bin/sh
# Sentinel Shield — independent verification of a security summary's source attestation.
#
# WHY THIS IS A SEPARATE FILE, AND A SEPARATE STEP
#
# A summary cannot attest to itself. `build-security-summary.sh` writes `.source` from the
# environment it happened to run in, and it deliberately emits `trust: "unverified"` because
# an environment variable is a claim, not provenance. If the enforcer then accepted an
# `.attestation` object embedded in that same summary, anyone who can write the summary could
# write `{"verified": true}` beside it — the document would be authorising itself, and the
# regulated gate would be checking the SHAPE of a claim rather than its authenticity.
#
# Binding an artifact to a digest also cannot be done from inside the artifact: the digest
# changes as soon as you write it in. So the verification result is produced HERE, into a
# SEPARATE file, from an anchor outside the repository — GitHub's artifact attestations, via
# `gh attestation verify`, which checks a Sigstore bundle against the workflow identity that
# actually produced the file.
#
# The record this writes is what `enforce-gates.sh --attestation` consumes. It is not a
# substitute for the anchor: if `gh` cannot verify, nothing is written and the run fails.
#
# Exit: 0 verified (record written); 1 NOT verified; 2 invalid invocation; 3 tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

usage() {
	cat <<'EOF'
Usage:
  verify-source-attestation.sh --summary <security-summary.json> --repository <owner/name>
                               --output <attestation.json>
                               [--signer-workflow <path>] [--gh <path-to-gh>]

Verifies that <summary> was produced by an attested workflow run of <repository>, using
GitHub artifact attestations, and writes the verification record to <output>.

The record binds: repository, commit, workflow, run_id and the sha256 of the summary FILE.
`enforce-gates.sh --attestation <output>` requires all five and cross-checks them against the
summary's own `.source` claims; a disagreement is a refusal, not a warning.
EOF
}

SUMMARY=""; REPOSITORY=""; OUTPUT=""; SIGNER_WORKFLOW=""; GH_BIN="gh"
while [ $# -gt 0 ]; do
	case "$1" in
		--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
		--repository) REPOSITORY="${2:?--repository requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--signer-workflow) SIGNER_WORKFLOW="${2:?--signer-workflow requires a value}"; shift 2 ;;
		--gh) GH_BIN="${2:?--gh requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

[ -n "$SUMMARY" ] || { log_error "--summary is required"; usage >&2; exit 2; }
[ -n "$REPOSITORY" ] || { log_error "--repository is required"; usage >&2; exit 2; }
[ -n "$OUTPUT" ] || { log_error "--output is required"; usage >&2; exit 2; }
[ -f "$SUMMARY" ] || { log_error "summary not found: $SUMMARY"; exit 2; }
command_exists jq || { log_error "jq is required but was not found"; exit 3; }
command_exists "$GH_BIN" || { log_error "gh is required but was not found (the attestation anchor lives outside this repository; without it nothing here can be verified)"; exit 3; }

# The digest of the artifact as it exists on disk. Computed here, never read from the file.
if command_exists sha256sum; then _digest=$(sha256sum "$SUMMARY" | awk '{print $1}')
elif command_exists shasum; then _digest=$(shasum -a 256 "$SUMMARY" | awk '{print $1}')
else log_error "no sha256 tool (sha256sum/shasum) — the artifact digest cannot be computed"; exit 3; fi
printf '%s' "$_digest" | grep -Eq '^[0-9a-f]{64}$' \
	|| { log_error "computed digest is not a sha256: '$_digest'"; exit 3; }

# THE ANCHOR. `gh attestation verify` checks the Sigstore bundle for this artifact against the
# identity that produced it. Everything below only records what it returned; nothing here can
# turn an unverified artifact into a verified one.
set -- attestation verify "$SUMMARY" --repo "$REPOSITORY" --format json
[ -z "$SIGNER_WORKFLOW" ] || set -- "$@" --signer-workflow "$SIGNER_WORKFLOW"
_out=""
if ! _out=$("$GH_BIN" "$@" 2>&1); then
	log_error "SOURCE_ATTESTATION_UNVERIFIED"
	log_error "  summary:    $SUMMARY"
	log_error "  sha256:     $_digest"
	log_error "  repository: $REPOSITORY"
	log_error "  gh attestation verify did not verify this artifact. An unverified artifact is"
	log_error "  not a verified one; no record is written and nothing downstream may treat it"
	log_error "  as attested."
	printf '%s\n' "$_out" | sed 's/^/  gh: /' >&2
	exit 1
fi

# Pull the bound identity out of the verification result — never out of the summary.
_rec=$(printf '%s' "$_out" | jq -c '
	( if type == "array" then .[0] else . end ) as $a
	| ($a.verificationResult // $a) as $v
	| ($v.signature.certificate // {}) as $c
	| {
		repository: ($c.sourceRepositoryURI // "" | sub("^https://github.com/"; "")),
		commit:     ($c.sourceRepositoryDigest // ""),
		workflow:   ($c.buildSignerURI // "" | sub("^.*/\\.github/workflows/"; "") | sub("@.*$"; "")),
		run_id:     ($c.runInvocationURI // "" | sub("^.*/actions/runs/"; "") | sub("/.*$"; ""))
	  }' 2>/dev/null) || _rec=""
[ -n "$_rec" ] || { log_error "the verification result could not be parsed; refusing to record an attestation this script cannot read"; exit 1; }

for _f in repository commit workflow run_id; do
	_v=$(printf '%s' "$_rec" | jq -r --arg f "$_f" '.[$f] // ""')
	[ -n "$_v" ] || { log_error "the verified attestation does not bind $_f — a verified flag with no bound identity is not provenance"; exit 1; }
done

_tmp=$(mktemp) || { log_error "could not create a temporary file"; exit 3; }
trap 'rm -f -- "$_tmp"' EXIT INT TERM HUP
printf '%s' "$_rec" | jq --arg d "sha256:$_digest" --arg s "$SUMMARY" '
	{ attestation: "sentinel-shield/source-attestation@1",
	  verified: true, verifier: "verify-source-attestation.sh",
	  artifact: $s, artifact_digest: $d,
	  repository: .repository, commit: .commit, workflow: .workflow, run_id: .run_id }' > "$_tmp"
jq -e . "$_tmp" >/dev/null 2>&1 || { log_error "the verification record is not valid JSON"; exit 1; }
mv -- "$_tmp" "$OUTPUT"
trap - EXIT INT TERM HUP

printf 'source attestation VERIFIED\n'
printf '  artifact:   %s\n' "$SUMMARY"
printf '  sha256:     %s\n' "$_digest"
jq -r '"  repository: \(.repository)\n  commit:     \(.commit)\n  workflow:   \(.workflow)\n  run_id:     \(.run_id)"' "$OUTPUT"
printf '  record:     %s\n' "$OUTPUT"
