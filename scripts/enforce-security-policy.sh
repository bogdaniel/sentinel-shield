#!/bin/sh
# Sentinel Shield — production security acceptance gate.
#
# The FINAL security decision point for a production release. It consumes the canonical
# production security policy (config/production-security-policy.json), a NORMALIZED
# security summary (produced by scripts/normalize-security-summary.sh), an accepted-risks
# waiver file (schemas/accepted-risks.schema.json + v1.11 fields) and an optional
# regression baseline, then PROVES and records — in a machine-readable acceptance report
# (schemas/security-acceptance.schema.json) — that:
#   * every REQUIRED scanner applicable to the target executed;
#   * each scanner's version + vulnerability-database freshness is within policy;
#   * target applicability + coverage are accounted for;
#   * each scanner's raw report has a verifiable digest;
#   * normalized findings were evaluated against blocking severities / categories;
#   * every suppression is a valid, owned, approved, issue-linked, unexpired,
#     narrowly-scoped waiver (no blanket scanner/package suppression);
#   * no unexplained drop in finding counts or target coverage occurred (regression);
#   * a documented emergency-release path is honoured when present.
#
# It NEVER prints secrets, tokens, signing-key paths, or repo-local absolute paths.
#
# Exit codes (fail closed):
#   0  accepted — all gates pass (decision "accepted" or "accepted-emergency").
#   1  rejected — one or more blocking violations (findings / scanner / regression).
#   2  configuration / input error — missing/malformed/non-conformant policy, summary,
#      waiver file, or an acceptance report that cannot be validated. FAIL CLOSED.
#   4  timeout — a bounded evaluation step timed out; the run is UNVERIFIABLE.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/security-policy.sh
. "$SCRIPT_DIR/lib/security-policy.sh"

POLICY="$REPO_ROOT/config/production-security-policy.json"
SUMMARY="reports/security-summary.json"
ACCEPTED_RISKS=".sentinel-shield/accepted-risks.json"
BASELINE=""
OUTPUT="reports/security-acceptance.json"
BOUND=60
SOURCE_COMMIT=""
WORKSPACE="$REPO_ROOT"

usage() {
	cat <<'EOF'
Usage: enforce-security-policy.sh [options]

Apply the production security acceptance gate and write an acceptance report.

Options:
  --policy <path>          Production security policy (default: config/production-security-policy.json)
  --summary <path>         Normalized security summary (default: reports/security-summary.json)
  --accepted-risks <path>  Accepted-risks waiver file (default: .sentinel-shield/accepted-risks.json)
  --baseline <path>        Security regression baseline (optional)
  --source-commit <sha>    Authoritative source commit the scan ran against. Used to
                           cross-check every non-applicability proof (default: summary .source.commit)
  --workspace <dir>        Repository tree to RECOMPUTE applicability against with cheap
                           filesystem checks (default: the Sentinel Shield repo root)
  --output <path>          Acceptance report to write (default: reports/security-acceptance.json)
  --timeout <seconds>      Bounded per-evaluation timeout (default: 60)
  -h, --help               Show this help

Exit: 0 accepted, 1 rejected, 2 config/input error, 4 timeout. Requires jq.
EOF
}

die_cfg() { log_error "$*"; exit 2; }

while [ $# -gt 0 ]; do case "$1" in
	--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
	--summary) SUMMARY="${2:?--summary requires a value}"; shift 2 ;;
	--accepted-risks) ACCEPTED_RISKS="${2:?--accepted-risks requires a value}"; shift 2 ;;
	--baseline) BASELINE="${2:?--baseline requires a value}"; shift 2 ;;
	--source-commit) SOURCE_COMMIT="${2:?--source-commit requires a value}"; shift 2 ;;
	--workspace) WORKSPACE="${2:?--workspace requires a value}"; shift 2 ;;
	--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
	--timeout) BOUND="${2:?--timeout requires a value}"; shift 2 ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die_cfg "unknown argument: $1" ;;
