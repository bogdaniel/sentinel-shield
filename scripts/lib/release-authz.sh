#!/bin/sh
# Sentinel Shield — production release authorization library (POSIX sh, ra_* functions).
#
# Source this file; do NOT execute it. It backs scripts/authorize-production-release.sh and
# scripts/verify-published-release.sh with the fail-closed validators behind release
# preparation, candidate verification, authorization-record governance, and the
# never-delete/never-move destructive-operation guard.
#
# Requires scripts/lib/sentinel-shield-common.sh (log_*/command_exists) sourced FIRST, and jq.
# All validators FAIL CLOSED: missing / empty / malformed / non-conformant input returns
# non-zero, and callers MUST treat that as a gate failure — never a pass. This library
# enables no `set -eu`, logs to STDERR only, and records NO secrets or local key paths.
#
# Standard return codes used by the ra_* validators that distinguish malformed from rejected:
#   0 ok/pass    1 rejected (well-formed but does not satisfy the gate)    2 malformed/fail-closed

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_RELEASE_AUTHZ_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null
fi
__SENTINEL_SHIELD_RELEASE_AUTHZ_LOADED=1

# RA_TIMEOUT is read by callers to distinguish a timed-out bounded operation (distinct
# exit code 4) from a clean result.
RA_TIMEOUT=0

# ra_bounded <seconds> <cmd...> — run a bounded operation. When a timeout tool is present,
# wrap the command; on timeout set RA_TIMEOUT=1 and return 124. Without a timeout tool the
# command runs directly (git/jq over local files cannot hang on I/O), preserving behaviour
# on hosts (e.g. stock macOS) that ship no timeout(1).
ra_bounded() {
	_ra_lim=$1
	shift
	if command_exists timeout; then
		timeout "$_ra_lim" "$@"
		_ra_rc=$?
	elif command_exists gtimeout; then
		gtimeout "$_ra_lim" "$@"
		_ra_rc=$?
	else
		"$@"
		_ra_rc=$?
	fi
	# RA_TIMEOUT is consumed cross-file by the caller scripts; shellcheck cannot see that.
	# shellcheck disable=SC2034
	if [ "$_ra_rc" = 124 ]; then RA_TIMEOUT=1; fi
	return "$_ra_rc"
}

# ra_today_utc — current date as YYYY-MM-DD (UTC), overridable for deterministic tests via
# SENTINEL_SHIELD_RELEASE_NOW (falls back to the shared security override, then to date(1)).
ra_today_utc() {
	if [ -n "${SENTINEL_SHIELD_RELEASE_NOW:-}" ]; then
		printf '%s' "$SENTINEL_SHIELD_RELEASE_NOW"
	elif [ -n "${SENTINEL_SHIELD_SECURITY_NOW:-}" ]; then
		printf '%s' "$SENTINEL_SHIELD_SECURITY_NOW"
	else
		date -u +%Y-%m-%d
	fi
}

# ra_is_hex40 <value> — 0 iff EXACTLY 40 lowercase-or-upper hex chars.
ra_is_hex40() {
	case "${1:-}" in
		"" | *[!0-9A-Fa-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 40 ]
}

# ra_is_hex64 <value> — 0 iff EXACTLY 64 lowercase-or-upper hex chars.
ra_is_hex64() {
	case "${1:-}" in
		"" | *[!0-9A-Fa-f]*) return 1 ;;
	esac
	[ "${#1}" -eq 64 ]
}

# ra_json_ok <path> — 0 iff file exists, is non-empty, and is valid JSON.
ra_json_ok() {
	[ -n "${1:-}" ] && [ -s "$1" ] || return 1
	command_exists jq || return 1
	jq -e . "$1" >/dev/null 2>&1
}

# --- destructive-operation guard ---------------------------------------------
# ra_guard_destructive <all-argv...> — REFUSE the operation (return 2, logging) if any
# forbidden destructive tag/release flag is present anywhere in argv. A Sentinel Shield
# rollback NEVER deletes or moves a released tag and NEVER deletes a GitHub Release; it
# publishes a superseding fixed release instead. This guard is called by every mode so an
# attempted tag movement or release deletion is refused up-front.
ra_guard_destructive() {
	for _ra_a in "$@"; do
		case "$_ra_a" in
			--delete-tag | --move-tag | --force-tag | --retag | --overwrite-tag \
				| --delete-release | --remove-release | --unpublish | --delete-published \
				| --rewrite-history | --force-push)
				log_error "ra_guard_destructive: refusing '$_ra_a' — Sentinel Shield NEVER deletes or moves a released tag or deletes a published release."
				log_error "Roll forward instead: publish a SUPERSEDING fixed release and mark the affected version via 'declare-superseded'/'rollback-advisory'."
				return 2
				;;
		esac
	done
	return 0
}

