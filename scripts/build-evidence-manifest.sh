#!/bin/sh
# Sentinel Shield — PRODUCER-side evidence manifest for the trusted cross-workflow handoff.
#
# The consumer of a cross-run handoff must be able to prove the artifact it downloaded is the
# artifact the producer uploaded, for the commit it claims. An artifact name alone proves
# nothing: names are not unique across runs and contents are not bound to a commit.
#
# This walks the evidence directory and records, for every file, its SHA-256, together with
# the producing repository, run id and commit. scripts/verify-evidence-handoff.sh then rejects
# a missing manifest, a manifest from another run/commit/repository, a digest mismatch, a
# listed-but-absent file, and any file the manifest does not cover.
#
# Usage:
#   build-evidence-manifest.sh --dir reports --repository owner/name --run-id 123 \
#       --commit <40hex> [--workflow <name>] [--output <path>]
#
# Exit: 0 written; 2 invalid invocation; 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

DIR=""; REPO=""; RUN_ID=""; COMMIT=""; WORKFLOW=""; OUTPUT=""
ARTIFACT_NAME="sentinel-shield-security-summary"
while [ $# -gt 0 ]; do
	case "$1" in
		--dir) DIR="${2:?--dir requires a value}"; shift 2 ;;
		--repository) REPO="${2:?--repository requires a value}"; shift 2 ;;
		--run-id) RUN_ID="${2:?--run-id requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--workflow) WORKFLOW="${2:?--workflow requires a value}"; shift 2 ;;
		--artifact-name) ARTIFACT_NAME="${2:?--artifact-name requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help)
			printf 'Usage: build-evidence-manifest.sh --dir <dir> --repository <owner/name> --run-id <id> --commit <40hex> [--workflow <name>] [--output <path>]\n'
			exit 0 ;;
		*) log_error "unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required"; exit 3; }
ss_have_sha256 || { log_error "a SHA-256 tool (sha256sum/shasum) is required"; exit 3; }
[ -n "$DIR" ] && [ -d "$DIR" ] || { log_error "--dir must be an existing directory"; exit 2; }
case "$REPO" in */*) ;; *) log_error "--repository must be owner/name"; exit 2 ;; esac
case "$RUN_ID" in '' | *[!0-9]*) log_error "--run-id must be numeric"; exit 2 ;; esac
printf '%s' "$COMMIT" | grep -Eq '^[0-9a-fA-F]{40}$' || { log_error "--commit must be a full 40-hex commit SHA"; exit 2; }
COMMIT=$(printf '%s' "$COMMIT" | tr 'A-F' 'a-f')
[ -n "$OUTPUT" ] || OUTPUT="$DIR/sentinel-shield-artifact-manifest.json"

TMP=$(mktemp)
TMPOUT=$(mktemp)
trap 'rm -f -- "$TMP" "$TMPOUT"' EXIT INT TERM HUP

# Sorted, so the manifest is deterministic for identical evidence. The manifest itself is
# excluded — it cannot contain its own digest.
(cd "$DIR" && find . -type f ! -name "$(basename "$OUTPUT")" 2>/dev/null) | sed 's|^\./||' | sort > "$TMP"
: > "$TMPOUT"
while IFS= read -r _p; do
	[ -n "$_p" ] || continue
	_d=$(ss_sha256_file "$DIR/$_p") || { log_error "could not hash '$_p'"; exit 2; }
	jq -nc --arg p "$_p" --arg d "$_d" '{path:$p, sha256:$d}' >> "$TMPOUT"
done < "$TMP"

jq -s --arg repo "$REPO" --arg run "$RUN_ID" --arg commit "$COMMIT" --arg wf "$WORKFLOW" \
	--arg ts "$(timestamp_utc)" \
	--arg artifact "$ARTIFACT_NAME" \
	'{ schema_version: "1", generator: "build-evidence-manifest",
	   repository: $repo, run_id: $run, commit: $commit, artifact: $artifact,
	   workflow: (if $wf == "" then null else $wf end),
	   generated_at: $ts, files: . }' "$TMPOUT" > "$OUTPUT.tmp" \
	|| { log_error "could not write the manifest"; rm -f "$OUTPUT.tmp"; exit 2; }
mv -- "$OUTPUT.tmp" "$OUTPUT"
log_info "evidence manifest: $OUTPUT ($(jq '.files | length' "$OUTPUT") file(s), commit $COMMIT, run $RUN_ID)"
