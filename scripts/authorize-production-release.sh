#!/bin/sh
# Sentinel Shield — production release, rollback, and support authorization (MACRO-TASK 4).
#
# One fail-closed tool for the production-release lifecycle. It NEVER creates a tag or a
# GitHub Release and NEVER deletes or moves one: it VERIFIES a release candidate, records a
# governed AUTHORIZATION, prints the exact operator commands, and (for rollback) produces a
# SUPERSEDING-release advisory. Publishing remains a deliberate, manual, out-of-band step
# that requires both an explicit destructive flag AND a valid authorization token per repo
# policy — this tool refuses to perform it.
#
# Release stages: beta | rc | ga. For an engine-only GA the candidate must independently prove
# (verify-candidate re-derives EVERY one from the referenced artifacts, fail closed):
#   exact default-branch source commit; required CI green (not PR-only); artifact content +
#   digest reproducibility vs the manifest; manifest self-consistency; production security
#   acceptance (no unresolved critical/high, no expired waivers); compatibility matrix;
#   adopter scorecard; upgrade validation; rollback validation; published limitations; and
#   support + incident-response readiness. framework-validated / full-platform GA is BLOCKED —
#   the engine cannot prove framework live-validation.
#
# Modes:
#   prepare            Emit a release-candidate descriptor (schemas/release-candidate.schema.json).
#   verify-candidate   Re-verify every gate over a candidate descriptor. READY only if all pass.
#   authorize          verify-candidate + a governed authorization record -> emit a decision.
#                      Never publishes.
#   print-tag-commands Print the exact (manual) tag/release commands for an AUTHORIZED candidate.
#   declare-superseded Emit a superseding-release advisory that marks affected versions.
#   rollback-advisory  Emit a rollback advisory recommending a known-good prior version.
#
# Exit: 0 ok/READY/authorized; 1 NOT-READY / rejected / BLOCKED; 2 invalid invocation /
#       malformed input / refused destructive op; 3 required tool unavailable; 4 timeout.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$SCRIPT_DIR/lib/release-authz.sh"

VERIFY_MANIFEST="$SCRIPT_DIR/verify-release-manifest.sh"
VALIDATE_EVIDENCE="$SCRIPT_DIR/validate-release-evidence.sh"
# Canonical COMPLETE required release-workflow set (config/*.json). Overridable ONLY for
# deterministic tests via SENTINEL_SHIELD_RELEASE_WORKFLOW_POLICY; production uses the shipped
# policy. The evidence gate loads the set from here — never from a hardcoded ad hoc list.
REQUIRED_WORKFLOWS_POLICY="${SENTINEL_SHIELD_RELEASE_WORKFLOW_POLICY:-$SCRIPT_DIR/../config/release-required-workflows.json}"
BOUND_SECS="${RA_BOUND_SECS:-120}"

usage() {
	cat <<'EOF'
Usage:
  authorize-production-release.sh prepare --version <v> --stage <beta|rc|ga> --scope <engine-only|framework-validated|full-platform> \
      --source-commit <40hex> --tag <name> [--base-dir <dir>] \
      [--evidence <f>] [--manifest <f>] [--artifacts <f>] [--security-acceptance <f>] \
      [--compat-matrix <f>] [--adopter-scorecard <f>] [--upgrade-validation <f>] [--rollback-validation <f>] \
      [--waivers <f>] [--limitations <doc>] [--support-policy <doc>] [--incident-response <doc>] [--output <f>]

  authorize-production-release.sh verify-candidate --candidate <descriptor> [--base-dir <dir>] [--source-commit <40hex>]

  authorize-production-release.sh authorize --candidate <descriptor> --authorization <record> [--base-dir <dir>] \
      [--confirm-token <t>] [--output <decision>]

  authorize-production-release.sh print-tag-commands --candidate <descriptor> --authorization <record> [--base-dir <dir>] [--remote <name>]

  authorize-production-release.sh declare-superseded --advisory-id <id> --superseded-version <v> --superseding-version <v> \
      [--superseded-tag <t>] [--superseding-tag <t>] --reason <text> [--guidance <line> ...] [--reference <url> ...] [--output <f>]

  authorize-production-release.sh rollback-advisory --advisory-id <id> --affected-version <v> [--affected-version <v> ...] \
      --rollback-to <v> --reason <text> [--guidance <line> ...] [--reference <url> ...] [--output <f>]

A Sentinel Shield rollback NEVER deletes or moves a released tag: it publishes a SUPERSEDING fixed release.
EOF
}