# --- generic gate reader -----------------------------------------------------
# ra_gate_ok <path> — 0 iff the JSON report presents an explicit green verdict and no
# explicit incompleteness/failure signal. Recognizes result|decision|status|verdict in a
# fixed pass vocabulary and additionally requires: incomplete!=true, complete!=false,
# missing[] empty, failure_count==0. An unrecognized/empty verdict FAILS CLOSED.
ra_gate_ok() {
	ra_json_ok "$1" || {
		log_error "ra_gate_ok: '${1:-}' is missing/empty/not JSON (fail closed)"
		return 1
	}
	jq -e '
		((.result? // .decision? // .status? // .verdict? // "") | tostring | ascii_downcase) as $d
		| ($d == "pass" or $d == "accepted" or $d == "accepted-emergency" or $d == "ready"
			or $d == "complete" or $d == "green" or $d == "ok" or $d == "success")
			and ((.incomplete // false) == false)
			and ((.complete // true) == true)
			and (((.missing // []) | length) == 0)
			and (((.failure_count // 0)) == 0)
	' "$1" >/dev/null 2>&1
}

# ra_security_acceptance_ok <path> — 0 iff a conformant security-acceptance report with a
# green decision (accepted | accepted-emergency). Requires enough structure that a bare
# {"decision":"accepted"} cannot masquerade as a full acceptance record.
ra_security_acceptance_ok() {
	ra_json_ok "$1" || {
		log_error "ra_security_acceptance_ok: '${1:-}' missing/empty/not JSON (fail closed)"
		return 1
	}
	jq -e '
		(.schema_version == "1")
		and (.decision | . == "accepted" or . == "accepted-emergency")
		and (.findings | type == "object")
		and ((.findings.blocking // 0) == 0)
		and (.violations | type == "array")
		and ((.violations | length) == 0)
	' "$1" >/dev/null 2>&1
}

# --- canonical required release-workflow policy ------------------------------
# ra_required_workflows_ok <policy> — 0 iff <policy> is a well-formed CANONICAL required-
# workflow set: a repository (owner/repo), a non-empty approved_events[] drawn ONLY from the
# default-branch events (push|workflow_dispatch), and a non-empty required_workflows[] of
# distinct { workflow_name:non-empty-string, artifacts_required:boolean } entries. A policy
# that admits pull_request (or any non-default-branch event) as approved, or that repeats a
# workflow_name, is REJECTED — release proof is default-branch only and per-workflow unique.
# Returns 0 ok, 2 malformed/missing (fail closed).
ra_required_workflows_ok() {
	ra_json_ok "${1:-}" || {
		log_error "ra_required_workflows_ok: policy '${1:-}' missing/empty/not JSON (fail closed)"
		return 2
	}
	jq -e '
		def repo: (type == "string") and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$");
		(.repository | repo)
		and (.approved_events | type == "array" and (length >= 1)
			and all(.[]; . == "push" or . == "workflow_dispatch"))
		and (.required_workflows | type == "array" and (length >= 1)
			and all(.[]; (.workflow_name | type == "string" and (length > 0))
				and (.artifacts_required | type == "boolean")))
		and ((.required_workflows | map(.workflow_name) | length)
			== (.required_workflows | map(.workflow_name) | unique | length))
	' "$1" >/dev/null 2>&1 || {
		log_error "ra_required_workflows_ok: '$1' is not a conformant required-workflow policy (fail closed)"
		return 2
	}
	return 0
}

# --- evidence source / COMPLETE required-workflow-set gate --------------------
# ra_check_evidence_source <evidence> <source_commit> <policy> [validator] — prove the
# candidate's source commit is backed by the COMPLETE canonical set of required default-branch
# CI workflows, NOT merely "at least one successful run". All steps fail closed:
#   1. structural + semantic integrity is delegated to the existing GitHub-backed evidence
#      validator (scripts/validate-release-evidence.sh --offline) when its path is supplied, so
#      this gate never re-implements a second, weaker evidence parser;
#   2. evidence.engine_commit must equal the expected source_commit;
#   3. the required-workflow set is loaded from the CANONICAL policy (config/*.json), NOT a
#      hardcoded list, and for EVERY required workflow there must be EXACTLY ONE authoritative
#      run: exact workflow_name, exact repository, exact source_commit, an approved default-
#      branch event, a successful conclusion, and the declared artifact state.
# REJECTS (return 1): a missing required workflow; a PR-only / non-default-branch run; an
# unrelated workflow standing in for a required one; a wrong repository / branch(event) /
# commit; a failed / cancelled / neutral / skipped run; and duplicate successful runs for one
# required workflow (ambiguous authority). Per-workflow head_branch proof against the live
# default branch remains the job of validate-release-evidence.sh --verify-github, which this
# gate reuses rather than duplicating. Returns: 0 ok, 1 rejected, 2 malformed/unverifiable.
ra_check_evidence_source() {
	_rev="$1"
	_rsrc="$2"
	_rpol="${3:-}"
	_rval="${4:-}"
	ra_json_ok "$_rev" || {
		log_error "ra_check_evidence_source: evidence '${_rev:-}' missing/empty/not JSON (fail closed)"
		return 2
	}
	ra_is_hex40 "$_rsrc" || {
		log_error "ra_check_evidence_source: --source-commit is not a 40-hex SHA"
		return 2
	}
	_rsrc=$(printf '%s' "$_rsrc" | tr 'A-F' 'a-f')
	ra_required_workflows_ok "$_rpol" || return 2

	# (1) Reuse the existing evidence validator for structural + semantic integrity.
	if [ -n "$_rval" ] && [ -f "$_rval" ]; then
		_vrc=0
		ra_bounded "${RA_BOUND_SECS:-120}" sh "$_rval" --file "$_rev" --offline >/dev/null || _vrc=$?
		case "$_vrc" in
			0) ;;
			124) log_error "ra_check_evidence_source: evidence validation TIMED OUT (fail closed)"; return 2 ;;
			2 | 3) log_error "ra_check_evidence_source: EVIDENCE_INVALID — validator rejected the evidence as malformed/unverifiable (exit $_vrc, fail closed)"; return 2 ;;
			*) log_error "ra_check_evidence_source: EVIDENCE_UNMET — validator rejected the evidence (exit $_vrc)"; return 1 ;;
		esac
	fi

	# (2) The evidence's engine_commit must equal the expected source commit.
	_reng=$(jq -r '.engine_commit // ""' "$_rev")
	if [ "$_reng" != "$_rsrc" ]; then
		log_error "ra_check_evidence_source: SOURCE_COMMIT_MISMATCH — evidence engine_commit ($_reng) != expected source_commit ($_rsrc)"
		return 1
	fi

	# (3) EVERY required workflow must have EXACTLY ONE authoritative default-branch run.
	_reasons=$(jq -r --arg c "$_rsrc" --slurpfile pol "$_rpol" '
		($pol[0]) as $p
		| ($p.repository) as $repo
		| ($p.approved_events) as $ev
		| (.engine_ci // []) as $ci
		| [ $p.required_workflows[] as $w
			| ($ci | map(select(.workflow_name == $w.workflow_name))) as $named
			| ($named | map(. as $r | select(
					$r.repository == $repo
					and $r.commit == $c
					and (($ev | index($r.event)) != null)
					and $r.result == "success"
					and (if $w.artifacts_required then ($r.artifacts_verified == true) else true end)
				))) as $ok
			| if ($ok | length) == 1 then empty
			  elif ($ok | length) > 1 then "DUPLICATE_AUTHORITY:\($w.workflow_name) (\($ok | length) successful runs; no deterministic authority)"
			  elif ($named | length) == 0 then "MISSING_WORKFLOW:\($w.workflow_name)"
			  elif (($named | map(. as $r | select(($ev | index($r.event)) != null)) | length) == 0)
			       then "NON_DEFAULT_BRANCH_EVENT:\($w.workflow_name) (events \([ $named[].event ] | unique | join(",")); default-branch push/workflow_dispatch required)"
			  elif (($named | map(select(.repository == $repo)) | length) == 0)
			       then "WRONG_REPOSITORY:\($w.workflow_name) (\([ $named[].repository ] | unique | join(",")) != \($repo))"
			  elif (($named | map(select(.commit == $c)) | length) == 0)
			       then "WRONG_COMMIT:\($w.workflow_name)"
			  elif (($named | map(select(.result == "success")) | length) == 0)
			       then "NOT_SUCCESSFUL:\($w.workflow_name) (\([ $named[].result ] | unique | join(",")))"
			  elif ($w.artifacts_required and (($named | map(select(.artifacts_verified == true)) | length) == 0))
			       then "ARTIFACT_STATE:\($w.workflow_name) (expected verified artifacts)"
			  else "UNSATISFIED:\($w.workflow_name)" end
		  ]
		| unique | .[]
	' "$_rev" 2>/dev/null) || {
		log_error "ra_check_evidence_source: could not evaluate the required-workflow set (fail closed)"
		return 2
	}
	if [ -n "$_reasons" ]; then
		printf '%s\n' "$_reasons" | while IFS= read -r _r; do
			[ -n "$_r" ] && log_error "ra_check_evidence_source: INCOMPLETE_RELEASE_WORKFLOW_SET — $_r"
		done
		return 1
	fi
	return 0
}

# --- waiver expiry gate ------------------------------------------------------
# ra_no_expired_waivers <accepted-risks|""> [today] — 0 iff no waiver has expired. An absent/
# empty file is a valid no-waivers state (0). Returns 1 when an approved waiver is expired,
# 2 when the file is present but malformed. Dates are ISO YYYY-MM-DD (lexical compare is
# correct for that form).
ra_no_expired_waivers() {
	_rwf="${1:-}"
	_rtoday="${2:-$(ra_today_utc)}"
	[ -n "$_rwf" ] && [ -f "$_rwf" ] && [ -s "$_rwf" ] || return 0
	ra_json_ok "$_rwf" || {
		log_error "ra_no_expired_waivers: '$_rwf' is not valid JSON (fail closed)"
		return 2
	}
	jq -e 'type == "object" and (.risks | type == "array")' "$_rwf" >/dev/null 2>&1 || {
		log_error "ra_no_expired_waivers: '$_rwf' must be an object with a 'risks' array (fail closed)"
		return 2
	}
	case "$_rtoday" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
		*) log_error "ra_no_expired_waivers: reference date '$_rtoday' is not YYYY-MM-DD"; return 2 ;;
	esac
	_bad=$(jq -r --arg today "$_rtoday" '
		[ .risks[]
		  | select((.expires_at // "") == "" or (.expires_at < $today)) | .id // "?" ]
		| join(",")' "$_rwf" 2>/dev/null) || {
		log_error "ra_no_expired_waivers: could not evaluate waivers (fail closed)"
		return 2
	}
	if [ -n "$_bad" ]; then
		log_error "ra_no_expired_waivers: EXPIRED_WAIVER — expired/undated waiver(s): $_bad (as of $_rtoday)"
		return 1
	fi
	return 0
}

# --- artifact-digest reproducibility gate ------------------------------------
# ra_artifacts_match_manifest <artifacts-report> <manifest> [required-workflows-policy]
# Fail-closed proof that the COMPLETE set of verified artifacts in the verification
# <artifacts-report> is IDENTICAL — on full IDENTITY, not merely digest — to the artifact set
# fingerprinted in the release <manifest> body.
#
# BEFORE any set comparison every artifact record on BOTH sides is validated against the
# required identity tuple. A report record must carry: artifact_id (integer > 0), name
# (non-empty), workflow_run_id/run_id (non-empty scalar), repository (owner/name),
# size_in_bytes (integer >= 0), sha256 (EXACTLY 64 lowercase hex), expired == false,
# verified == true. A manifest record must carry the shared identity: run_id, artifact_id,
# name, sha256 (64-hex). A MALFORMED digest is REJECTED — never silently filtered out; the
# historical bug was that malformed digests collapsed to two empty equal arrays that then
# compared equal and spuriously PASSED. Missing identity, duplicate records, and conflicting
# identities (the same run_id+artifact_id carrying a different name/sha256) are REJECTED. The
# surviving report and manifest identity tuples must then match EXACTLY.
#
# Zero artifacts is a match ONLY when it is genuinely zero on both sides (no records present,
# not "records present but filtered away") AND, when a required-workflow <policy> is supplied,
# no required workflow declares artifacts_required:true — a release whose policy configures any
# artifact-producing workflow MUST ship at least one verified artifact.
#
# Returns: 0 match; 1 rejected (identity/digest drift, or zero where artifacts are required);
#          2 malformed/unverifiable input (fail closed).
ra_artifacts_match_manifest() {
	_ram_report="$1"
	_ram_manifest="$2"
	_ram_policy="${3:-}"
	ra_json_ok "$_ram_report" || { log_error "ra_artifacts_match_manifest: artifacts report '${_ram_report:-}' not JSON (fail closed)"; return 2; }
	ra_json_ok "$_ram_manifest" || { log_error "ra_artifacts_match_manifest: manifest '${_ram_manifest:-}' not JSON (fail closed)"; return 2; }

	# (1) Validate + normalize the REPORT artifact identity tuples (fail closed on any
	#     malformed record, missing identity, malformed digest, duplicate, or conflict).
	_ram_r=$(jq -c '
		def hex64: type == "string" and test("^[0-9a-f]{64}$");
		def sk: (type == "number" or type == "string");
		(.artifacts) as $a
		| if ($a | type) != "array" then { ok:false, reasons:["REPORT_ARTIFACTS_NOT_ARRAY"], tuples:[] }
		  else
			[ $a[] | { run_id, artifact_id, name, sha256,
				bad:[
					(if (.artifact_id|type)=="number" and (.artifact_id>0) then empty else "artifact_id" end),
					(if (.name|type)=="string" and ((.name|length)>0) then empty else "artifact_name" end),
					(if (.run_id|sk) and ((.run_id|tostring|length)>0) then empty else "workflow_run_id" end),
					(if (.repository|type)=="string" and (.repository|test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")) then empty else "repository" end),
					(if (.size_in_bytes|type)=="number" and (.size_in_bytes>=0) then empty else "size" end),
					(if (.sha256|hex64) then empty else "sha256" end),
					(if .expired==false then empty else "expired" end),
					(if .verified==true then empty else "verified" end)
				] } ] as $r
			| [ $r[] | select((.bad|length)>0) | "record["+(.artifact_id|tostring)+":"+(.bad|join("+"))+"]" ] as $mal
			| [ $r[] | { run_id:(.run_id|tostring), artifact_id:(.artifact_id|tostring), name, sha256 } ] as $ids
			| ($ids | group_by([.run_id,.artifact_id])) as $g
			| [ $g[] | select(length>1) | { k:(.[0].run_id+"/"+.[0].artifact_id), d:(map({name,sha256})|unique|length) } ] as $m
			| [ $m[] | select(.d>1) | .k ] as $conf
			| [ $m[] | select(.d==1) | .k ] as $dup
			| { ok: (($mal|length)==0 and ($conf|length)==0 and ($dup|length)==0),
				reasons: ($mal + ($conf|map("CONFLICTING_IDENTITY:"+.)) + ($dup|map("DUPLICATE_RECORD:"+.))),
				tuples: ($ids | unique) }
		  end
	' "$_ram_report" 2>/dev/null) || {
		log_error "ra_artifacts_match_manifest: could not validate artifact report records (fail closed)"
		return 2
	}
	if [ "$(printf '%s' "$_ram_r" | jq -r '.ok')" != true ]; then
		log_error "ra_artifacts_match_manifest: REPORT artifact identity invalid — $(printf '%s' "$_ram_r" | jq -rc '.reasons') (fail closed)"
		return 2
	fi

	# (2) Validate + normalize the MANIFEST artifact identity tuples (fail closed).
	_ram_m=$(jq -c '
		def hex64: type == "string" and test("^[0-9a-f]{64}$");
		def sk: (type == "number" or type == "string");
		(.body.artifact_digests) as $a
		| if ($a == null) then { ok:true, reasons:[], tuples:[] }
		  elif ($a | type) != "array" then { ok:false, reasons:["MANIFEST_ARTIFACT_DIGESTS_NOT_ARRAY"], tuples:[] }
		  else
			[ $a[] | { run_id, artifact_id, name, sha256,
				bad:[
					(if (.artifact_id|type)=="number" and (.artifact_id>0) then empty else "artifact_id" end),
					(if (.name|type)=="string" and ((.name|length)>0) then empty else "name" end),
					(if (.run_id|sk) and ((.run_id|tostring|length)>0) then empty else "run_id" end),
					(if (.sha256|hex64) then empty else "sha256" end)
				] } ] as $r
			| [ $r[] | select((.bad|length)>0) | "digest["+(.artifact_id|tostring)+":"+(.bad|join("+"))+"]" ] as $mal
			| [ $r[] | { run_id:(.run_id|tostring), artifact_id:(.artifact_id|tostring), name, sha256 } ] as $ids
			| ($ids | group_by([.run_id,.artifact_id])) as $g
			| [ $g[] | select(length>1) | { k:(.[0].run_id+"/"+.[0].artifact_id), d:(map({name,sha256})|unique|length) } ] as $m
			| [ $m[] | select(.d>1) | .k ] as $conf
			| [ $m[] | select(.d==1) | .k ] as $dup
			| { ok: (($mal|length)==0 and ($conf|length)==0 and ($dup|length)==0),
				reasons: ($mal + ($conf|map("CONFLICTING_IDENTITY:"+.)) + ($dup|map("DUPLICATE_RECORD:"+.))),
				tuples: ($ids | unique) }
		  end
	' "$_ram_manifest" 2>/dev/null) || {
		log_error "ra_artifacts_match_manifest: could not validate manifest artifact_digests (fail closed)"
		return 2
	}
	if [ "$(printf '%s' "$_ram_m" | jq -r '.ok')" != true ]; then
		log_error "ra_artifacts_match_manifest: MANIFEST artifact identity invalid — $(printf '%s' "$_ram_m" | jq -rc '.reasons') (fail closed)"
		return 2
	fi

	# (3) Canonical identity sets (key-sorted, already unique).
	_ram_rt=$(printf '%s' "$_ram_r" | jq -Sc '.tuples')
	_ram_mt=$(printf '%s' "$_ram_m" | jq -Sc '.tuples')

	# (4) Zero-artifact policy: genuinely empty on both sides is a match only when policy
	#     (if supplied) does not require artifacts.
	if [ "$_ram_rt" = '[]' ] && [ "$_ram_mt" = '[]' ]; then
		if [ -n "$_ram_policy" ]; then
			ra_json_ok "$_ram_policy" || { log_error "ra_artifacts_match_manifest: required-workflow policy '$_ram_policy' not JSON (fail closed)"; return 2; }
			if jq -e '[ .required_workflows[]? | select(.artifacts_required == true) ] | length > 0' "$_ram_policy" >/dev/null 2>&1; then
				log_error "ra_artifacts_match_manifest: ZERO_ARTIFACTS_NOT_PERMITTED — policy configures artifact-producing required workflow(s) but no verified artifacts were presented (fail closed)"
				return 1
			fi
		fi
		return 0
	fi

	# (5) EXACT identity-tuple set equality between report and manifest.
	if [ "$_ram_rt" != "$_ram_mt" ]; then
		log_error "ra_artifacts_match_manifest: DIGEST_MISMATCH — verified artifact identity set does not equal the manifest fingerprint (report=$_ram_rt manifest=$_ram_mt)"
		return 1
	fi
	return 0
}

# --- candidate descriptor validation -----------------------------------------
# ra_validate_candidate <descriptor> — fail-closed structural conformance to
# schemas/release-candidate.schema.json (the parts jq can express). 0 valid, else non-zero.
ra_validate_candidate() {
	ra_json_ok "$1" || {
		log_error "ra_validate_candidate: '${1:-}' missing/empty/not JSON (fail closed)"
		return 1
	}
	jq -e '
		(.schema_version == "1")
		and (.version | type == "string" and (length > 0))
		and (.stage | . == "beta" or . == "rc" or . == "ga")
		and (.release_scope | . == "engine-only" or . == "framework-validated" or . == "full-platform")
		and (.source_commit | type == "string" and test("^[0-9a-f]{40}$"))
		and (.tag | type == "string" and (length > 0))
		and (.artifacts | type == "object")
	' "$1" >/dev/null 2>&1 || {
		log_error "ra_validate_candidate: '$1' does not conform to release-candidate.schema.json"
		return 1
	}
	return 0
}

# --- authorization record validation -----------------------------------------
# ra_validate_authorization <record> — fail-closed STRUCTURAL conformance to
# schemas/release-authorization.schema.json. Cross-field binding to a candidate is checked by
# the caller (ra_authorization_binds). Returns 0 valid, 2 malformed/non-conformant.
ra_validate_authorization() {
	ra_json_ok "$1" || {
		log_error "ra_validate_authorization: '${1:-}' missing/empty/not JSON (fail closed)"
		return 2
	}
	jq -e '
		def isodt: (type == "string") and test("^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$");
		(.schema_version == "1")
		and (.version | type == "string" and (length > 0))
		and (.stage | . == "beta" or . == "rc" or . == "ga")
		and (.release_scope | . == "engine-only" or . == "framework-validated" or . == "full-platform")
		and (.source_commit | type == "string" and test("^[0-9a-f]{40}$"))
		and (.tag | type == "string" and (length > 0))
		and (.candidate_hash | type == "string" and test("^[0-9a-f]{64}$"))
		and (.authorization | type == "object")
		and (.authorization.method | . == "interactive" or . == "signed")
		and (.authorization.token | type == "string" and (length >= 8))
		and (.authorization.requested_by | type == "string" and (length > 0))
		and (.authorization.approved_by | type == "string" and (length > 0))
		and (.created_at | isodt)
		and (.expires_at | isodt)
	' "$1" >/dev/null 2>&1 || {
		log_error "ra_validate_authorization: '$1' does not conform to release-authorization.schema.json"
		return 2
	}
	return 0
}

# ra_authorization_binds <record> <version> <stage> <scope> <source_commit> <tag> <candidate_hash> [today] [confirm_token]
# Enforce the cross-field governance rules JSON Schema cannot: the record must match the
# VERIFIED candidate on every identity field, forbid self-approval, be unexpired, and (for
# the interactive method) require the supplied --confirm-token to equal authorization.token.
# Returns 0 authorized, 1 governance-rejected. Assumes ra_validate_authorization already passed.
ra_authorization_binds() {
	_rrec="$1"
	_rv="$2"
	_rs="$3"
	_rsc="$4"
	_rcommit="$5"
	_rtag="$6"
	_rhash="$7"
	_rtoday="${8:-$(ra_today_utc)}"
	_rconfirm="${9:-}"
	_rerr=$(jq -r \
		--arg v "$_rv" --arg s "$_rs" --arg sc "$_rsc" --arg c "$_rcommit" \
		--arg tag "$_rtag" --arg h "$_rhash" --arg today "$_rtoday" '
		def d2i(s): (s | split("-") | (.[0]|tonumber)*10000 + (.[1]|tonumber)*100 + (.[2]|tonumber));
		. as $r
		| [
			(if $r.version == $v then empty else "version mismatch: record=\($r.version) candidate=\($v)" end),
			(if $r.stage == $s then empty else "stage mismatch: record=\($r.stage) candidate=\($s)" end),
			(if $r.release_scope == $sc then empty else "release_scope mismatch: record=\($r.release_scope) candidate=\($sc)" end),
			(if $r.source_commit == $c then empty else "source_commit mismatch: record=\($r.source_commit) candidate=\($c)" end),
			(if $r.tag == $tag then empty else "tag mismatch: record=\($r.tag) candidate=\($tag)" end),
			(if $r.candidate_hash == $h then empty else "candidate_hash mismatch: record does not authorize this manifest fingerprint" end),
			(if $r.authorization.requested_by != $r.authorization.approved_by then empty else "self-approval FORBIDDEN: requested_by == approved_by (\($r.authorization.requested_by))" end),
			(if (d2i($r.expires_at[0:10]) >= d2i($today)) then empty else "EXPIRED: expires_at=\($r.expires_at) is not on/after \($today)" end)
		  ]
		| .[]
	' "$_rrec" 2>/dev/null) || {
		log_error "ra_authorization_binds: governance check failed to evaluate (fail closed)"
		return 1
	}
	if [ -n "$_rerr" ]; then
		printf '%s\n' "$_rerr" | while IFS= read -r _l; do [ -n "$_l" ] && log_error "ra_authorization_binds: $_l"; done
		return 1
	fi
	# Interactive method: the confirmation token must be re-supplied and match.
	_rmethod=$(jq -r '.authorization.method' "$_rrec")
	if [ "$_rmethod" = interactive ]; then
		_rtok=$(jq -r '.authorization.token' "$_rrec")
		if [ -z "$_rconfirm" ] || [ "$_rconfirm" != "$_rtok" ]; then
			log_error "ra_authorization_binds: interactive authorization requires --confirm-token to equal the record's authorization.token (fail closed)"
			return 1
		fi
	fi
	return 0
}
