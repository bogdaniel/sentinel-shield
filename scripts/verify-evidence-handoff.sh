#!/bin/sh
# Sentinel Shield — TRUSTED cross-workflow security-evidence handoff (opt-in).
#
# The safe default is unchanged and still recommended: run the gate in the SAME workflow run
# as the scanners, wired with `needs:`, so the summary artifact is in-run and no trust
# decision is needed. This exists for the topology that default cannot serve — an
# organisation whose protected release/deploy workflow is separate from its scanner workflow —
# because the alternative is every adopter hand-rolling artifact discovery, which is exactly
# where untrusted-run and wrong-commit mistakes happen.
#
# "Latest successful run" is NOT a trust rule. This verifier consumes EXPLICIT producer
# metadata and fails closed unless the evidence is bound to all of:
#
#   repository · workflow identity (allowlisted) · run id · run conclusion · exact commit SHA ·
#   trusted ref · trusted event · same-repository head (never a fork) · freshness ·
#   artifact name (allowlisted) · artifact checksum manifest · the summary's OWN embedded
#   commit/branch/workflow metadata
#
# Any missing, malformed, stale, ambiguous or mismatched input is a REJECTION. Nothing here
# downgrades to a warning, and no input is defaulted into trust.
#
# Modes:
#   verify   Verify one producer run + its downloaded artifact directory against expectations.
#   explain  Print the trust rules this verifier enforces (documentation for a reviewer).
#
# Exit: 0 verified; 1 REJECTED (fail closed); 2 invalid invocation / malformed input;
#       3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

usage() {
	cat <<'EOF'
Usage:
  verify-evidence-handoff.sh verify \
      --producer-run <run.json> [--producer-run <run.json> ...] \
      --expected-repository <owner/name> \
      --expected-workflow <name> [--expected-workflow <name> ...] \
      --expected-commit <40hex> \
      [--expected-run-id <id>] \
      [--expected-ref <ref> ...]      (default: the repository default branch ref must be given) \
      [--expected-event <push|workflow_dispatch|schedule> ...] \
      --artifact-dir <dir> \
      [--expected-artifact <name> ...] \
      [--summary <path-in-artifact-dir>]   (default: reports/security-summary.json) \
      [--manifest <path>]                  (default: <artifact-dir>/sentinel-shield-artifact-manifest.json) \
      [--max-age-seconds <n>]              (default: 86400) \
      [--now <ISO8601Z>] [--format text|json]

  verify-evidence-handoff.sh explain

READ-ONLY. Never downloads anything, never executes consumer code, never trusts
"the latest successful run".
EOF
}

MODE="${1:-}"
case "$MODE" in
	verify | explain) shift ;;
	-h | --help) usage; exit 0 ;;
	'') log_error "a mode is required (verify|explain)"; usage >&2; exit 2 ;;
	*) log_error "unknown mode: $MODE"; usage >&2; exit 2 ;;
esac

if [ "$MODE" = explain ]; then
	cat <<'EOF'
Trust rules enforced by verify-evidence-handoff.sh (all mandatory, all fail-closed):

  1  repository        the producer run belongs to the EXACT expected repository
  2  fork              head repository == producer repository (a fork PR run is rejected)
  3  workflow          the producer workflow name is on the caller's allowlist
  4  run id            when an expected run id is given it must match exactly
  5  status            the run is `completed`
  6  conclusion        the run concluded `success` (failure/cancelled/skipped are rejected)
  7  event             the triggering event is on the allowlist (never pull_request*)
  8  ref               the run's ref/branch is on the caller's trusted-ref allowlist
  9  commit            head_sha equals the exact commit being gated
 10  freshness         the run is not older than --max-age-seconds
 11  ambiguity         exactly ONE producer run survives the filters; 0 or >1 is a rejection
 12  artifact name     every expected artifact name is present in the artifact directory
 13  manifest          a checksum manifest exists, covers every file, and every digest matches
 14  summary binding   the summary's OWN source.commit / source.branch / source.workflow match
EOF
	exit 0
fi