esac; done

case "$BOUND" in ''|*[!0-9]*) die_cfg "--timeout must be a positive integer" ;; esac

command_exists jq || die_cfg "jq is required to evaluate the security policy (install jq)."

# --- fail-closed input validation (bounded) ----------------------------------
sp_bounded "$BOUND" sp_validate_policy "$POLICY" || {
	[ "$SP_TIMEOUT" = 1 ] && { log_error "enforce-security-policy: policy validation timed out"; exit 4; }
	die_cfg "enforce-security-policy: policy invalid or missing: $POLICY"
}
sp_bounded "$BOUND" sp_validate_summary "$SUMMARY" || {
	[ "$SP_TIMEOUT" = 1 ] && { log_error "enforce-security-policy: summary validation timed out"; exit 4; }
	die_cfg "enforce-security-policy: normalized summary invalid/malformed/missing: $SUMMARY"
}
sp_bounded "$BOUND" sp_validate_waivers "$ACCEPTED_RISKS" "$POLICY" "$(sp_today_utc)" || {
	[ "$SP_TIMEOUT" = 1 ] && { log_error "enforce-security-policy: waiver validation timed out"; exit 4; }
	die_cfg "enforce-security-policy: accepted-risks waiver file rejected (fail closed): $ACCEPTED_RISKS"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM
SCAN_NDJSON="$WORK/scanners.ndjson"; : > "$SCAN_NDJSON"
VIOL_NDJSON="$WORK/violations.ndjson"; : > "$VIOL_NDJSON"
APPLIED_NDJSON="$WORK/applied.ndjson"; : > "$APPLIED_NDJSON"
REJECTED_NDJSON="$WORK/rejected.ndjson"; : > "$REJECTED_NDJSON"

TODAY=$(sp_today_utc)
POLICY_VERSION=$(jq -r '.policy_version' "$POLICY")
POL_BLOCKING=$(jq -r '.blocking_severities | join(" ")' "$POLICY")
POL_WAIVABLE=$(jq -r '.waivable_severities | join(" ")' "$POLICY")
POL_EMERG_WAIVABLE=$(jq -r '.emergency_waivable_severities | join(" ")' "$POLICY")
POL_NEVER_CAT=$(jq -r '.never_waivable_categories | join(" ")' "$POLICY")
POL_MIN_COV=$(jq -r '.regression_baseline.min_coverage_ratio' "$POLICY")
POL_REG_ENABLED=$(jq -r '.regression_baseline.enabled' "$POLICY")

# --- applicability-proof policy (independent proof of non-applicability) ------
# A scanner's `applicable:false` claim is NOT self-authenticating. Absent an
# `applicability` policy block, apply STRICT defaults (proof required; the four core
# engine scans always required; a fixed approved-reason list; reject all-non-applicable).
POL_APP_REQUIRE_PROOF=$(jq -r 'if (.applicability.require_independent_proof | type == "boolean") then .applicability.require_independent_proof else true end' "$POLICY")
POL_APP_REJECT_ALL=$(jq -r 'if (.applicability.reject_all_non_applicable | type == "boolean") then .applicability.reject_all_non_applicable else true end' "$POLICY")
POL_APP_ALWAYS=$(jq -r 'if (.applicability.always_required_categories | type == "array") then (.applicability.always_required_categories | join(" ")) else "leaked_secrets source_vulnerabilities container_findings workflow_vulnerabilities" end' "$POLICY")
POL_APP_DISABLED=$(jq -r 'if (.applicability.disabled_scanners | type == "array") then (.applicability.disabled_scanners | join(" ")) else "" end' "$POLICY")
POL_APP_REASONS=$(jq -r 'if (.applicability.approved_non_applicability_reasons | type == "array") then (.applicability.approved_non_applicability_reasons | join(" ")) else "no-dependency-manifests no-lockfiles no-container-image no-dockerfile no-workflows no-source-code" end' "$POLICY")

# Authoritative source commit the scan ran against: the --source-commit flag wins, else the
# summary's own .source.commit. Every non-applicability proof must name THIS commit, so a
# stale/foreign detector report cannot authenticate a fresh non-applicability claim.
EXPECTED_COMMIT="$SOURCE_COMMIT"
[ -n "$EXPECTED_COMMIT" ] || EXPECTED_COMMIT=$(jq -r '.source.commit // ""' "$SUMMARY")

# contains <space-list> <value> — 0 if <value> is a whitespace-delimited member.
contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

# recompute_applicable <applies_when> — INDEPENDENTLY recompute, with cheap filesystem
# checks against $WORKSPACE, whether this scanner class actually applies to the tree.
# Echoes "yes" (the tree triggers this class — a non-applicability claim is contradicted),
# "no" (no trigger found — the claim is consistent) or "unknown" (cannot cheaply decide).
# Bounded and read-only; never trusts the summary's own applicability assertion.
recompute_applicable() {
	case "$1" in
		always) printf 'yes'; return 0 ;;
		manifest_present)
			# tests/ and examples/ are pruned: they hold deliberately-vulnerable consumer/adopter
			# fixtures (test DATA), not the engine's own supply chain. Keeping this identical to
			# scripts/build-scanner-manifest.sh is what keeps the two recomputes from disagreeing.
			_hit=$(sp_bounded "$BOUND" find "$WORKSPACE" -maxdepth 4 \
				\( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
				\( -name package.json -o -name package-lock.json -o -name yarn.lock \
				   -o -name pnpm-lock.yaml -o -name composer.json -o -name composer.lock \
				   -o -name go.mod -o -name go.sum -o -name requirements.txt -o -name Pipfile \
				   -o -name pyproject.toml -o -name poetry.lock -o -name Cargo.toml \
				   -o -name Cargo.lock -o -name pom.xml -o -name build.gradle -o -name Gemfile \) \
				-print 2>/dev/null | head -n 1)
			[ -n "$_hit" ] && printf 'yes' || printf 'no'; return 0 ;;
		dockerfile_present)
			_hit=$(sp_bounded "$BOUND" find "$WORKSPACE" -maxdepth 4 \
				\( -name node_modules -o -name vendor -o -name .git -o -name tests -o -name examples \) -prune -o -type f \
				\( -name Dockerfile -o -name 'Dockerfile.*' -o -name '*.Dockerfile' -o -name 'Containerfile' \) ! -name '*.md' \
				-print 2>/dev/null | head -n 1)
			[ -n "$_hit" ] && printf 'yes' || printf 'no'; return 0 ;;
		workflows_present)
			if [ -d "$WORKSPACE/.github/workflows" ]; then
				_hit=$(sp_bounded "$BOUND" find "$WORKSPACE/.github/workflows" -maxdepth 1 -type f \
					\( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | head -n 1)
				[ -n "$_hit" ] && printf 'yes' || printf 'no'
			else
				printf 'no'
			fi
			return 0 ;;
		*) printf 'unknown'; return 0 ;;
	esac
}

