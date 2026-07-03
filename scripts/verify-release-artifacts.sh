#!/bin/sh
# Sentinel Shield — verify-release-artifacts: download and SAFELY verify the CI
# artifacts that back a release (Task 06.2).
#
# For each workflow run under scrutiny it lists the run's artifacts (through $GH_BIN,
# default 'gh', mockable), downloads each into an ISOLATED per-artifact temp dir, and
# fail-CLOSED verifies:
#   * ownership  — artifact.workflow_run.id equals the run, artifact.id/name match.
#   * expiration — artifact.expired must be false.
#   * archive integrity + safety — via scripts/lib/archive-safety.sh: REJECT path
#     traversal, symlinks escaping the extraction root, duplicate archive paths, and
#     oversized/zip-bomb archives before and during extraction.
#   * inventory  — records every contained file (path + SHA-256); can require a
#     minimum file count and/or an expected embedded commit string.
#   * digests    — SHA-256 of the whole artifact zip AND of each contained file.
# It emits one artifact-verification record per artifact. NOTHING is trusted that was
# not fetched and checked; a single rejection fails the whole run (exit 1).
#
# Modes (choose one source of runs):
#   --evidence <file>            iterate every engine_ci[] run in a release-evidence
#                                document; --repo/--commit default from the file.
#   --repo <owner/name> --run <id>
#                                verify one specific run's artifacts directly.
#
# Usage:
#   verify-release-artifacts.sh (--evidence <file> | --repo <owner/name> --run <id>)
#       [--commit <40hex>] [--require-embedded-commit] [--min-files <n>]
#       [--max-bytes <n>] [--max-entries <n>] [--workdir <dir>] [--output <path>]
#
# Exit:
#   0 = every artifact verified safe and owned
#   1 = a verification/safety check REJECTED an artifact
#   2 = invalid invocation / malformed API response
#   3 = required tool unavailable (jq, gh, unzip/zipinfo, sha256)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/archive-safety.sh
. "$SCRIPT_DIR/lib/archive-safety.sh"

usage() {
	printf 'Usage: verify-release-artifacts.sh (--evidence <file> | --repo <owner/name> --run <id>) [--commit <40hex>] [--require-embedded-commit] [--min-files <n>] [--max-bytes <n>] [--max-entries <n>] [--workdir <dir>] [--output <path>]\n'
}

EVIDENCE=""
REPO=""
RUN=""
COMMIT=""
REQUIRE_EMBEDDED=0
MIN_FILES=0
MAX_BYTES=104857600      # 100 MiB total uncompressed
MAX_ENTRIES=10000
WORKDIR=""
OUTPUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--evidence) EVIDENCE="${2:?--evidence requires a value}"; shift 2 ;;
		--repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
		--run) RUN="${2:?--run requires a value}"; shift 2 ;;
		--commit) COMMIT="${2:?--commit requires a value}"; shift 2 ;;
		--require-embedded-commit) REQUIRE_EMBEDDED=1; shift ;;
		--min-files) MIN_FILES="${2:?--min-files requires a value}"; shift 2 ;;
		--max-bytes) MAX_BYTES="${2:?--max-bytes requires a value}"; shift 2 ;;
		--max-entries) MAX_ENTRIES="${2:?--max-entries requires a value}"; shift 2 ;;
		--workdir) WORKDIR="${2:?--workdir requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
ss_have_sha256 || { log_error "a SHA-256 tool (sha256sum or shasum) is required"; exit 3; }
archive_safety_tools_ok || { log_error "unzip and zipinfo are required for archive inspection"; exit 3; }
: "${GH_BIN:=gh}"
command_exists "$GH_BIN" || { log_error "GitHub API access requested but '$GH_BIN' is not available"; exit 3; }

# Resolve the (repo, run) work list and engine commit.
RUNS_TSV=""   # lines: "<repo>\t<run_id>"
if [ -n "$EVIDENCE" ]; then
	[ -f "$EVIDENCE" ] || { log_error "evidence file not found: $EVIDENCE"; exit 2; }
	jq -e . "$EVIDENCE" >/dev/null 2>&1 || { log_error "evidence is not valid JSON: $EVIDENCE"; exit 2; }
	[ -n "$COMMIT" ] || COMMIT=$(jq -r '.engine_commit // ""' "$EVIDENCE")
	RUNS_TSV=$(jq -r '(.engine_ci // [])[] | "\(.repository)\t\(.workflow_run_id)"' "$EVIDENCE")
	[ -n "$RUNS_TSV" ] || { log_error "evidence has no engine_ci[] runs to verify"; exit 2; }
