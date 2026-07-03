#!/bin/sh
# tests/prod/262-production-release.sh — deterministic tests for production release, rollback,
# and support authorization: scripts/authorize-production-release.sh, scripts/verify-published-release.sh,
# scripts/lib/release-authz.sh and their schemas (release-authorization / release-candidate /
# rollback-advisory).
#
# NETWORK-FREE + DETERMINISTIC. Every scenario builds synthetic evidence / manifest / report
# fixtures in a scratch dir; waiver + authorization expiry use fixed far-future (2999) / past
# (2000) dates and a pinned "now" (SENTINEL_SHIELD_RELEASE_NOW) so the SAME assertions hold on
# any day. verify-tag scenarios build a real throwaway git repo (no signing keys needed: a
# wrong-target tag fails identity; an unsigned tag fails the signature requirement).
#
# The 16 required scenarios:
#   (1) missing master/default-branch CI            -> NOT READY
#   (2) PR CI offered as release proof              -> REJECTED
#   (3) wrong source commit                          -> REJECTED
#   (4) unverifiable signed tag                      -> REJECTED
#   (5) tag targeting the wrong commit               -> REJECTED
#   (6) artifact digest mismatch vs manifest         -> NOT READY
#   (7) failed security acceptance                   -> NOT READY
#   (8) incomplete compatibility matrix              -> NOT READY
#   (9) failed adopter scorecard                     -> NOT READY
#  (10) expired waiver                               -> NOT READY
#  (11) valid engine-only RC                         -> READY (exit 0)
#  (12) valid engine-only GA                         -> READY (exit 0)
#  (13) framework-validated GA                       -> BLOCKED (nonzero)
#  (14) attempted tag movement                       -> REFUSED (exit 2)
#  (15) attempted release deletion as rollback       -> REFUSED (exit 2)
#  (16) valid superseding-release workflow           -> advisory emitted, affected marked, no delete/move
#
# Self-contained; jq is a hard dependency. Prints "PASS: x" / "FAIL: x"; exits nonzero if any fail.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
AUTH="$ROOT/scripts/authorize-production-release.sh"
VPUB="$ROOT/scripts/verify-published-release.sh"
GEN="$ROOT/scripts/generate-release-manifest.sh"
CAND_SCHEMA="$ROOT/schemas/release-candidate.schema.json"
AUTHZ_SCHEMA="$ROOT/schemas/release-authorization.schema.json"
ADV_SCHEMA="$ROOT/schemas/rollback-advisory.schema.json"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'FAIL: git is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Deterministic clock for waiver/authorization expiry.
SENTINEL_SHIELD_RELEASE_NOW=2026-07-04
export SENTINEL_SHIELD_RELEASE_NOW

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

RC=0
run() { RC=0; sh "$@" >/dev/null 2>&1 || RC=$?; }

SRC=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
WRONG=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
A_SHA=$(printf '%064d' 1)
B_SHA=$(printf '%064d' 2)
EMPTY="$WORK/emptyrepo"; mkdir -p "$EMPTY"

# --- schemas are valid JSON --------------------------------------------------
for _s in "$CAND_SCHEMA" "$AUTHZ_SCHEMA" "$ADV_SCHEMA"; do
	if jq -e . "$_s" >/dev/null 2>&1; then pass "schema valid JSON: $(basename "$_s")"; else fail "schema invalid JSON: $(basename "$_s")"; fi
done

# mk_evidence <path> <engine_commit> <event|none> <result> — a release-evidence fixture.
mk_evidence() {
	if [ "$3" = none ]; then _ci='[]'; else
		_ci=$(jq -n --arg c "$2" --arg e "$3" --arg r "$4" '[{workflow_name:"ci-self-test",repository:"org/engine",commit:$c,event:$e,workflow_run_id:12,workflow_url:"https://github.com/org/engine/actions/runs/12",result:$r,artifacts:[],artifacts_verified:false,verified_at:"2026-07-01T00:00:00Z",verification_method:"github-api"}]')
	fi
	jq -n --arg v 2.0.0 --arg c "$2" --argjson ci "$_ci" '
		{version:$v,stage:"ga",release_scope:"engine-only",engine_ci:$ci,engine_commit:$c,consumer_runs:[],
		 required_evidence:{laravel:false,symfony:false,php_library:false,node_react:false,combined_profile:false,bootstrap_apply:false,rollback_npm:false,rollback_pnpm:false,rollback_yarn:false}}' > "$1"
}