RUNS=""
EXP_REPO=""
EXP_WORKFLOWS=""
EXP_COMMIT=""
EXP_RUN_ID=""
EXP_REFS=""
EXP_EVENTS=""
ARTIFACT_DIR=""
EXP_ARTIFACTS=""
SUMMARY_REL="reports/security-summary.json"
MANIFEST=""
MAX_AGE=86400
NOW=""
FORMAT=text
while [ $# -gt 0 ]; do
	case "$1" in
		--producer-run) RUNS="$RUNS ${2:?--producer-run requires a value}"; shift 2 ;;
		--expected-repository) EXP_REPO="${2:?--expected-repository requires a value}"; shift 2 ;;
		--expected-workflow) EXP_WORKFLOWS="$EXP_WORKFLOWS
${2:?--expected-workflow requires a value}"; shift 2 ;;
		--expected-commit) EXP_COMMIT="${2:?--expected-commit requires a value}"; shift 2 ;;
		--expected-run-id) EXP_RUN_ID="${2:?--expected-run-id requires a value}"; shift 2 ;;
		--expected-ref) EXP_REFS="$EXP_REFS
${2:?--expected-ref requires a value}"; shift 2 ;;
		--expected-event) EXP_EVENTS="$EXP_EVENTS
${2:?--expected-event requires a value}"; shift 2 ;;
		--artifact-dir) ARTIFACT_DIR="${2:?--artifact-dir requires a value}"; shift 2 ;;
		--expected-artifact) EXP_ARTIFACTS="$EXP_ARTIFACTS
${2:?--expected-artifact requires a value}"; shift 2 ;;
		--summary) SUMMARY_REL="${2:?--summary requires a value}"; shift 2 ;;
		--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
		--max-age-seconds) MAX_AGE="${2:?--max-age-seconds requires a value}"; shift 2 ;;
		--now) NOW="${2:?--now requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required"; exit 3; }