MODE="${1:-}"
[ -n "$MODE" ] || { log_error "a mode is required"; usage >&2; exit 2; }
case "$MODE" in
	prepare | verify-candidate | authorize | print-tag-commands | declare-superseded | rollback-advisory) ;;
	-h | --help) usage; exit 0 ;;
	*) log_error "unknown mode: $MODE"; usage >&2; exit 2 ;;
esac
shift

# Refuse any destructive tag/release operation up-front, in EVERY mode (tests 14 & 15).
ra_guard_destructive "$@" || exit 2

command_exists jq || { log_error "jq is required but was not found"; exit 3; }

# --- flag parsing (union across modes) ---------------------------------------
VERSION=""; STAGE=""; SCOPE=""; SOURCE_COMMIT=""; TAG=""; BASE_DIR=""
CANDIDATE=""; AUTHORIZATION=""; CONFIRM_TOKEN=""; OUTPUT=""; REMOTE="origin"
F_EVIDENCE=""; F_MANIFEST=""; F_ARTIFACTS=""; F_SECACC=""; F_COMPAT=""; F_ADOPTER=""
F_UPGRADE=""; F_ROLLBACK=""; F_WAIVERS=""; D_LIMITS=""; D_SUPPORT=""; D_INCIDENT=""
ADVISORY_ID=""; SUPERSEDED_VER=""; SUPERSEDED_TAG=""; SUPERSEDING_VER=""; SUPERSEDING_TAG=""
ROLLBACK_TO=""; REASON=""; GUIDANCE=""; REFERENCES=""; AFFECTED=""
while [ $# -gt 0 ]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--stage) STAGE="${2:?}"; shift 2 ;;
		--scope) SCOPE="${2:?}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?}"; shift 2 ;;
		--tag) TAG="${2:?}"; shift 2 ;;
		--base-dir) BASE_DIR="${2:?}"; shift 2 ;;
		--candidate) CANDIDATE="${2:?}"; shift 2 ;;
		--authorization) AUTHORIZATION="${2:?}"; shift 2 ;;
		--confirm-token) CONFIRM_TOKEN="${2:?}"; shift 2 ;;
		--output) OUTPUT="${2:?}"; shift 2 ;;
		--remote) REMOTE="${2:?}"; shift 2 ;;
		--evidence) F_EVIDENCE="${2:?}"; shift 2 ;;
		--manifest) F_MANIFEST="${2:?}"; shift 2 ;;
		--artifacts) F_ARTIFACTS="${2:?}"; shift 2 ;;
		--security-acceptance) F_SECACC="${2:?}"; shift 2 ;;
		--compat-matrix) F_COMPAT="${2:?}"; shift 2 ;;
		--adopter-scorecard) F_ADOPTER="${2:?}"; shift 2 ;;
		--upgrade-validation) F_UPGRADE="${2:?}"; shift 2 ;;
		--rollback-validation) F_ROLLBACK="${2:?}"; shift 2 ;;
		--waivers) F_WAIVERS="${2:?}"; shift 2 ;;
		--limitations) D_LIMITS="${2:?}"; shift 2 ;;
		--support-policy) D_SUPPORT="${2:?}"; shift 2 ;;
		--incident-response) D_INCIDENT="${2:?}"; shift 2 ;;
		--advisory-id) ADVISORY_ID="${2:?}"; shift 2 ;;
		--superseded-version) SUPERSEDED_VER="${2:?}"; shift 2 ;;
		--superseded-tag) SUPERSEDED_TAG="${2:?}"; shift 2 ;;
		--superseding-version) SUPERSEDING_VER="${2:?}"; shift 2 ;;
		--superseding-tag) SUPERSEDING_TAG="${2:?}"; shift 2 ;;
		--affected-version) AFFECTED="$AFFECTED${AFFECTED:+
}${2:?}"; shift 2 ;;
		--rollback-to) ROLLBACK_TO="${2:?}"; shift 2 ;;
		--reason) REASON="${2:?}"; shift 2 ;;
		--guidance) GUIDANCE="$GUIDANCE${GUIDANCE:+
}${2:?}"; shift 2 ;;
		--reference) REFERENCES="$REFERENCES${REFERENCES:+
}${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

# resolve_path <maybe-relative> — echo an absolute path resolved against BASE_DIR.
resolve_path() {
	case "$1" in
		/*) printf '%s' "$1" ;;
		*) printf '%s/%s' "${BASE_DIR:-.}" "$1" ;;
	esac
}

# ============================================================================
# mode: prepare — emit a candidate descriptor (read-only)
# ============================================================================
if [ "$MODE" = prepare ]; then
	[ -n "$VERSION" ] || { log_error "prepare: --version is required"; exit 2; }
	case "$STAGE" in beta | rc | ga) ;; *) log_error "prepare: --stage must be beta|rc|ga"; exit 2 ;; esac
	case "$SCOPE" in engine-only | framework-validated | full-platform) ;; *) log_error "prepare: --scope must be engine-only|framework-validated|full-platform"; exit 2 ;; esac
	ra_is_hex40 "$SOURCE_COMMIT" || { log_error "prepare: --source-commit must be a 40-hex SHA"; exit 2; }
	SOURCE_COMMIT=$(printf '%s' "$SOURCE_COMMIT" | tr 'A-F' 'a-f')
	[ -n "$TAG" ] || { log_error "prepare: --tag is required"; exit 2; }
	# Build artifacts{} / docs{} objects from whatever paths were supplied (relative, as recorded).
	ARTS=$(jq -n \
		--arg evidence "$F_EVIDENCE" --arg manifest "$F_MANIFEST" --arg artv "$F_ARTIFACTS" \
		--arg secacc "$F_SECACC" --arg compat "$F_COMPAT" --arg adopter "$F_ADOPTER" \
		--arg upg "$F_UPGRADE" --arg rbk "$F_ROLLBACK" --arg waivers "$F_WAIVERS" '
		{ evidence:$evidence, manifest:$manifest, artifact_verification:$artv,
		  security_acceptance:$secacc, compatibility_matrix:$compat, adopter_scorecard:$adopter,
		  upgrade_validation:$upg, rollback_validation:$rbk, waivers:$waivers }
		| with_entries(select(.value | length > 0))')
	DOCS=$(jq -n --arg lim "$D_LIMITS" --arg sup "$D_SUPPORT" --arg inc "$D_INCIDENT" '
		{ limitations:$lim, support_policy:$sup, incident_response:$inc } | with_entries(select(.value | length > 0))')
	DESC=$(jq -n \
		--arg v "$VERSION" --arg s "$STAGE" --arg sc "$SCOPE" --arg c "$SOURCE_COMMIT" --arg tag "$TAG" \
		--argjson arts "$ARTS" --argjson docs "$DOCS" '
		{ schema_version:"1", version:$v, stage:$s, release_scope:$sc, source_commit:$c, tag:$tag, artifacts:$arts }
		+ (if ($docs | length) > 0 then { docs:$docs } else {} end)')
	# Self-check the emitted descriptor before returning it.
	_tmp=$(mktemp 2>/dev/null || mktemp -t sscand); printf '%s\n' "$DESC" > "$_tmp"
	ra_validate_candidate "$_tmp" || { rm -f "$_tmp"; log_error "prepare: emitted descriptor failed validation (fail closed)"; exit 2; }
	rm -f "$_tmp"
	if [ -n "$OUTPUT" ]; then printf '%s\n' "$DESC" > "$OUTPUT"; log_info "prepare: wrote candidate descriptor to $OUTPUT"; else printf '%s\n' "$DESC"; fi
	exit 0
fi

# ============================================================================
# shared: verify-candidate implementation (used by verify-candidate + authorize)
# ============================================================================
# Populated by verify_candidate_impl for downstream modes.
CAND_VERSION=""; CAND_STAGE=""; CAND_SCOPE=""; CAND_SOURCE=""; CAND_TAG=""; CAND_MANIFEST_HASH=""

# verify_candidate_impl — evaluate every gate. Echoes PASS/FAIL lines; sets the CAND_* vars.
# Returns 0 READY, 1 NOT-READY/BLOCKED, 2 malformed/invalid, 4 timeout.
verify_candidate_impl() {
	[ -n "$CANDIDATE" ] || { log_error "verify-candidate: --candidate <descriptor> is required"; return 2; }
	[ -f "$CANDIDATE" ] || { log_error "verify-candidate: descriptor not found: $CANDIDATE"; return 2; }
	ra_validate_candidate "$CANDIDATE" || return 2
	[ -n "$BASE_DIR" ] || BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$CANDIDATE")" && pwd)

	CAND_VERSION=$(jq -r '.version' "$CANDIDATE")
	CAND_STAGE=$(jq -r '.stage' "$CANDIDATE")
	CAND_SCOPE=$(jq -r '.release_scope' "$CANDIDATE")
	CAND_SOURCE=$(jq -r '.source_commit' "$CANDIDATE")
	CAND_TAG=$(jq -r '.tag' "$CANDIDATE")
	# --source-commit is an EXPECTED-identity assertion, never an override: if the caller
	# supplies one it must equal the descriptor's .source_commit, else fail closed (a
	# descriptor for commit A must never be verified/authorized as commit B).
	if [ -n "$SOURCE_COMMIT" ]; then
		_expect_src=$(printf '%s' "$SOURCE_COMMIT" | tr 'A-F' 'a-f')
		_desc_src=$(printf '%s' "$CAND_SOURCE" | tr 'A-F' 'a-f')
		if [ "$_expect_src" != "$_desc_src" ]; then
			log_error "verify-candidate: --source-commit ($_expect_src) does not match descriptor .source_commit ($_desc_src) — refusing (fail closed)"
			return 2
		fi
		CAND_SOURCE="$_desc_src"
	fi

	_ev=$(resolve_path "$(jq -r '.artifacts.evidence // ""' "$CANDIDATE")")
	_mf=$(resolve_path "$(jq -r '.artifacts.manifest // ""' "$CANDIDATE")")
	_av=$(resolve_path "$(jq -r '.artifacts.artifact_verification // ""' "$CANDIDATE")")
	_sa=$(resolve_path "$(jq -r '.artifacts.security_acceptance // ""' "$CANDIDATE")")
	_cm=$(resolve_path "$(jq -r '.artifacts.compatibility_matrix // ""' "$CANDIDATE")")
	_as=$(resolve_path "$(jq -r '.artifacts.adopter_scorecard // ""' "$CANDIDATE")")
	_up=$(resolve_path "$(jq -r '.artifacts.upgrade_validation // ""' "$CANDIDATE")")
	_rb=$(resolve_path "$(jq -r '.artifacts.rollback_validation // ""' "$CANDIDATE")")
	_wv_rel=$(jq -r '.artifacts.waivers // ""' "$CANDIDATE"); _wv=""; [ -n "$_wv_rel" ] && _wv=$(resolve_path "$_wv_rel")
	_d_lim=$(jq -r '.docs.limitations // ""' "$CANDIDATE")
	_d_sup=$(jq -r '.docs.support_policy // ""' "$CANDIDATE")
	_d_inc=$(jq -r '.docs.incident_response // ""' "$CANDIDATE")

	_fails=0
	_pass() { printf '  PASS  %s\n' "$*"; }
	_fail() { _fails=$((_fails + 1)); printf '  FAIL  %s\n' "$*"; }

	printf 'Sentinel Shield — release candidate verification\n'
	printf 'Version: %s   Stage: %s   Scope: %s\n' "$CAND_VERSION" "$CAND_STAGE" "$CAND_SCOPE"
	printf 'Source:  %s   Tag: %s\n\n' "$CAND_SOURCE" "$CAND_TAG"

	# GATE 0 — GA scope: only engine-only is authorizable to GA. Framework live-validation
	# is out of scope and must never be claimed, so framework-validated/full-platform GA is BLOCKED.
	if [ "$CAND_STAGE" = ga ] && [ "$CAND_SCOPE" != engine-only ]; then
		_fail "GA scope: '$CAND_SCOPE' GA is BLOCKED — engine-only is the only engine-authorizable GA scope (framework live-validation is out of scope)"
		printf '\nrelease-candidate: %s stage=%s — BLOCKED\n' "$CAND_VERSION" "$CAND_STAGE"
		return 1
	fi
	_pass "scope '$CAND_SCOPE' is eligible for stage '$CAND_STAGE'"

	# GATE 1 — exact source commit + the COMPLETE canonical required release-workflow set
	# (each required workflow proven by a UNIQUE authoritative default-branch run; not PR-only,
	# not "at least one run"). The required set is loaded from the canonical policy file.
	if [ -z "$_ev" ] || [ ! -f "$_ev" ]; then
		_fail "evidence: missing release-evidence artifact (required)"
	else
		_rc=0; ra_check_evidence_source "$_ev" "$CAND_SOURCE" "$REQUIRED_WORKFLOWS_POLICY" "$VALIDATE_EVIDENCE" || _rc=$?
		case "$_rc" in
			0) _pass "source commit passed the COMPLETE required release-workflow set on the default branch (unique authoritative runs)" ;;
			2) _fail "evidence: malformed/unverifiable release-evidence or required-workflow policy (fail closed)" ;;
			*) _fail "evidence: required release-workflow set INCOMPLETE / source-commit CI REJECTED (see reason above)" ;;
		esac
	fi

	# GATE 2 — manifest self-consistency (reproducibility hash recomputed).
	if [ -z "$_mf" ] || [ ! -f "$_mf" ]; then
		_fail "manifest: missing release manifest (required)"
	elif [ ! -x "$VERIFY_MANIFEST" ] && [ ! -f "$VERIFY_MANIFEST" ]; then
		_fail "manifest: verifier not found ($VERIFY_MANIFEST) (fail closed)"
	else
		_rc=0; ra_bounded "$BOUND_SECS" sh "$VERIFY_MANIFEST" --manifest "$_mf" >/dev/null 2>&1 || _rc=$?
		if [ "$_rc" = 124 ]; then _fail "manifest: verification TIMED OUT"; RA_TIMEOUT=1
		elif [ "$_rc" = 0 ]; then
			_pass "manifest is self-consistent (reproducibility hash verified)"
			CAND_MANIFEST_HASH=$(jq -r '.reproducibility.hash // ""' "$_mf")
		else _fail "manifest: self-consistency/reconstruction FAILED (verifier exit $_rc)"; fi
	fi

	# GATE 3 — artifact content verification green + digest reproducibility vs manifest.
	if [ -z "$_av" ] || [ ! -f "$_av" ]; then
		_fail "artifacts: missing artifact-verification report (required)"
	else
		if ra_gate_ok "$_av"; then _pass "artifact content verification is green (no rejected artifacts)"
		else _fail "artifacts: verification report is not green"; fi
		if [ -n "$_mf" ] && [ -f "$_mf" ]; then
			_rc=0; ra_artifacts_match_manifest "$_av" "$_mf" "$REQUIRED_WORKFLOWS_POLICY" || _rc=$?
			if [ "$_rc" = 0 ]; then _pass "artifact digests reproduce the manifest fingerprint"
			else _fail "artifacts: digest reproducibility check REJECTED (mismatch/malformed)"; fi
		fi
	fi

	# GATE 4 — production security acceptance (covers no unresolved critical/high defects).
	if [ -z "$_sa" ] || [ ! -f "$_sa" ]; then
		_fail "security: missing production security-acceptance report (required)"
	elif ra_security_acceptance_ok "$_sa"; then _pass "production security acceptance is green (no blocking findings/violations)"
	else _fail "security: acceptance report is not green (blocking findings/violations, or not accepted)"; fi

	# GATE 5 — no expired waivers.
	_rc=0; ra_no_expired_waivers "$_wv" || _rc=$?
	case "$_rc" in
		0) _pass "no expired waivers" ;;
		2) _fail "waivers: malformed accepted-risks file (fail closed)" ;;
		*) _fail "waivers: an approved waiver has EXPIRED (see reason above)" ;;
	esac

	# GATE 6 — compatibility matrix.
	if [ -z "$_cm" ] || [ ! -f "$_cm" ]; then _fail "compat: missing compatibility-matrix report (required)"
	elif ra_gate_ok "$_cm"; then _pass "compatibility matrix is complete and green"
	else _fail "compat: matrix is incomplete or not green"; fi

	# GATE 7 — adopter scorecard.
	if [ -z "$_as" ] || [ ! -f "$_as" ]; then _fail "adopter: missing adopter scorecard (required)"
	elif ra_gate_ok "$_as"; then _pass "adopter scorecard passed"
	else _fail "adopter: scorecard did not pass"; fi

	# GATE 8 — upgrade validation.
	if [ -z "$_up" ] || [ ! -f "$_up" ]; then _fail "upgrade: missing upgrade-validation report (required)"
	elif ra_gate_ok "$_up"; then _pass "upgrade validation passed"
	else _fail "upgrade: validation did not pass"; fi

	# GATE 9 — rollback validation.
	if [ -z "$_rb" ] || [ ! -f "$_rb" ]; then _fail "rollback: missing rollback-validation report (required)"
	elif ra_gate_ok "$_rb"; then _pass "rollback validation passed"
	else _fail "rollback: validation did not pass"; fi

	# GATE 10 — published limitations + support & incident-response readiness.
	_doc_ok() { _dp=$(resolve_path "$1"); [ -n "$1" ] && [ -s "$_dp" ]; }
	if _doc_ok "$_d_lim"; then _pass "published limitations document present"; else _fail "docs: published limitations document missing/empty (required)"; fi
	if _doc_ok "$_d_sup"; then _pass "support-policy document present"; else _fail "docs: support-policy document missing/empty (required)"; fi
	if _doc_ok "$_d_inc"; then _pass "incident-response document present"; else _fail "docs: incident-response document missing/empty (required)"; fi

	printf '\n----\n'
	if [ "${RA_TIMEOUT}" = 1 ]; then
		printf 'release-candidate: %s stage=%s — TIMEOUT during verification (fail closed)\n' "$CAND_VERSION" "$CAND_STAGE"
		return 4
	fi
	if [ "$_fails" -eq 0 ]; then
		printf 'release-candidate: %s stage=%s scope=%s — READY (all gates met)\n' "$CAND_VERSION" "$CAND_STAGE" "$CAND_SCOPE"
		return 0
	fi
	printf 'release-candidate: %s stage=%s — NOT READY (%d gate(s) failed); fail closed\n' "$CAND_VERSION" "$CAND_STAGE" "$_fails"
	return 1
}

if [ "$MODE" = verify-candidate ]; then
	_rc=0; verify_candidate_impl || _rc=$?
	exit "$_rc"
fi

# ============================================================================
# mode: authorize — verify-candidate + governed authorization -> decision
# ============================================================================
if [ "$MODE" = authorize ]; then
	[ -n "$AUTHORIZATION" ] || { log_error "authorize: --authorization <record> is required"; exit 2; }
	[ -f "$AUTHORIZATION" ] || { log_error "authorize: authorization record not found: $AUTHORIZATION"; exit 2; }
	_rc=0; verify_candidate_impl || _rc=$?
	if [ "$_rc" != 0 ]; then
		log_error "authorize: candidate is not READY (verify-candidate exit $_rc) — refusing to authorize (fail closed)"
		exit "$_rc"
	fi
	[ -n "$CAND_MANIFEST_HASH" ] || { log_error "authorize: candidate manifest hash unresolved — cannot bind authorization (fail closed)"; exit 2; }
	ra_validate_authorization "$AUTHORIZATION" || exit 2
	if ! ra_authorization_binds "$AUTHORIZATION" "$CAND_VERSION" "$CAND_STAGE" "$CAND_SCOPE" "$CAND_SOURCE" "$CAND_TAG" "$CAND_MANIFEST_HASH" "$(ra_today_utc)" "$CONFIRM_TOKEN"; then
		log_error "authorize: authorization record REJECTED (governance) — fail closed"
		exit 1
	fi
	_method=$(jq -r '.authorization.method' "$AUTHORIZATION")
	_appr=$(jq -r '.authorization.approved_by' "$AUTHORIZATION")
	_req=$(jq -r '.authorization.requested_by' "$AUTHORIZATION")
	DECISION=$(jq -n \
		--arg at "$(timestamp_utc)" --arg v "$CAND_VERSION" --arg s "$CAND_STAGE" --arg sc "$CAND_SCOPE" \
		--arg c "$CAND_SOURCE" --arg tag "$CAND_TAG" --arg h "$CAND_MANIFEST_HASH" \
		--arg method "$_method" --arg req "$_req" --arg appr "$_appr" '
		{ schema_version:"1", kind:"release-authorization-decision", generated_at:$at,
		  decision:"authorized", version:$v, stage:$s, release_scope:$sc,
		  source_commit:$c, tag:$tag, candidate_hash:$h,
		  authorized_by:{ method:$method, requested_by:$req, approved_by:$appr },
		  publish:{ performed:false, note:"This tool NEVER creates a tag or GitHub Release. Run print-tag-commands and publish manually with an explicit destructive step." } }')
	if [ -n "$OUTPUT" ]; then printf '%s\n' "$DECISION" > "$OUTPUT"; log_info "authorize: wrote authorization decision to $OUTPUT"; else printf '%s\n' "$DECISION"; fi
	printf '\nAUTHORIZED: %s %s (scope=%s) at source %s — NOT published.\n' "$CAND_VERSION" "$CAND_TAG" "$CAND_SCOPE" "$CAND_SOURCE"
	printf 'Next: authorize-production-release.sh print-tag-commands --candidate %s --authorization %s\n' "$CANDIDATE" "$AUTHORIZATION"
	exit 0
fi

# ============================================================================
# mode: print-tag-commands — print exact manual commands for an AUTHORIZED candidate
# ============================================================================
if [ "$MODE" = print-tag-commands ]; then
	[ -n "$CANDIDATE" ] && [ -f "$CANDIDATE" ] || { log_error "print-tag-commands: --candidate <descriptor> is required"; exit 2; }
	[ -n "$AUTHORIZATION" ] && [ -f "$AUTHORIZATION" ] || { log_error "print-tag-commands: an --authorization <record> is required to print executable publish commands (fail closed)"; exit 2; }
	# FULL governance binding before emitting executable publish commands: re-verify the
	# candidate is READY (this recomputes CAND_MANIFEST_HASH) and require the authorization
	# record to BIND completely (candidate_hash, stage/scope, expiry, self-approval, interactive
	# token) — the SAME gate as `authorize`. A weaker version/tag/source compare could print
	# publish commands for a record `authorize` would reject.
	_rc=0; verify_candidate_impl >/dev/null || _rc=$?
	[ "$_rc" = 0 ] || { log_error "print-tag-commands: candidate is not READY (verify-candidate exit $_rc) — refusing (fail closed)"; exit "$_rc"; }
	[ -n "$CAND_MANIFEST_HASH" ] || { log_error "print-tag-commands: candidate manifest hash unresolved — cannot bind authorization (fail closed)"; exit 2; }
	ra_validate_authorization "$AUTHORIZATION" || exit 2
	if ! ra_authorization_binds "$AUTHORIZATION" "$CAND_VERSION" "$CAND_STAGE" "$CAND_SCOPE" "$CAND_SOURCE" "$CAND_TAG" "$CAND_MANIFEST_HASH" "$(ra_today_utc)" "$CONFIRM_TOKEN"; then
		log_error "print-tag-commands: authorization record REJECTED (governance) — refusing to print publish commands (fail closed)"
		exit 1
	fi
	_v="$CAND_VERSION"; _s="$CAND_STAGE"; _sc="$CAND_SCOPE"; _c="$CAND_SOURCE"; _tag="$CAND_TAG"
	# INJECTION GUARD: _v/_tag/_c are interpolated into copy/paste shell commands below. Refuse
	# anything outside a safe release/tag/commit charset so a crafted descriptor cannot emit a
	# command substitution or break quoting.
	case "$_c" in ''|*[!0-9a-f]*) log_error "print-tag-commands: .source_commit is not a lowercase 40-hex commit — refusing (fail closed)"; exit 2 ;; esac
	[ "${#_c}" -eq 40 ] || { log_error "print-tag-commands: .source_commit is not 40 hex chars — refusing (fail closed)"; exit 2; }
	for _x in "$_v" "$_tag"; do
		case "$_x" in
			''|*[!A-Za-z0-9._+/-]*) log_error "print-tag-commands: refusing unsafe version/tag '$_x' (allowed: A-Za-z0-9 . _ + / -)"; exit 2 ;;
		esac
	done
	cat <<EOF
# Sentinel Shield — MANUAL publish commands for $_v ($_s, scope=$_sc)
# These are the ONLY steps that publish. This tool does NOT run them. Each is destructive and
# requires you to hold the authorization for candidate_hash $(jq -r '.candidate_hash' "$AUTHORIZATION").
# The tag targets the CI-proven source commit; it is a NEW tag — never re-point an existing one.

# 1) Create a SIGNED annotated tag at the exact source commit (fails if the tag already exists):
git tag -s -a "$_tag" -m "Sentinel Shield $_v" "$_c"

# 2) Verify locally before pushing:
git verify-tag "$_tag" && git rev-list -n1 "$_tag"   # must print $_c

# 3) Push the tag (never force):
git push "$REMOTE" "refs/tags/$_tag"

# 4) Create the GitHub Release from the pushed tag (attach the verified artifacts + manifest):
gh release create "$_tag" --verify-tag --title "$_v" --notes-file docs/${_v}-release-notes.md

# After publishing, verify the published tag & release:
#   scripts/verify-published-release.sh verify-tag --repo-root . --tag "$_tag" --commit "$_c"
#   scripts/verify-published-release.sh verify-github-release --tag "$_tag" --expected-commit "$_c" --release-json <gh-release.json>
EOF
	exit 0
fi

# ============================================================================
# advisory helpers (declare-superseded / rollback-advisory)
# ============================================================================
# build_str_array <newline-list> — echo a compact JSON array of the non-empty lines.
build_str_array() {
	if [ -z "$1" ]; then printf '[]'; return; fi
	printf '%s\n' "$1" | jq -R . | jq -sc 'map(select(length > 0))'
}

# validate_advisory <file> — fail-closed jq structural conformance to rollback-advisory.schema.json.
validate_advisory() {
	jq -e '
		(.schema_version == "1")
		and (.advisory_id | type == "string" and (length > 0))
		and (.kind | . == "superseded" or . == "rollback")
		and (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
		and (.affected_versions | type == "array" and (length > 0)
			and all((.version | type == "string" and (length > 0)) and (.status | . == "superseded" or . == "yanked-advisory" or . == "affected")))
		and (.action | . == "publish-superseding-release" or . == "recommend-rollback")
		and (.consumer_guidance | type == "array" and (length > 0))
		and (if .kind == "superseded" then (.superseding_version | type == "string" and (length > 0)) else true end)
		and (if .kind == "rollback" then (.rollback_to | type == "string" and (length > 0)) else true end)
	' "$1" >/dev/null 2>&1
}

if [ "$MODE" = declare-superseded ]; then
	[ -n "$ADVISORY_ID" ] || { log_error "declare-superseded: --advisory-id is required"; exit 2; }
	[ -n "$SUPERSEDED_VER" ] || { log_error "declare-superseded: --superseded-version is required"; exit 2; }
	[ -n "$SUPERSEDING_VER" ] || { log_error "declare-superseded: --superseding-version is required"; exit 2; }
	[ -n "$REASON" ] || { log_error "declare-superseded: --reason is required"; exit 2; }
	if [ -z "$GUIDANCE" ]; then
		GUIDANCE="Upgrade to $SUPERSEDING_VER: pin the Sentinel Shield ref to the superseding release tag.
Re-run install-baseline/sync against $SUPERSEDING_VER and re-run your CI to confirm green.
Do NOT expect $SUPERSEDED_VER's tag to move or disappear — released tags are immutable; the fix ships as $SUPERSEDING_VER."
	fi
	_guid=$(build_str_array "$GUIDANCE")
	_refs=$(build_str_array "$REFERENCES")
	_affected=$(jq -n --arg v "$SUPERSEDED_VER" --arg t "$SUPERSEDED_TAG" '
		[ { version:$v, status:"superseded" } + (if ($t|length) > 0 then { tag:$t } else {} end) ]')
	ADV=$(jq -n \
		--arg id "$ADVISORY_ID" --arg at "$(timestamp_utc)" --arg reason "$REASON" \
		--arg sv "$SUPERSEDING_VER" --arg st "$SUPERSEDING_TAG" \
		--argjson affected "$_affected" --argjson guid "$_guid" --argjson refs "$_refs" '
		{ schema_version:"1", advisory_id:$id, kind:"superseded", generated_at:$at,
		  title:("\($sv) supersedes the affected release(s)"), reason:$reason,
		  affected_versions:$affected, superseding_version:$sv,
		  action:"publish-superseding-release", consumer_guidance:$guid }
		+ (if ($st|length) > 0 then { superseding_tag:$st } else {} end)
		+ (if ($refs|length) > 0 then { references:$refs } else {} end)')
	_tmp=$(mktemp 2>/dev/null || mktemp -t ssadv); printf '%s\n' "$ADV" > "$_tmp"
	validate_advisory "$_tmp" || { rm -f "$_tmp"; log_error "declare-superseded: emitted advisory failed validation (fail closed)"; exit 2; }
	rm -f "$_tmp"
	if [ -n "$OUTPUT" ]; then printf '%s\n' "$ADV" > "$OUTPUT"; log_info "declare-superseded: wrote advisory to $OUTPUT"; else printf '%s\n' "$ADV"; fi
	log_info "declare-superseded: $SUPERSEDED_VER marked 'superseded' by $SUPERSEDING_VER (no tag was deleted or moved)"
	exit 0
fi

if [ "$MODE" = rollback-advisory ]; then
	[ -n "$ADVISORY_ID" ] || { log_error "rollback-advisory: --advisory-id is required"; exit 2; }
	[ -n "$AFFECTED" ] || { log_error "rollback-advisory: at least one --affected-version is required"; exit 2; }
	[ -n "$ROLLBACK_TO" ] || { log_error "rollback-advisory: --rollback-to is required"; exit 2; }
	[ -n "$REASON" ] || { log_error "rollback-advisory: --reason is required"; exit 2; }
	if [ -z "$GUIDANCE" ]; then
		GUIDANCE="Pin Sentinel Shield to the known-good release $ROLLBACK_TO until a superseding fix ships.
Re-run install-baseline/sync against $ROLLBACK_TO and confirm your CI is green.
Watch for the superseding release; the affected tag(s) remain published and immutable."
	fi
	_affected=$(build_str_array "$AFFECTED" | jq -c 'map({ version:., status:"affected" })')
	_guid=$(build_str_array "$GUIDANCE")
	_refs=$(build_str_array "$REFERENCES")
	ADV=$(jq -n \
		--arg id "$ADVISORY_ID" --arg at "$(timestamp_utc)" --arg reason "$REASON" --arg rt "$ROLLBACK_TO" \
		--argjson affected "$_affected" --argjson guid "$_guid" --argjson refs "$_refs" '
		{ schema_version:"1", advisory_id:$id, kind:"rollback", generated_at:$at,
		  title:("Recommend rolling back to \($rt)"), reason:$reason,
		  affected_versions:$affected, rollback_to:$rt,
		  action:"recommend-rollback", consumer_guidance:$guid }
		+ (if ($refs|length) > 0 then { references:$refs } else {} end)')
	_tmp=$(mktemp 2>/dev/null || mktemp -t ssadv); printf '%s\n' "$ADV" > "$_tmp"
	validate_advisory "$_tmp" || { rm -f "$_tmp"; log_error "rollback-advisory: emitted advisory failed validation (fail closed)"; exit 2; }
	rm -f "$_tmp"
	if [ -n "$OUTPUT" ]; then printf '%s\n' "$ADV" > "$OUTPUT"; log_info "rollback-advisory: wrote advisory to $OUTPUT"; else printf '%s\n' "$ADV"; fi
	log_info "rollback-advisory: recommended rollback to $ROLLBACK_TO (no tag/release was deleted or moved)"
	exit 0
fi

log_error "unhandled mode: $MODE"
exit 2