elif [ -n "$REPO" ] && [ -n "$RUN" ]; then
	case "$REPO" in */*) ;; *) log_error "--repo must be owner/name"; exit 2 ;; esac
	RUNS_TSV=$(printf '%s\t%s' "$REPO" "$RUN")
else
	log_error "provide either --evidence <file> or --repo <owner/name> --run <id>"; usage >&2; exit 2
fi

# COMMIT drives the embedded-commit grep; a malformed value like '.' would match
# unrelated text. Accept only empty, 'unknown', or a 40-hex SHA (fixed-string later).
if [ -n "$COMMIT" ] && [ "$COMMIT" != unknown ]; then
	printf '%s' "$COMMIT" | grep -Eq '^[0-9a-f]{40}$' || {
		log_error "--commit/engine_commit must be a 40-hex SHA or 'unknown'"; exit 2; }
fi

if [ -n "$WORKDIR" ]; then
	ensure_dir "$WORKDIR"; ROOT_WORK="$WORKDIR"; _cleanup_work=0
else
	ROOT_WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssartifacts); _cleanup_work=1
fi
# shellcheck disable=SC2064
[ "$_cleanup_work" = 1 ] && trap "rm -rf \"$ROOT_WORK\"" EXIT INT TERM

RECORDS="[]"
FAILURES=0

# verify_one_artifact <repo> <run_id> <artifact_json> — download + verify a single
# artifact; append a record to RECORDS; increment FAILURES on any rejection.
verify_one_artifact() {
	_repo="$1"; _run="$2"; _aj="$3"
	_aid=$(printf '%s' "$_aj" | jq -r '.id // ""')
	_aname=$(printf '%s' "$_aj" | jq -r '.name // ""')
	_aexpired=$(printf '%s' "$_aj" | jq -r 'if (.expired // false) then "true" else "false" end')
	_aowner=$(printf '%s' "$_aj" | jq -r '.workflow_run.id // ""')
	_asize=$(printf '%s' "$_aj" | jq -r '.size_in_bytes // 0')

	_reasons=""
	_ownership_ok=true
	# Ownership: the artifact must belong to THIS run and carry a positive id + name.
	if [ -z "$_aid" ] || [ "$_aid" = null ]; then _reasons="$_reasons missing-artifact-id"; _ownership_ok=false; fi
	if [ -z "$_aname" ] || [ "$_aname" = null ]; then _reasons="$_reasons missing-artifact-name"; _ownership_ok=false; fi
	if [ -z "$_aowner" ] || [ "$_aowner" = null ]; then
		_reasons="$_reasons missing-workflow-run-id"; _ownership_ok=false
	elif [ "$_aowner" != "$_run" ]; then
		_reasons="$_reasons run-ownership-mismatch:$_aowner!=$_run"; _ownership_ok=false
	fi
	# Expiration.
	if [ "$_aexpired" = true ]; then _reasons="$_reasons expired"; fi

	_archive_safe=true
	_sha=""
	_files_json="[]"
	_embedded_found=false
	_filecount=0
	if [ "$_ownership_ok" = true ] && [ "$_aexpired" != true ]; then
		_adir="$ROOT_WORK/a-$_run-$_aid"
		ensure_dir "$_adir"
		_zip="$_adir/artifact.zip"
		if ! "$GH_BIN" api "repos/$_repo/actions/artifacts/$_aid/zip" > "$_zip" 2>/dev/null; then
			_reasons="$_reasons download-failed"; _archive_safe=false
		else
			_sha=$(ss_sha256_file "$_zip" || printf '')
			# Pre-extraction safety scan (path traversal, symlinks, dupes, zip-bomb) PLUS a
			# case-fold collision scan: two entries differing only by case would silently
			# clobber each other on a case-insensitive extraction filesystem.
			_scan=$(archive_safety_scan "$_zip" "$MAX_BYTES" "$MAX_ENTRIES")
			_cscan=$(archive_safety_case_scan "$_zip")
			[ -n "$_cscan" ] && _scan=$(printf '%s\n%s' "$_scan" "$_cscan" | sed '/^$/d')
			if [ -n "$_scan" ]; then
				_archive_safe=false
				# Fold each violation token into the reasons list.
				for _tok in $_scan; do _reasons="$_reasons $_tok"; done
			else
				_extract="$_adir/extract"
				if ! archive_safety_extract "$_zip" "$_extract"; then
					_archive_safe=false; _reasons="$_reasons unsafe-extraction"
				else
					# Inventory: path + SHA-256 for each contained regular file.
					_files_json=$(
						find "$_extract" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
							_rel=${_f#"$_extract"/}
							_fsha=$(ss_sha256_file "$_f" || printf 'unknown')
							jq -n --arg p "$_rel" --arg s "$_fsha" '{path:$p, sha256:$s}'
						done | jq -sc .
					)
					_filecount=$(printf '%s' "$_files_json" | jq 'length')
					# Embedded commit: does any file reference the engine commit?
					if [ -n "$COMMIT" ] && [ "$COMMIT" != unknown ]; then
						if grep -rqIF -- "$COMMIT" "$_extract" 2>/dev/null; then _embedded_found=true; fi
					fi
				fi
			fi
		fi
	else
		_archive_safe=false
	fi

	# Inventory minimums / embedded-commit requirement.
	if [ "$_archive_safe" = true ]; then
		if [ "$MIN_FILES" -gt 0 ] && [ "$_filecount" -lt "$MIN_FILES" ]; then
			_reasons="$_reasons too-few-files:$_filecount/$MIN_FILES"
		fi
		if [ "$REQUIRE_EMBEDDED" = 1 ] && [ "$_embedded_found" != true ]; then
			_reasons="$_reasons embedded-commit-missing"
		fi
	fi

	# A record is verified only when nothing was flagged.
	_reasons=$(printf '%s' "$_reasons" | sed 's/^ *//')
	if [ -n "$_reasons" ]; then _verified=false; FAILURES=$((FAILURES + 1)); else _verified=true; fi

	_reasons_json=$(printf '%s' "$_reasons" | tr ' ' '\n' | sed '/^$/d' | jq -R . | jq -sc .)
	_rec=$(jq -n \
		--arg repo "$_repo" --argjson run "$(printf '%s' "$_run" | jq -R 'tonumber? // .')" \
		--argjson aid "$(printf '%s' "${_aid:-0}" | jq -R 'tonumber? // 0')" \
		--arg name "$_aname" --argjson expired "$_aexpired" \
		--argjson ownership_ok "$_ownership_ok" --argjson archive_safe "$_archive_safe" \
		--arg sha "$_sha" --argjson size "$(printf '%s' "${_asize:-0}" | jq -R 'tonumber? // 0')" \
		--argjson files "$_files_json" --argjson embedded "$_embedded_found" \
		--argjson verified "$_verified" --argjson reasons "$_reasons_json" '
		{ repository: $repo, run_id: $run, artifact_id: $aid, name: $name,
		  ownership_ok: $ownership_ok, expired: $expired, size_in_bytes: $size,
		  archive_safe: $archive_safe, sha256: $sha, file_count: ($files|length),
		  files: $files, embedded_commit_found: $embedded, verified: $verified,
		  reasons: $reasons }')
	RECORDS=$(printf '%s' "$RECORDS" | jq -c --argjson r "$_rec" '. + [$r]')
}