# mk_artifacts <path> <sha> — a verify-release-artifacts style report (green).
mk_artifacts() {
	jq -n --arg s "$2" '{tool:"verify-release-artifacts",generated_at:"2026-07-01T00:00:00Z",engine_commit:"'"$SRC"'",status:"pass",artifact_count:1,failure_count:0,artifacts:[{repository:"org/engine",run_id:12,artifact_id:1,name:"engine-dist",ownership_ok:true,expired:false,size_in_bytes:10,archive_safe:true,sha256:$s,file_count:1,files:[{path:"a",sha256:$s}],embedded_commit_found:true,verified:true,reasons:[]}]}' > "$1"
}

mk_secacc() { # <path> <decision> <blocking> <violations-json>
	jq -n --arg d "$2" --argjson b "$3" --argjson viol "$4" '
		{schema_version:"1",generated_at:"2026-07-01T00:00:00Z",policy_version:"1.0.0",decision:$d,exit_code:0,
		 scanners:[],coverage:{},findings:{blocking:$b},waivers:{applied:[],rejected:[]},regression:{},violations:$viol}' > "$1"
}

mk_report() { printf '%s\n' "$2" > "$1"; }   # write raw JSON

# Common green sub-reports.
EV_OK="$WORK/ev-ok.json"; mk_evidence "$EV_OK" "$SRC" push success
ART_OK="$WORK/art-ok.json"; mk_artifacts "$ART_OK" "$A_SHA"
MF_OK="$WORK/mf-ok.json"
sh "$GEN" --evidence "$EV_OK" --artifacts "$ART_OK" --source-commit "$SRC" --repo-root "$EMPTY" --output "$MF_OK" >/dev/null 2>&1 \
	|| { fail "manifest generation failed (setup)"; }
MF_HASH=$(jq -r '.reproducibility.hash // ""' "$MF_OK")
SEC_OK="$WORK/sec-ok.json"; mk_secacc "$SEC_OK" accepted 0 '[]'
CMP_OK="$WORK/cmp-ok.json"; mk_report "$CMP_OK" '{"status":"pass","complete":true}'
ADO_OK="$WORK/ado-ok.json"; mk_report "$ADO_OK" '{"result":"pass"}'
UPG_OK="$WORK/upg-ok.json"; mk_report "$UPG_OK" '{"status":"pass"}'
RBK_OK="$WORK/rbk-ok.json"; mk_report "$RBK_OK" '{"status":"pass"}'
LIMITS="$WORK/limitations.md"; printf '# Published limitations\nEngine-only scope; no framework live-validation.\n' > "$LIMITS"
SUPPORT="$ROOT/docs/support-policy.md"
INCIDENT="$ROOT/docs/security-incident-response.md"