add_violation() { # <category> <severity|-> <scanner|-> <reason>
	_vsev=$2; _vscan=$3
	[ "$_vsev" = "-" ] && _vsev=null || _vsev="\"$_vsev\""
	[ "$_vscan" = "-" ] && _vscan=null || _vscan="\"$_vscan\""
	jq -cn --arg cat "$1" --argjson sev "$_vsev" --argjson scan "$_vscan" --arg reason "$4" \
		'{category:$cat, severity:$sev, scanner:$scan, reason:$reason}' >> "$VIOL_NDJSON"
}

EMERGENCY_USED=0
NONAPP_COUNT=0

# --- scanner execution / freshness / applicability ---------------------------
# Iterate policy.required_scanners; correlate each with the summary scanner record.
_reqcount=$(jq -r '.required_scanners | length' "$POLICY")
_i=0
while [ "$_i" -lt "$_reqcount" ]; do
	_name=$(jq -r --argjson i "$_i" '.required_scanners[$i].name' "$POLICY")
	_cat=$(jq -r --argjson i "$_i" '.required_scanners[$i].category' "$POLICY")
	_appwhen=$(jq -r --argjson i "$_i" '.required_scanners[$i].applies_when' "$POLICY")
	_smax=$(jq -r --argjson i "$_i" '.required_scanners[$i].max_database_age_days // "null"' "$POLICY")
	# Freshness cap is per-scanner. A null cap means the scanner has no vulnerability
	# database (e.g. a SAST/secret/workflow linter) so freshness does NOT apply; only a
	# positive cap (e.g. dependency/container scanners) is checked against age_days.
	_cap=$_smax
	[ -n "$_cap" ] || _cap="null"

	# Locate the matching summary scanner record (by name).
	_rec=$(jq -c --arg n "$_name" 'first(.scanners[] | select(.name == $n)) // empty' "$SUMMARY")
	if [ -z "$_rec" ]; then
		# A required scanner with no record at all — fail closed (missing applicable scanner).
		jq -n --arg n "$_name" --arg c "$_cat" \
			'{name:$n, category:$c, applicable:true, executed:false, status:"missing", version:null, database_age_days:null, fresh:false, targets_scanned:null, raw_report_digest:null}' >> "$SCAN_NDJSON"
		add_violation "$_cat" "-" "$_name" "SCANNER_MISSING"
		_i=$((_i + 1)); continue
	fi

	_applicable=$(printf '%s' "$_rec" | jq -r '.applicable')
	_status=$(printf '%s' "$_rec" | jq -r '.status')
	_version=$(printf '%s' "$_rec" | jq -r '.version // "null"')
	_age=$(printf '%s' "$_rec" | jq -r '.database.age_days // "null"')
	_targets=$(printf '%s' "$_rec" | jq -r '.targets_scanned // "null"')
	_digest=$(printf '%s' "$_rec" | jq -r '.raw_report_digest // ""')

	_verjson=null; [ "$_version" != "null" ] && _verjson="\"$_version\""
	_agejson=null; case "$_age" in ''|null) _agejson=null ;; *[!0-9]*) _agejson=null ;; *) _agejson=$_age ;; esac
	_tgtjson=null; case "$_targets" in ''|null) _tgtjson=null ;; *[!0-9]*) _tgtjson=null ;; *) _tgtjson=$_targets ;; esac
	_digjson=null; [ -n "$_digest" ] && _digjson="\"$_digest\""

	if [ "$_applicable" != "true" ]; then
		# A non-applicable claim is NOT self-authenticating. Independently prove it:
		#   (a) core engine scans (secrets/SAST/filesystem/workflow) are ALWAYS required
		#       unless the policy explicitly disables the scanner;
		#   (b) recompute applicability from the workspace — a tree that plainly triggers
		#       the scanner class contradicts the claim;
		#   (c) require a complete, policy-approved, commit-bound, digest-backed detector
		#       proof (name/version/result/inspected paths/source commit/reason/digest).
		# Each failure is a distinct blocking violation; the run fails closed.
		NONAPP_COUNT=$((NONAPP_COUNT + 1))
		_proof=$(printf '%s' "$_rec" | jq -c '.non_applicability // empty' 2>/dev/null || printf '')
		_na_detector=$(printf '%s' "$_proof" | jq -r '.detector // ""' 2>/dev/null || printf '')
		_na_ver=$(printf '%s' "$_proof" | jq -r '.detector_version // ""' 2>/dev/null || printf '')
		_na_reason=$(printf '%s' "$_proof" | jq -r '.reason // ""' 2>/dev/null || printf '')
		_na_commit=$(printf '%s' "$_proof" | jq -r '.source_commit // ""' 2>/dev/null || printf '')
		_na_digest=$(printf '%s' "$_proof" | jq -r '.detector_report_digest // ""' 2>/dev/null || printf '')

		# (a) always-required engine scan.
		if contains "$POL_APP_ALWAYS" "$_cat" && ! contains "$POL_APP_DISABLED" "$_name"; then
			add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_ALWAYS_REQUIRED"
		fi

		# (b) independent filesystem recompute.
		_recomp=$(recompute_applicable "$_appwhen")
		if [ "$_recomp" = "yes" ]; then
			add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_RECOMPUTED"
		fi

		# (c) complete + approved + commit-bound + digest-backed proof.
		if [ "$POL_APP_REQUIRE_PROOF" = "true" ]; then
			if [ -z "$_proof" ] || ! sp_nonapplicability_complete "$_proof"; then
				add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_UNPROVEN"
			else
				if [ -z "$_na_reason" ] || ! contains "$POL_APP_REASONS" "$_na_reason"; then
					add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_REASON_UNAPPROVED"
				fi
				if ! sp_digest_ok "$_na_digest"; then
					add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_NO_DIGEST"
				fi
				if [ -z "$EXPECTED_COMMIT" ] || [ "$_na_commit" != "$EXPECTED_COMMIT" ]; then
					add_violation "$_cat" "-" "$_name" "NON_APPLICABLE_COMMIT_MISMATCH"
				fi
			fi
		fi

		# Use --arg (not string interpolation) so a hostile detector/reason value cannot
		# inject JSON; empty strings normalize to null inside jq.
		jq -n --arg n "$_name" --arg c "$_cat" --argjson v "$_verjson" \
			--arg det "$_na_detector" --arg dver "$_na_ver" --arg rsn "$_na_reason" \
			--arg sc "$_na_commit" --arg dg "$_na_digest" --arg rc "$_recomp" \
			'def nz: if . == "" then null else . end;
			 {name:$n, category:$c, applicable:false, executed:false, status:"not-applicable", version:$v, database_age_days:null, fresh:true, targets_scanned:null, raw_report_digest:null,
			  non_applicability:{detector:($det|nz), detector_version:($dver|nz), reason:($rsn|nz), source_commit:($sc|nz), detector_report_digest:($dg|nz), recomputed:$rc}}' >> "$SCAN_NDJSON"
		_i=$((_i + 1)); continue
	fi

	# Applicable: it MUST have run cleanly.
	if [ "$_status" = "error" ]; then
		jq -n --arg n "$_name" --arg c "$_cat" --argjson v "$_verjson" \
			'{name:$n, category:$c, applicable:true, executed:false, status:"error", version:$v, database_age_days:null, fresh:false, targets_scanned:null, raw_report_digest:null}' >> "$SCAN_NDJSON"
		add_violation "$_cat" "-" "$_name" "SCANNER_FAILURE"
		_i=$((_i + 1)); continue
	fi

	# Success — evaluate targets, digest, freshness. Determine a terminal status token.
	_out_status="success"; _fresh=true
	if [ "$_tgtjson" = "null" ] || [ "$_tgtjson" = "0" ]; then
		_out_status="zero-targets"
		add_violation "$_cat" "-" "$_name" "SCANNER_ZERO_TARGETS"
	fi
	if ! sp_digest_ok "$_digest"; then
		[ "$_out_status" = "success" ] && _out_status="no-digest"
		add_violation "$_cat" "-" "$_name" "SCANNER_NO_DIGEST"
	fi
	if [ "$_cap" != "null" ] && [ -n "$_cap" ]; then
		if [ "$_agejson" = "null" ] || [ "$_agejson" -gt "$_cap" ]; then
			_fresh=false
			[ "$_out_status" = "success" ] && _out_status="stale"
			add_violation "$_cat" "-" "$_name" "SCANNER_DB_STALE"
		fi
	fi

	# Applicable + not a hard error => it executed (executed:true); the terminal status
	# token records whether the run was clean or produced a blocking execution problem.
	jq -n --arg n "$_name" --arg c "$_cat" --arg st "$_out_status" --argjson v "$_verjson" \
		--argjson age "$_agejson" --argjson tgt "$_tgtjson" --argjson dg "$_digjson" --argjson fr "$_fresh" \
		'{name:$n, category:$c, applicable:true, executed:true, status:$st, version:$v, database_age_days:$age, fresh:$fr, targets_scanned:$tgt, raw_report_digest:$dg}' >> "$SCAN_NDJSON"
	_i=$((_i + 1))