# Iterate runs; list each run's artifacts and verify every one.
printf '%s\n' "$RUNS_TSV" | grep -v '^[[:space:]]*$' > "$ROOT_WORK/runs.tsv"
while IFS="$(printf '\t')" read -r _repo _run; do
	[ -n "$_repo" ] && [ -n "$_run" ] || continue
	_listj=$("$GH_BIN" api "repos/$_repo/actions/runs/$_run/artifacts" 2>/dev/null) || {
		log_error "could not list artifacts for $_repo run $_run"; exit 2; }
	printf '%s' "$_listj" | jq -e . >/dev/null 2>&1 || { log_error "malformed artifacts list for $_repo run $_run"; exit 2; }
	_n=$(printf '%s' "$_listj" | jq '(.artifacts // []) | length')
	if [ "$_n" = 0 ]; then
		log_warn "run $_run on $_repo lists no artifacts"
	fi
	_i=0
	while [ "$_i" -lt "$_n" ]; do
		_aj=$(printf '%s' "$_listj" | jq -c ".artifacts[$_i]")
		verify_one_artifact "$_repo" "$_run" "$_aj"
		_i=$((_i + 1))
	done
done < "$ROOT_WORK/runs.tsv"

STATUS=pass
[ "$FAILURES" -gt 0 ] && STATUS=fail
REPORT=$(jq -n \
	--arg tool "verify-release-artifacts" --arg at "$(timestamp_utc)" \
	--arg commit "$COMMIT" --arg status "$STATUS" \
	--argjson records "$RECORDS" --argjson failures "$FAILURES" '
	{ tool: $tool, generated_at: $at, engine_commit: $commit, status: $status,
	  artifact_count: ($records|length), failure_count: $failures, artifacts: $records }')

if [ -n "$OUTPUT" ]; then
	printf '%s\n' "$REPORT" > "$OUTPUT"
else
	printf '%s\n' "$REPORT"
fi

if [ "$FAILURES" -gt 0 ]; then
	log_error "verify-release-artifacts: $FAILURES artifact(s) REJECTED (see report)"
	exit 1
fi
log_info "verify-release-artifacts: all $(printf '%s' "$RECORDS" | jq 'length') artifact(s) verified safe and owned"
exit 0