# mk_candidate <path> <stage> <scope> <source> <evidence> <manifest> <artifacts> <sec> <cmp> <ado> <upg> <rbk> [waivers]
mk_candidate() {
	_wv=""; [ $# -ge 13 ] && _wv="${13}"
	jq -n \
		--arg stage "$2" --arg scope "$3" --arg src "$4" \
		--arg ev "$5" --arg mf "$6" --arg art "$7" --arg sec "$8" \
		--arg cmp "$9" --arg ado "${10}" --arg upg "${11}" --arg rbk "${12}" --arg wv "$_wv" \
		--arg lim "$LIMITS" --arg sup "$SUPPORT" --arg inc "$INCIDENT" '
		{schema_version:"1",version:"2.0.0",stage:$stage,release_scope:$scope,source_commit:$src,tag:"v2.0.0",
		 artifacts:({evidence:$ev,manifest:$mf,artifact_verification:$art,security_acceptance:$sec,
		   compatibility_matrix:$cmp,adopter_scorecard:$ado,upgrade_validation:$upg,rollback_validation:$rbk}
		   + (if ($wv|length)>0 then {waivers:$wv} else {} end)),
		 docs:{limitations:$lim,support_policy:$sup,incident_response:$inc}}' > "$1"
}

# ============================================================================
# (11) valid engine-only RC -> READY
# ============================================================================
C_RC="$WORK/c-rc.json"; mk_candidate "$C_RC" rc engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C_RC"
assert_eq "(11) valid engine-only RC -> READY (exit 0)" "$RC" "0"

# ============================================================================
# (12) valid engine-only GA -> READY
# ============================================================================
C_GA="$WORK/c-ga.json"; mk_candidate "$C_GA" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C_GA"
assert_eq "(12) valid engine-only GA -> READY (exit 0)" "$RC" "0"

# ============================================================================
# (13) framework-validated GA -> BLOCKED
# ============================================================================
C_FW="$WORK/c-fw.json"; mk_candidate "$C_FW" ga framework-validated "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C_FW"
assert_eq "(13) framework-validated GA -> BLOCKED (exit 1)" "$RC" "1"

# ============================================================================
# (1) missing default-branch CI -> NOT READY
# ============================================================================
EV_NOCI="$WORK/ev-noci.json"; mk_evidence "$EV_NOCI" "$SRC" none success
C1="$WORK/c1.json"; mk_candidate "$C1" ga engine-only "$SRC" "$EV_NOCI" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C1"
assert_eq "(1) missing default-branch CI -> NOT READY (exit 1)" "$RC" "1"

# ============================================================================
# (2) PR CI offered as proof -> REJECTED
# ============================================================================
EV_PR="$WORK/ev-pr.json"; mk_evidence "$EV_PR" "$SRC" pull_request success
C2="$WORK/c2.json"; mk_candidate "$C2" ga engine-only "$SRC" "$EV_PR" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C2"
assert_eq "(2) PR CI as proof -> REJECTED (exit 1)" "$RC" "1"

# ============================================================================
# (3) wrong source commit -> REJECTED
# ============================================================================
EV_WRONG="$WORK/ev-wrong.json"; mk_evidence "$EV_WRONG" "$WRONG" push success
C3="$WORK/c3.json"; mk_candidate "$C3" ga engine-only "$SRC" "$EV_WRONG" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C3"
assert_eq "(3) wrong source commit -> REJECTED (exit 1)" "$RC" "1"

# ============================================================================
# (6) artifact digest mismatch vs manifest -> NOT READY
# ============================================================================
ART_BAD="$WORK/art-bad.json"; mk_artifacts "$ART_BAD" "$B_SHA"   # green report, but digest != manifest
C6="$WORK/c6.json"; mk_candidate "$C6" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_BAD" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C6"
assert_eq "(6) artifact digest mismatch -> NOT READY (exit 1)" "$RC" "1"

# ============================================================================
# (7) failed security acceptance -> NOT READY
# ============================================================================
SEC_BAD="$WORK/sec-bad.json"; mk_secacc "$SEC_BAD" rejected 1 '[{"reason":"BLOCKING_FINDING"}]'
C7="$WORK/c7.json"; mk_candidate "$C7" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_BAD" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C7"
assert_eq "(7) failed security acceptance -> NOT READY (exit 1)" "$RC" "1"

# ============================================================================
# (8) incomplete compatibility matrix -> NOT READY
# ============================================================================
CMP_BAD="$WORK/cmp-bad.json"; mk_report "$CMP_BAD" '{"status":"pass","complete":false,"missing":["php-8.4"]}'
C8="$WORK/c8.json"; mk_candidate "$C8" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_BAD" "$ADO_OK" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C8"
assert_eq "(8) incomplete compat matrix -> NOT READY (exit 1)" "$RC" "1"

# ============================================================================
# (9) failed adopter scorecard -> NOT READY
# ============================================================================
ADO_BAD="$WORK/ado-bad.json"; mk_report "$ADO_BAD" '{"result":"fail"}'
C9="$WORK/c9.json"; mk_candidate "$C9" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_BAD" "$UPG_OK" "$RBK_OK"
run "$AUTH" verify-candidate --candidate "$C9"
assert_eq "(9) failed adopter scorecard -> NOT READY (exit 1)" "$RC" "1"

# ============================================================================
# (10) expired waiver -> NOT READY
# ============================================================================
WV_EXP="$WORK/wv-exp.json"
printf '{"version":"1","risks":[{"id":"R","owner":"a","approved_by":"b","issue":"x","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-X","severity":"high","reason":"x","created_at":"2000-01-01","expires_at":"2000-02-01","status":"approved","scope":"finding"}]}\n' > "$WV_EXP"
C10="$WORK/c10.json"; mk_candidate "$C10" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK" "$WV_EXP"
run "$AUTH" verify-candidate --candidate "$C10"
assert_eq "(10) expired waiver -> NOT READY (exit 1)" "$RC" "1"
# a NON-expired waiver keeps the candidate READY
WV_OK="$WORK/wv-ok.json"
printf '{"version":"1","risks":[{"id":"R","owner":"a","approved_by":"b","issue":"x","scanner":"grype","category":"dependency_vulnerabilities","finding_id":"CVE-X","severity":"high","reason":"x","created_at":"2999-01-01","expires_at":"2999-02-01","status":"approved","scope":"finding"}]}\n' > "$WV_OK"
C10B="$WORK/c10b.json"; mk_candidate "$C10B" ga engine-only "$SRC" "$EV_OK" "$MF_OK" "$ART_OK" "$SEC_OK" "$CMP_OK" "$ADO_OK" "$UPG_OK" "$RBK_OK" "$WV_OK"
run "$AUTH" verify-candidate --candidate "$C10B"
assert_eq "(10b) non-expired waiver -> READY (exit 0)" "$RC" "0"

# ============================================================================
# verify-tag scenarios (4) & (5): build a real throwaway git repo
# ============================================================================
GITREPO="$WORK/gitrepo"; mkdir -p "$GITREPO"
(
	cd "$GITREPO"
	git init -q
	git config user.email t@example.com
	git config user.name tester
	git config commit.gpgsign false
	printf 'a\n' > f.txt; git add f.txt; git commit -q -m one
) >/dev/null 2>&1
CA=$(git -C "$GITREPO" rev-parse HEAD)
( cd "$GITREPO"; printf 'b\n' > f.txt; git add f.txt; git commit -q -m two ) >/dev/null 2>&1
CB=$(git -C "$GITREPO" rev-parse HEAD)
git -C "$GITREPO" tag -a v-wrong -m wrong "$CB" >/dev/null 2>&1     # annotated tag at the WRONG commit
git -C "$GITREPO" tag -a v-unsigned -m unsigned "$CA" >/dev/null 2>&1  # annotated, UNSIGNED, correct commit

# (5) tag targeting the wrong commit -> REJECTED
run "$VPUB" verify-tag --repo-root "$GITREPO" --tag v-wrong --commit "$CA"
assert_eq "(5) tag targets wrong commit -> REJECTED (exit 1)" "$RC" "1"

# (4) unverifiable signed tag (unsigned annotated) -> REJECTED (signature required)
run "$VPUB" verify-tag --repo-root "$GITREPO" --tag v-unsigned --commit "$CA"
assert_eq "(4) unverifiable signed tag -> REJECTED (exit 1)" "$RC" "1"
# identity-only path is explicit and opt-in
run "$VPUB" verify-tag --repo-root "$GITREPO" --tag v-unsigned --commit "$CA" --allow-unsigned
assert_eq "(4b) --allow-unsigned identity-only at correct commit -> exit 0" "$RC" "0"
# a genuinely absent tag fails closed
run "$VPUB" verify-tag --repo-root "$GITREPO" --tag v-absent --commit "$CA"
assert_eq "(4c) absent tag -> REJECTED (exit 1)" "$RC" "1"

# ============================================================================
# authorize: a governed authorization over a READY GA candidate
# ============================================================================
mk_authz() { # <path> <version> <stage> <scope> <src> <tag> <hash> <method> <req> <appr> <expires>
	jq -n --arg v "$2" --arg s "$3" --arg sc "$4" --arg c "$5" --arg tag "$6" --arg h "$7" \
		--arg m "$8" --arg req "$9" --arg appr "${10}" --arg exp "${11}" '
		{schema_version:"1",version:$v,stage:$s,release_scope:$sc,source_commit:$c,tag:$tag,candidate_hash:$h,
		 authorization:{method:$m,token:"tok-abcdef12",requested_by:$req,approved_by:$appr},
		 created_at:"2026-07-01T00:00:00Z",expires_at:$exp}' > "$1"
}
AUTHZ_OK="$WORK/authz-ok.json"; mk_authz "$AUTHZ_OK" 2.0.0 ga engine-only "$SRC" v2.0.0 "$MF_HASH" signed alice bob 2999-01-01T00:00:00Z
DEC="$WORK/decision.json"
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_OK" --output "$DEC"
assert_eq "(auth+) valid authorization over READY GA -> exit 0" "$RC" "0"
if [ -f "$DEC" ]; then
	assert_eq "(auth+) decision=authorized" "$(jq -r '.decision' "$DEC")" "authorized"
	assert_eq "(auth+) publish NOT performed (tool never publishes)" "$(jq -r '.publish.performed' "$DEC")" "false"
fi
# wrong candidate_hash -> the authorization does not bind -> rejected
AUTHZ_BADH="$WORK/authz-badh.json"; mk_authz "$AUTHZ_BADH" 2.0.0 ga engine-only "$SRC" v2.0.0 "$(printf '%064d' 9)" signed alice bob 2999-01-01T00:00:00Z
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_BADH"
assert_eq "(auth-) wrong candidate_hash -> REJECTED (exit 1)" "$RC" "1"
# self-approval -> rejected
AUTHZ_SELF="$WORK/authz-self.json"; mk_authz "$AUTHZ_SELF" 2.0.0 ga engine-only "$SRC" v2.0.0 "$MF_HASH" signed alice alice 2999-01-01T00:00:00Z
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_SELF"
assert_eq "(auth-) self-approval -> REJECTED (exit 1)" "$RC" "1"
# expired authorization -> rejected
AUTHZ_EXP="$WORK/authz-exp.json"; mk_authz "$AUTHZ_EXP" 2.0.0 ga engine-only "$SRC" v2.0.0 "$MF_HASH" signed alice bob 2000-01-01T00:00:00Z
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_EXP"
assert_eq "(auth-) expired authorization -> REJECTED (exit 1)" "$RC" "1"
# authorizing a NOT-READY candidate is refused
run "$AUTH" authorize --candidate "$C7" --authorization "$AUTHZ_OK"
assert_eq "(auth-) authorize refuses a NOT-READY candidate" "$RC" "1"

# interactive method requires the confirmation token
AUTHZ_INT="$WORK/authz-int.json"; mk_authz "$AUTHZ_INT" 2.0.0 ga engine-only "$SRC" v2.0.0 "$MF_HASH" interactive alice bob 2999-01-01T00:00:00Z
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_INT"
assert_eq "(auth-) interactive without --confirm-token -> REJECTED" "$RC" "1"
run "$AUTH" authorize --candidate "$C_GA" --authorization "$AUTHZ_INT" --confirm-token tok-abcdef12
assert_eq "(auth+) interactive with matching --confirm-token -> exit 0" "$RC" "0"

# print-tag-commands requires an authorization and never runs the commands
run "$AUTH" print-tag-commands --candidate "$C_GA" --authorization "$AUTHZ_OK"
assert_eq "(tagcmd) print-tag-commands with authorization -> exit 0" "$RC" "0"
run "$AUTH" print-tag-commands --candidate "$C_GA"
assert_eq "(tagcmd) print-tag-commands WITHOUT authorization -> refused (exit 2)" "$RC" "2"

# ============================================================================
# (14) attempted tag movement -> REFUSED
# ============================================================================
run "$AUTH" declare-superseded --move-tag v2.0.0 --advisory-id SSA-1 --superseded-version 2.0.0 --superseding-version 2.0.1 --reason x
assert_eq "(14) attempted tag movement -> REFUSED (exit 2)" "$RC" "2"
run "$VPUB" verify-tag --repo-root "$GITREPO" --tag v-unsigned --commit "$CA" --force-tag
assert_eq "(14b) verify-tag refuses --force-tag (exit 2)" "$RC" "2"

# ============================================================================
# (15) attempted release deletion as rollback -> REFUSED
# ============================================================================
run "$AUTH" rollback-advisory --delete-release v2.0.0 --advisory-id SSA-2 --affected-version 2.0.0 --rollback-to 1.9.0 --reason x
assert_eq "(15) attempted release deletion -> REFUSED (exit 2)" "$RC" "2"

# ============================================================================
# (16) valid superseding-release workflow -> advisory emitted, affected marked
# ============================================================================
ADV="$WORK/adv.json"
run "$AUTH" declare-superseded --advisory-id SSA-2026-001 --superseded-version 2.0.0 --superseded-tag v2.0.0 \
	--superseding-version 2.0.1 --superseding-tag v2.0.1 --reason "critical fix" \
	--guidance "Upgrade to 2.0.1" --output "$ADV"
assert_eq "(16) superseding workflow -> advisory emitted (exit 0)" "$RC" "0"
if [ -f "$ADV" ]; then
	assert_eq "(16) advisory kind=superseded" "$(jq -r '.kind' "$ADV")" "superseded"
	assert_eq "(16) affected version marked superseded" "$(jq -r '.affected_versions[0].status' "$ADV")" "superseded"
	assert_eq "(16) superseding_version recorded" "$(jq -r '.superseding_version' "$ADV")" "2.0.1"
	assert_eq "(16) action is publish-superseding-release (never delete/move)" "$(jq -r '.action' "$ADV")" "publish-superseding-release"
fi
# rollback advisory (non-destructive) path
ADV2="$WORK/adv2.json"
run "$AUTH" rollback-advisory --advisory-id SSA-2026-002 --affected-version 2.0.0 --rollback-to 1.9.0 --reason "regression" --output "$ADV2"
assert_eq "(16b) rollback advisory emitted (exit 0)" "$RC" "0"
if [ -f "$ADV2" ]; then
	assert_eq "(16b) advisory kind=rollback" "$(jq -r '.kind' "$ADV2")" "rollback"
	assert_eq "(16b) rollback_to recorded" "$(jq -r '.rollback_to' "$ADV2")" "1.9.0"
	assert_eq "(16b) action recommend-rollback" "$(jq -r '.action' "$ADV2")" "recommend-rollback"
fi

# ============================================================================
# FAILURE-INJECTION: malformed / missing inputs fail closed
# ============================================================================
printf '{ broken\n' > "$WORK/bad-candidate.json"
run "$AUTH" verify-candidate --candidate "$WORK/bad-candidate.json"
assert_eq "fail-closed: malformed candidate -> exit 2" "$RC" "2"
run "$AUTH" verify-candidate --candidate "$WORK/does-not-exist.json"
assert_eq "fail-closed: missing candidate -> exit 2" "$RC" "2"
run "$AUTH" nonsense-mode
assert_eq "fail-closed: unknown mode -> exit 2" "$RC" "2"
# a candidate missing a required artifact is NOT READY
C_MISS="$WORK/c-miss.json"
jq 'del(.artifacts.security_acceptance)' "$C_GA" > "$C_MISS"
run "$AUTH" verify-candidate --candidate "$C_MISS"
assert_eq "fail-closed: candidate missing security-acceptance -> NOT READY (exit 1)" "$RC" "1"

# smoke: post-release smoke passes for the matching manifest+artifacts, fails on mismatch
run "$VPUB" smoke --manifest "$MF_OK" --artifacts "$ART_OK"
assert_eq "(smoke+) matching manifest+artifacts -> exit 0" "$RC" "0"
run "$VPUB" smoke --manifest "$MF_OK" --artifacts "$ART_BAD"
assert_eq "(smoke-) mismatched digests -> exit 1" "$RC" "1"

# verify-github-release: offline metadata checks
GHREL="$WORK/ghrel.json"; printf '{"tag_name":"v2.0.0","draft":false,"prerelease":false}\n' > "$GHREL"
run "$VPUB" verify-github-release --tag v2.0.0 --stage ga --release-json "$GHREL"
assert_eq "(ghrel+) published non-draft GA release -> exit 0" "$RC" "0"
GHREL_DRAFT="$WORK/ghrel-draft.json"; printf '{"tag_name":"v2.0.0","draft":true,"prerelease":false}\n' > "$GHREL_DRAFT"
run "$VPUB" verify-github-release --tag v2.0.0 --stage ga --release-json "$GHREL_DRAFT"
assert_eq "(ghrel-) draft release -> REJECTED (exit 1)" "$RC" "1"
GHREL_PRE="$WORK/ghrel-pre.json"; printf '{"tag_name":"v2.0.0","draft":false,"prerelease":true}\n' > "$GHREL_PRE"
run "$VPUB" verify-github-release --tag v2.0.0 --stage ga --release-json "$GHREL_PRE"
assert_eq "(ghrel-) GA marked prerelease -> REJECTED (exit 1)" "$RC" "1"

printf '\n262-production-release: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All production-release assertions passed.\n'
exit 0