done

# A summary that marks EVERY required scanner non-applicable proves nothing — it is the
# spoof the applicability gate exists to catch. Reject it outright (fail closed).
if [ "$POL_APP_REJECT_ALL" = "true" ] && [ "$_reqcount" -gt 0 ] && [ "$NONAPP_COUNT" -ge "$_reqcount" ]; then
	add_violation "applicability" "-" "-" "ALL_SCANNERS_NON_APPLICABLE"
fi

# --- findings evaluation (severity / category / waiver) ----------------------
_fcount=$(jq -r '.findings | length' "$SUMMARY")
FINDINGS_TOTAL=$_fcount
FINDINGS_BLOCKING=0
FINDINGS_WAIVED=0
_j=0
while [ "$_j" -lt "$_fcount" ]; do
	_fid=$(jq -r --argjson i "$_j" '.findings[$i].id' "$SUMMARY")
	_fscan=$(jq -r --argjson i "$_j" '.findings[$i].scanner' "$SUMMARY")
	_fcat=$(jq -r --argjson i "$_j" '.findings[$i].category' "$SUMMARY")
	_fsev=$(jq -r --argjson i "$_j" '.findings[$i].severity' "$SUMMARY")

	# Candidate for the gate if the severity is blocking OR the category is never-waivable
	# (e.g. leaked secrets block at any severity).
	_candidate=0
	contains "$POL_BLOCKING" "$_fsev" && _candidate=1
	contains "$POL_NEVER_CAT" "$_fcat" && _candidate=1
	if [ "$_candidate" -eq 0 ]; then _j=$((_j + 1)); continue; fi

	# Never-waivable category (secrets): always blocking, ignore any waiver.
	if contains "$POL_NEVER_CAT" "$_fcat"; then
		FINDINGS_BLOCKING=$((FINDINGS_BLOCKING + 1))
		add_violation "$_fcat" "$_fsev" "$_fscan" "SECRET_LEAK_BLOCKING"
		_j=$((_j + 1)); continue
	fi

	# Look for a matching, valid, unexpired, approved narrow waiver.
	_match=$(jq -r --arg s "$_fscan" --arg c "$_fcat" --arg id "$_fid" --arg today "$TODAY" '
		[ .risks[]
		  | select(.status == "approved")
		  | select((.scope // "finding") == "finding")
		  | select(.scanner == $s and .category == $c and .finding_id == $id)
		  | select(.expires_at >= $today)
		] | if length == 0 then "none"
		    elif any(.[]; (.emergency // false) == true) then "emergency"
		    else "normal" end' "$ACCEPTED_RISKS" 2>/dev/null || printf 'none')
	[ -n "$_match" ] || _match=none

	if [ "$_match" = "emergency" ]; then
		# Emergency path: may accept a finding whose severity is emergency-waivable.
		if contains "$POL_EMERG_WAIVABLE" "$_fsev"; then
			FINDINGS_WAIVED=$((FINDINGS_WAIVED + 1)); EMERGENCY_USED=1
			jq -n --arg id "$_fid" --arg s "$_fscan" --arg c "$_fcat" --arg sev "$_fsev" \
				'{finding_id:$id, scanner:$s, category:$c, severity:$sev, mode:"emergency"}' >> "$APPLIED_NDJSON"
			_j=$((_j + 1)); continue
		fi
		FINDINGS_BLOCKING=$((FINDINGS_BLOCKING + 1))
		add_violation "$_fcat" "$_fsev" "$_fscan" "BLOCKING_FINDING"
		_j=$((_j + 1)); continue
	fi
	if [ "$_match" = "normal" ]; then
		if contains "$POL_WAIVABLE" "$_fsev"; then
			FINDINGS_WAIVED=$((FINDINGS_WAIVED + 1))
			jq -n --arg id "$_fid" --arg s "$_fscan" --arg c "$_fcat" --arg sev "$_fsev" \
				'{finding_id:$id, scanner:$s, category:$c, severity:$sev, mode:"accepted-risk"}' >> "$APPLIED_NDJSON"
			_j=$((_j + 1)); continue
		fi
		# Severity not waivable via the normal path (e.g. critical) — record the rejected
		# suppression and keep the finding blocking.
		jq -n --arg id "$_fid" --arg s "$_fscan" --arg c "$_fcat" --arg sev "$_fsev" \
			'{finding_id:$id, scanner:$s, category:$c, severity:$sev, reason:"severity-not-waivable"}' >> "$REJECTED_NDJSON"
	fi

	FINDINGS_BLOCKING=$((FINDINGS_BLOCKING + 1))
	add_violation "$_fcat" "$_fsev" "$_fscan" "BLOCKING_FINDING"
	_j=$((_j + 1))
done

# --- coverage + regression baseline ------------------------------------------
COV_EXPECTED=$(jq -r '.targets.expected' "$SUMMARY")
COV_SCANNED=$(jq -r '.targets.scanned' "$SUMMARY")
COV_RATIO=$(jq -r 'if .targets.coverage_ratio != null then .targets.coverage_ratio elif (.targets.expected // 0) > 0 then (.targets.scanned / .targets.expected) else 1 end' "$SUMMARY")

BASE_PRESENT=false
COV_REGRESSION=false
UNEXPLAINED_DROP=false
BASE_COV_RATIO=null
BASE_FIND_TOTAL=null

# Absolute coverage floor (independent of a baseline). A ratio below the policy floor
# is a coverage failure, fail closed.
if jq -n --argjson r "$COV_RATIO" --argjson m "$POL_MIN_COV" -e '$r < $m' >/dev/null 2>&1; then
	add_violation "coverage" "-" "-" "COVERAGE_FLOOR"
fi

if [ -n "$BASELINE" ]; then
	[ -f "$BASELINE" ] && [ -s "$BASELINE" ] || die_cfg "enforce-security-policy: baseline missing/empty: $BASELINE"
	jq -e . "$BASELINE" >/dev/null 2>&1 || die_cfg "enforce-security-policy: baseline is not valid JSON: $BASELINE"
	jq -e '(.targets.scanned | type == "number") and (.findings.total | type == "number")' "$BASELINE" >/dev/null 2>&1 \
		|| die_cfg "enforce-security-policy: baseline lacks targets.scanned / findings.total: $BASELINE"
	BASE_PRESENT=true
	_bscanned=$(jq -r '.targets.scanned' "$BASELINE")
	BASE_FIND_TOTAL=$(jq -r '.findings.total' "$BASELINE")
	BASE_COV_RATIO=$(jq -r 'if .targets.coverage_ratio != null then .targets.coverage_ratio elif (.targets.expected // 0) > 0 then (.targets.scanned / .targets.expected) else 1 end' "$BASELINE")
	if [ "$POL_REG_ENABLED" = "true" ]; then
		# Target-coverage reduction: fewer targets scanned than the accepted baseline.
		if [ "$COV_SCANNED" -lt "$_bscanned" ]; then
			COV_REGRESSION=true
			add_violation "regression" "-" "-" "SECURITY_REGRESSION"
		fi
		# Unexplained finding drop: fewer findings AND fewer targets scanned (i.e. the drop
		# is explained by reduced coverage, not by fixes).
		if [ "$FINDINGS_TOTAL" -lt "$BASE_FIND_TOTAL" ] && [ "$COV_SCANNED" -lt "$_bscanned" ]; then
			UNEXPLAINED_DROP=true
		fi
	fi
fi

# --- decision ----------------------------------------------------------------
# Count records robustly (slurp all JSON values; empty file -> 0), never by line count.
VIOL_COUNT=$(jq -s 'length' "$VIOL_NDJSON" 2>/dev/null || printf '0')
case "$VIOL_COUNT" in ''|*[!0-9]*) VIOL_COUNT=0 ;; esac

if [ "$VIOL_COUNT" -gt 0 ]; then
	DECISION="rejected"; EXITC=1
elif [ "$EMERGENCY_USED" -eq 1 ]; then
	DECISION="accepted-emergency"; EXITC=0
else
	DECISION="accepted"; EXITC=0
fi

# --- assemble + validate the acceptance report -------------------------------
ensure_dir "$(dirname -- "$OUTPUT")"
_tmp="$OUTPUT.tmp.$$"
jq -n \
	--arg gen "$(timestamp_utc)" \
	--arg pv "$POLICY_VERSION" \
	--arg dec "$DECISION" \
	--argjson ec "$EXITC" \
	--slurpfile scanners "$SCAN_NDJSON" \
	--slurpfile violations "$VIOL_NDJSON" \
	--slurpfile applied "$APPLIED_NDJSON" \
	--slurpfile rejected "$REJECTED_NDJSON" \
	--argjson cexp "$COV_EXPECTED" \
	--argjson cscan "$COV_SCANNED" \
	--argjson cratio "$COV_RATIO" \
	--argjson ftotal "$FINDINGS_TOTAL" \
	--argjson fblock "$FINDINGS_BLOCKING" \
	--argjson fwaive "$FINDINGS_WAIVED" \
	--argjson basepresent "$BASE_PRESENT" \
	--argjson covreg "$COV_REGRESSION" \
	--argjson undrop "$UNEXPLAINED_DROP" \
	--argjson bcov "$BASE_COV_RATIO" \
	--argjson bfind "$BASE_FIND_TOTAL" '
	{
		schema_version: "1",
		generated_at: $gen,
		policy_version: $pv,
		decision: $dec,
		exit_code: $ec,
		scanners: $scanners,
		coverage: { expected: $cexp, scanned: $cscan, ratio: $cratio },
		findings: { total: $ftotal, blocking: $fblock, waived: $fwaive },
		waivers: { applied: $applied, rejected: $rejected },
		regression: {
			baseline_present: $basepresent,
			coverage_regression: $covreg,
			unexplained_finding_drop: $undrop,
			baseline_coverage_ratio: $bcov,
			baseline_finding_total: $bfind
		},
		violations: $violations
	}' > "$_tmp" || die_cfg "enforce-security-policy: could not assemble acceptance report"

sp_validate_acceptance "$_tmp" || { rm -f "$_tmp"; die_cfg "enforce-security-policy: produced a non-conforming acceptance report"; }
mv -- "$_tmp" "$OUTPUT" || die_cfg "enforce-security-policy: cannot write $OUTPUT"

log_info "security acceptance: decision=$DECISION violations=$VIOL_COUNT report=$OUTPUT"
printf 'security-acceptance: decision=%s exit=%s findings(total=%s blocking=%s waived=%s) coverage=%s/%s\n' \
	"$DECISION" "$EXITC" "$FINDINGS_TOTAL" "$FINDINGS_BLOCKING" "$FINDINGS_WAIVED" "$COV_SCANNED" "$COV_EXPECTED"
exit "$EXITC"