case "$FORMAT" in text | json) ;; *) log_error "--format must be text|json"; exit 2 ;; esac
[ -n "$RUNS" ] || { log_error "at least one --producer-run <run.json> is required"; exit 2; }
[ -n "$EXP_REPO" ] || { log_error "--expected-repository is required (evidence is never accepted from an unnamed repository)"; exit 2; }
case "$EXP_REPO" in */*) ;; *) log_error "--expected-repository must be owner/name"; exit 2 ;; esac
[ -n "$EXP_WORKFLOWS" ] || { log_error "--expected-workflow is required (an allowlist, never 'any workflow')"; exit 2; }
printf '%s' "$EXP_COMMIT" | grep -Eq '^[0-9a-fA-F]{40}$' || { log_error "--expected-commit must be a full 40-hex commit SHA"; exit 2; }
EXP_COMMIT=$(printf '%s' "$EXP_COMMIT" | tr 'A-F' 'a-f')
[ -n "$EXP_REFS" ] || { log_error "--expected-ref is required (a trusted-ref allowlist, never 'any ref')"; exit 2; }
[ -n "$ARTIFACT_DIR" ] && [ -d "$ARTIFACT_DIR" ] || { log_error "--artifact-dir must be an existing directory"; exit 2; }
case "$MAX_AGE" in '' | *[!0-9]*) log_error "--max-age-seconds must be a non-negative integer"; exit 2 ;; esac
[ -n "$EXP_EVENTS" ] || EXP_EVENTS="
push
workflow_dispatch"
[ -n "$EXP_ARTIFACTS" ] || EXP_ARTIFACTS="
sentinel-shield-security-summary"
# `actions/upload-artifact` roots the archive at the LEAST COMMON ANCESTOR of the uploaded
# paths, so a producer uploading `reports/security-summary.json` and
# `reports/sentinel-shield-artifact-manifest.json` yields an archive whose members have NO
# `reports/` prefix. Both layouts are accepted, and which one was found is reported, so a
# handoff cannot fail with "missing" for a file that is simply one directory up.
if [ -z "$MANIFEST" ]; then
	if [ -f "$ARTIFACT_DIR/sentinel-shield-artifact-manifest.json" ]; then
		MANIFEST="$ARTIFACT_DIR/sentinel-shield-artifact-manifest.json"
	elif [ -f "$ARTIFACT_DIR/reports/sentinel-shield-artifact-manifest.json" ]; then
		MANIFEST="$ARTIFACT_DIR/reports/sentinel-shield-artifact-manifest.json"
	else
		MANIFEST="$ARTIFACT_DIR/sentinel-shield-artifact-manifest.json"
	fi
fi

REJECTIONS=0
REASONS=""
ok() { [ "$FORMAT" = text ] && printf '  PASS  %s\n' "$*"; return 0; }
reject() {
	REJECTIONS=$((REJECTIONS + 1))
	REASONS="$REASONS$1
"
	[ "$FORMAT" = text ] && printf '  REJECT  %s\n' "$1"
	return 0
}

# in_list <value> <newline-list> — exact membership (never a substring/prefix match).
in_list() {
	printf '%s\n' "$2" | while IFS= read -r _e; do
		[ -n "$_e" ] || continue
		[ "$_e" = "$1" ] && printf 'yes'
	done | grep -q yes
}

# iso_to_epoch <iso8601Z> — seconds since epoch, empty when unparseable. Portable across
# GNU date and BSD date; an unparseable timestamp is NOT silently treated as fresh.
iso_to_epoch() {
	[ -n "${1:-}" ] || return 0
	date -u -d "$1" +%s 2>/dev/null && return 0
	date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
	return 0
}

NOW_EPOCH=""
if [ -n "$NOW" ]; then
	NOW_EPOCH=$(iso_to_epoch "$NOW")
	[ -n "$NOW_EPOCH" ] || { log_error "--now is not a parseable ISO-8601 UTC timestamp: $NOW"; exit 2; }
else
	NOW_EPOCH=$(date -u +%s)
fi

# --- (1..11) select exactly ONE trusted producer run -------------------------------------
# Mismatches on a candidate are DIAGNOSTIC, not immediately fatal: when several producer runs
# are supplied (a rerun, a superseded run, a decoy) the caller is asking "which one, if any, is
# trustworthy". They become rejections when NO run survives, and an AMBIGUOUS result — more
# than one survivor — is itself a rejection, because "latest by time" is not a trust rule.
ACCEPTED_RUN=""
ACCEPTED_ID=""
CANDIDATES=0
DIAG=""
note() { DIAG="$DIAG$1
"; }
for _rf in $RUNS; do
	CANDIDATES=$((CANDIDATES + 1))
	_label=$(basename "$_rf")
	if [ ! -f "$_rf" ] || ! jq -e . "$_rf" >/dev/null 2>&1; then
		note "PRODUCER_RUN_UNREADABLE — '$_rf' is missing or not valid JSON"
		continue
	fi
	_repo=$(jq -r '(.repository.full_name // .repository_full_name // "")' "$_rf")
	_head_repo=$(jq -r '(.head_repository.full_name // .repository.full_name // .repository_full_name // "")' "$_rf")
	_wf=$(jq -r '(.name // .workflow_name // "")' "$_rf")
	_id=$(jq -r '(.id // .run_id // "") | tostring' "$_rf")
	_status=$(jq -r '(.status // "")' "$_rf")
	_concl=$(jq -r '(.conclusion // "")' "$_rf")
	_event=$(jq -r '(.event // "")' "$_rf")
	_sha=$(jq -r '(.head_sha // "") | ascii_downcase' "$_rf")
	_branch=$(jq -r '(.head_branch // "")' "$_rf")
	_ref=$(jq -r '(.head_ref // ("refs/heads/" + (.head_branch // "")))' "$_rf")
	_created=$(jq -r '(.created_at // .run_started_at // "")' "$_rf")

	_bad=0
	[ "$_repo" = "$EXP_REPO" ] || { note "WRONG_REPOSITORY [$_label] — run repository '$_repo' != expected '$EXP_REPO'"; _bad=1; }
	[ "$_head_repo" = "$_repo" ] || { note "FORK_EVIDENCE [$_label] — head repository '$_head_repo' differs from '$_repo'; a fork run is never trusted evidence"; _bad=1; }
	in_list "$_wf" "$EXP_WORKFLOWS" || { note "WORKFLOW_NOT_ALLOWLISTED [$_label] — producer workflow '$_wf' is not on the allowlist"; _bad=1; }
	if [ -n "$EXP_RUN_ID" ] && [ "$_id" != "$EXP_RUN_ID" ]; then
		note "WRONG_RUN_ID [$_label] — run id '$_id' != expected '$EXP_RUN_ID'"; _bad=1
	fi
	[ "$_status" = "completed" ] || { note "RUN_NOT_COMPLETED [$_label] — status '$_status'"; _bad=1; }
	[ "$_concl" = "success" ] || { note "RUN_NOT_SUCCESSFUL [$_label] — conclusion '$_concl' (failure/cancelled/skipped evidence is never accepted)"; _bad=1; }
	in_list "$_event" "$EXP_EVENTS" || { note "UNTRUSTED_EVENT [$_label] — event '$_event' is not on the allowlist (pull_request/pull_request_target evidence is never trusted)"; _bad=1; }
	[ "$_sha" = "$EXP_COMMIT" ] || { note "WRONG_COMMIT [$_label] — head_sha '$_sha' != the commit being gated '$EXP_COMMIT'"; _bad=1; }
	if ! in_list "$_ref" "$EXP_REFS" && ! in_list "$_branch" "$EXP_REFS"; then
		note "UNTRUSTED_REF [$_label] — ref '$_ref' (branch '$_branch') is not on the trusted-ref allowlist"; _bad=1
	fi
	_cepoch=$(iso_to_epoch "$_created")
	if [ -z "$_cepoch" ]; then
		note "RUN_TIMESTAMP_UNREADABLE [$_label] — created_at '$_created' could not be parsed; freshness is unprovable"; _bad=1
	else
		_age=$((NOW_EPOCH - _cepoch))
		[ "$_age" -lt 0 ] && { note "RUN_IN_THE_FUTURE [$_label] — created_at is ahead of now by $((0 - _age))s"; _bad=1; }
		if [ "$_age" -gt "$MAX_AGE" ]; then
			note "STALE_EVIDENCE [$_label] — run is ${_age}s old, limit ${MAX_AGE}s"; _bad=1
		fi
	fi
	if [ "$_bad" -eq 0 ]; then
		if [ -n "$ACCEPTED_RUN" ]; then
			reject "AMBIGUOUS_PRODUCER — more than one producer run satisfies the trust rules (ids '$ACCEPTED_ID' and '$_id'); pick one explicitly with --expected-run-id. 'Latest by time' is not a trust rule."
		else
			ACCEPTED_RUN="$_rf"; ACCEPTED_ID="$_id"
		fi
	fi
done
if [ -z "$ACCEPTED_RUN" ]; then
	printf '%s' "$DIAG" | while IFS= read -r _d; do
		[ -n "$_d" ] || continue
		[ "$FORMAT" = text ] && printf '  REJECT  %s\n' "$_d"
	done
	# Every diagnostic is a reason; count them so the verdict reports the real rule count.
	_dn=$(printf '%s' "$DIAG" | grep -c . || true)
	case "$_dn" in '' | *[!0-9]*) _dn=0 ;; esac
	REJECTIONS=$((REJECTIONS + _dn))
	REASONS="$REASONS$DIAG"
	reject "NO_TRUSTED_PRODUCER — none of the $CANDIDATES supplied producer run(s) satisfied the trust rules"
else
	ok "trusted producer run $ACCEPTED_ID (repository $EXP_REPO, commit $EXP_COMMIT)"
	[ -n "$DIAG" ] && [ "$FORMAT" = text ] && printf '%s' "$DIAG" | while IFS= read -r _d; do
		[ -n "$_d" ] || continue
		printf '  note    rejected candidate: %s\n' "$_d"
	done
fi

# --- (12) the artifact IDENTITY is declared, not guessed ----------------------------------
# `actions/download-artifact` with `name:` extracts an artifact's CONTENTS, so the artifact
# name is not visible on disk. Identity therefore comes from the producer's manifest (which is
# itself digest-bound below), with a filesystem fallback for the `pattern:`/`merge-multiple`
# layout where each artifact lands in its own directory.
TMPDIR_VH=$(mktemp -d)
trap 'rm -rf -- "$TMPDIR_VH"' EXIT INT TERM HUP
_declared=""
[ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1 && _declared=$(jq -r '.artifact // ""' "$MANIFEST")
if [ -n "$_declared" ]; then
	if in_list "$_declared" "$EXP_ARTIFACTS"; then
		ok "the artifact declares itself as '$_declared', which is on the allowlist"
	else
		reject "ARTIFACT_NOT_ALLOWLISTED — the manifest declares artifact '$_declared', which is not on the expected list"
	fi
else
	# NO DIRECTORY-NAME HEURISTIC. Inferring identity from the extraction layout means a
	# directory named like an expected artifact is treated AS that artifact; the layout is
	# chosen by whoever produced the download, not by the platform. A manifest that declares
	# no artifact name is rejected outright.
	reject "ARTIFACT_IDENTITY_UNDECLARED — the checksum manifest declares no artifact name. Artifact identity is never inferred from the extracted directory layout, because that layout is not evidence of which artifact was downloaded."
fi

# --- (13) checksum manifest covers the artifact exactly -----------------------------------
if [ ! -f "$MANIFEST" ] || ! jq -e . "$MANIFEST" >/dev/null 2>&1; then
	reject "MANIFEST_MISSING — no readable checksum manifest at '$MANIFEST'; unverifiable artifact contents are never accepted"
elif ! ss_have_sha256; then
	log_error "a SHA-256 tool (sha256sum/shasum) is required to verify the artifact manifest"
	exit 3
else
	_mrepo=$(jq -r '.repository // ""' "$MANIFEST")
	_mrun=$(jq -r '(.run_id // "") | tostring' "$MANIFEST")
	_mcommit=$(jq -r '(.commit // "") | ascii_downcase' "$MANIFEST")
	# THESE BINDINGS ARE MANDATORY. They were compared only when non-empty, so a manifest that
	# simply OMITTED repository, commit and run_id passed the binding stage entirely — the very
	# fields that tie the downloaded bytes to the platform-verified producer. Absence is
	# rejection, not a skipped check.
	[ -n "$_mrepo" ] || reject "MANIFEST_UNBOUND_REPOSITORY — the manifest declares no repository; an artifact that does not say where it came from is not attributable evidence"
	[ -n "$_mcommit" ] || reject "MANIFEST_UNBOUND_COMMIT — the manifest declares no commit; evidence that does not name its target cannot be checked against one"
	[ -n "$_mrun" ] || reject "MANIFEST_UNBOUND_RUN — the manifest declares no run_id; without it the artifact cannot be tied to the producer run that was authenticated"
	[ -z "$_mrepo" ] || [ "$_mrepo" = "$EXP_REPO" ] || reject "MANIFEST_WRONG_REPOSITORY — manifest repository '$_mrepo' != '$EXP_REPO'"
	[ -z "$_mcommit" ] || [ "$_mcommit" = "$EXP_COMMIT" ] || reject "MANIFEST_WRONG_COMMIT — manifest commit '$_mcommit' != '$EXP_COMMIT'"
	# Types matter as much as presence: a numeric or object commit is not a commit.
	jq -e '((.repository | type) == "string") and ((.commit | type) == "string")' "$MANIFEST" >/dev/null 2>&1 \
		|| reject "MANIFEST_MALFORMED_BINDING — repository and commit must be strings"
	printf '%s' "$_mcommit" | grep -Eq '^[0-9a-f]{40}$' \
		|| reject "MANIFEST_MALFORMED_COMMIT — manifest commit '$_mcommit' is not a full 40-hex SHA"
	if [ -n "$ACCEPTED_ID" ] && [ -n "$_mrun" ] && [ "$_mrun" != "$ACCEPTED_ID" ]; then
		reject "MANIFEST_WRONG_RUN — manifest run_id '$_mrun' != the trusted producer run '$ACCEPTED_ID' (artifact substitution)"
	fi
	_files=$(jq -r '(.files // []) | length' "$MANIFEST")
	case "$_files" in '' | *[!0-9]*) _files=0 ;; esac
	if [ "$_files" -eq 0 ]; then
		reject "MANIFEST_EMPTY — the manifest lists no files, so nothing about the artifact is verified"
	else
		_bad=0
		_i=0
		while [ "$_i" -lt "$_files" ]; do
			_p=$(jq -r --argjson i "$_i" '.files[$i].path // ""' "$MANIFEST")
			_d=$(jq -r --argjson i "$_i" '(.files[$i].sha256 // "") | ascii_downcase' "$MANIFEST")
			_i=$((_i + 1))
			case "$_p" in
				'' ) reject "MANIFEST_ENTRY_INVALID — a manifest entry has no path"; _bad=1; continue ;;
				/* | *..*) reject "MANIFEST_PATH_UNSAFE — '$_p' escapes the artifact directory"; _bad=1; continue ;;
			esac
			printf '%s' "$_d" | grep -Eq '^[0-9a-f]{64}$' || { reject "MANIFEST_DIGEST_INVALID — '$_p' has no 64-hex sha256"; _bad=1; continue; }
			if [ ! -f "$ARTIFACT_DIR/$_p" ]; then
				reject "ARTIFACT_FILE_MISSING — manifest lists '$_p' but the artifact does not contain it"; _bad=1; continue
			fi
			_actual=$(ss_sha256_file "$ARTIFACT_DIR/$_p") || _actual=""
			if [ "$_actual" != "$_d" ]; then
				reject "ARTIFACT_DIGEST_MISMATCH — '$_p' hashes to '${_actual:-unreadable}', manifest says '$_d' (substituted or truncated content)"; _bad=1
			fi
		done
		# Extra files that the manifest does not cover are unverified content.
		# POSIX sh: no process substitution — the listed set goes through a temp file.
		# Exclude the manifest by its EXACT path. `! -name <basename>` skipped EVERY file
		# with that name at any depth, so a nested decoy
		# (reports/sentinel-shield-artifact-manifest.json, not the real manifest and not
		# listed in .files) never reached the unverified-files check — unverified content
		# inside a verified artifact, which is exactly what this rule exists to prevent.
		_mrel=${MANIFEST#"$ARTIFACT_DIR/"}
		(cd "$ARTIFACT_DIR" && find . -type f 2>/dev/null) |
			sed 's|^\./||' | grep -Fxv "$_mrel" | sort > "$TMPDIR_VH/present"
		jq -r '(.files // [])[].path' "$MANIFEST" | sort > "$TMPDIR_VH/listed"
		_unlisted=$(grep -Fxv -f "$TMPDIR_VH/listed" "$TMPDIR_VH/present" 2>/dev/null || true)
		if [ -n "$_unlisted" ]; then
			reject "ARTIFACT_UNVERIFIED_FILES — the artifact contains file(s) the manifest does not cover: $(printf '%s' "$_unlisted" | tr '\n' ' ')"
			_bad=1
		fi
		[ "$_bad" -eq 0 ] && ok "artifact contents match the checksum manifest ($_files file(s))"
	fi
fi

# --- (14) the summary's OWN metadata binds it to this commit ------------------------------
# EXACTLY ONE candidate, and it must be one the manifest covers. The old resolution tried the
# declared path, then the basename at the artifact root, then `find -print -quit` — which
# selects whichever match the filesystem returns FIRST when two manifest-covered files share
# the basename. Choosing between candidates is exactly the ambiguity this verifier exists to
# refuse, so both fallbacks are gone: the flattened layout is resolved from the MANIFEST, not
# by searching.
_sum="$ARTIFACT_DIR/$SUMMARY_REL"
if [ ! -f "$_sum" ] && [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
	# The manifest lists repository-relative paths; accept the one whose path ENDS with the
	# declared summary path, and only when there is exactly one such entry.
	# `upload-artifact` roots the archive at the least common ancestor, so a real handoff
	# arrives FLAT and the manifest path is the declared path with leading components
	# dropped. Both directions are therefore accepted — but only ever ONE entry.
	# The path is BOUND first: inside `$s | endswith("/" + .)` the pipe rebinds `.` to $s,
	# so the suffix test would compare $s against itself and never match.
	_cand=$(jq -r --arg s "$SUMMARY_REL" '[ (.files // [])[] | .path as $p
		| select($p == $s or ($p | endswith("/" + $s)) or ($s | endswith("/" + $p)))
		| $p ] | unique | .[]' "$MANIFEST" 2>/dev/null || true)
	_ncand=$(printf '%s\n' "$_cand" | sed '/^$/d' | wc -l | tr -d ' ')
	case "$_ncand" in '' | *[!0-9]*) _ncand=0 ;; esac
	if [ "$_ncand" -gt 1 ]; then
		reject "SUMMARY_AMBIGUOUS — the manifest covers $_ncand files matching '$SUMMARY_REL'; the verifier never picks between candidates: $(printf '%s' "$_cand" | tr '\n' ' ')"
	elif [ "$_ncand" -eq 1 ]; then
		_rel=$(printf '%s\n' "$_cand" | sed '/^$/d' | head -1)
		[ -f "$ARTIFACT_DIR/$_rel" ] && _sum="$ARTIFACT_DIR/$_rel"
		# The flattened layout drops the leading directory component.
		[ -f "$_sum" ] || { [ -f "$ARTIFACT_DIR/$(basename "$_rel")" ] && _sum="$ARTIFACT_DIR/$(basename "$_rel")"; }
	fi
fi
if [ ! -f "$_sum" ] || ! jq -e . "$_sum" >/dev/null 2>&1; then
	reject "SUMMARY_MISSING — no readable security summary at '$SUMMARY_REL' inside the artifact (the path must be declared in the checksum manifest; it is never searched for)"
else
	_scommit=$(jq -r '(.source.commit // "") | ascii_downcase' "$_sum")
	_sbranch=$(jq -r '(.source.branch // "")' "$_sum")
	_sworkflow=$(jq -r '(.source.workflow // "")' "$_sum")
	if [ "$_scommit" = "$EXP_COMMIT" ]; then ok "the summary is self-bound to $EXP_COMMIT"
	else reject "SUMMARY_WRONG_COMMIT — the summary records source.commit '$_scommit', not the commit being gated '$EXP_COMMIT'"; fi
	if in_list "$_sbranch" "$EXP_REFS" || in_list "refs/heads/$_sbranch" "$EXP_REFS"; then
		ok "the summary's branch is on the trusted-ref allowlist"
	else
		reject "SUMMARY_UNTRUSTED_BRANCH — the summary records source.branch '$_sbranch', which is not on the trusted-ref allowlist"
	fi
	if in_list "$_sworkflow" "$EXP_WORKFLOWS"; then ok "the summary names an allowlisted producer workflow"
	else reject "SUMMARY_WRONG_WORKFLOW — the summary records source.workflow '$_sworkflow', which is not on the allowlist"; fi
fi

if [ "$FORMAT" = json ]; then
	jq -n --arg repo "$EXP_REPO" --arg commit "$EXP_COMMIT" --arg run "$ACCEPTED_ID" \
		--argjson rejections "$REJECTIONS" --arg reasons "$REASONS" \
		'{verified: ($rejections == 0), repository: $repo, commit: $commit, producer_run_id: $run,
		  rejections: $rejections, reasons: ($reasons | split("\n") | map(select(. != "")))}'
	[ "$REJECTIONS" -eq 0 ] && exit 0 || exit 1
fi

printf '\n----\n'
if [ "$REJECTIONS" -eq 0 ]; then
	printf 'verify-evidence-handoff: VERIFIED (run %s, commit %s)\n' "$ACCEPTED_ID" "$EXP_COMMIT"
	exit 0
fi
printf 'verify-evidence-handoff: REJECTED (%d rule violation(s)); fail closed\n' "$REJECTIONS"
exit 1
