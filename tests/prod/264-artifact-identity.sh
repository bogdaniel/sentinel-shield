#!/bin/sh
# Sentinel Shield production test — artifact IDENTITY validation before digest comparison
# (NN=264). Exercises scripts/lib/release-authz.sh :: ra_artifacts_match_manifest.
#
# The gate must validate every artifact record's COMPLETE identity tuple (artifact_id,
# artifact_name, workflow_run_id, repository, size, sha256, expired, verified) BEFORE any set
# comparison. The historical bug: malformed/missing digests were silently filtered out, so a
# report whose only artifact had a malformed digest collapsed to [] and compared equal to an
# empty manifest set — a SPURIOUS pass. This suite proves that bug is dead and that duplicates,
# conflicting identities, expired, verified:false, and zero-where-required are all rejected,
# while a genuinely matching set still passes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib"
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$LIB/release-authz.sh"

command_exists jq || { printf 'FAIL: jq required\n' >&2; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssartid)
trap 'rm -rf "$WORK"' EXIT INT TERM
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

S1=$(printf '%064d' 1)   # valid 64-hex digest
S2=$(printf '%064d' 2)   # a different valid 64-hex digest

# report_rec <sha> <expired> <verified> <name> <repo> <size> <run_id> <artifact_id> -> one record JSON
report_rec() {
	jq -n --arg s "$1" --argjson e "$2" --argjson v "$3" --arg n "$4" --arg r "$5" \
		--argjson sz "$6" --argjson run "$7" --argjson aid "$8" '
		{ repository:$r, run_id:$run, artifact_id:$aid, name:$n, ownership_ok:true,
		  expired:$e, size_in_bytes:$sz, archive_safe:true, sha256:$s, file_count:1,
		  files:[{path:"a",sha256:$s}], embedded_commit_found:true, verified:$v, reasons:[] }'
}
# mk_report <out> <record-json...> — assemble a verify-release-artifacts style report.
mk_report() { _o="$1"; shift; printf '%s\n' "$@" | jq -sc '{tool:"verify-release-artifacts",status:"pass",failure_count:0,artifacts:.}' > "$_o"; }
# manifest_rec <sha> <name> <run_id> <artifact_id>
manifest_rec() { jq -n --arg s "$1" --arg n "$2" --argjson run "$3" --argjson aid "$4" '{run_id:$run,artifact_id:$aid,name:$n,sha256:$s}'; }
# mk_manifest <out> <record-json...>
mk_manifest() { _o="$1"; shift; printf '%s\n' "$@" | jq -sc '{schema_version:"1",body:{artifact_digests:.}}' > "$_o"; }

# call <report> <manifest> [policy] -> sets RC
call() { _rc=0; ra_artifacts_match_manifest "$@" >/dev/null 2>&1 || _rc=$?; RC=$_rc; }

# ---------- VALID: identical identity tuple on both sides ----------
mk_report "$WORK/rep-ok.json" "$(report_rec "$S1" false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-ok.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-ok.json" "$WORK/mf-ok.json"
[ "$RC" = 0 ] && pass "valid matching identity set -> 0" || fail "valid match expected 0, got $RC"

# ---------- THE BUG: malformed digest must NOT collapse to an empty match ----------
# Report has ONE artifact whose digest is malformed; manifest carries zero digests (the
# generator would have filtered the malformed one out). Old code: [] == [] -> spurious 0.
mk_report "$WORK/rep-bad.json" "$(report_rec badf00d false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-empty.json"
call "$WORK/rep-bad.json" "$WORK/mf-empty.json"
[ "$RC" = 2 ] && pass "malformed report digest vs empty manifest -> REJECTED (2), not spurious pass" \
	|| fail "malformed digest collapse expected 2, got $RC"

# ---------- Both sides malformed -> old code collapsed both to [] and PASSED ----------
mk_report "$WORK/rep-bad2.json" "$(report_rec zzzz false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-bad2.json" "$(manifest_rec notahexdigest engine-dist 12 1)"
call "$WORK/rep-bad2.json" "$WORK/mf-bad2.json"
[ "$RC" = 2 ] && pass "both sides malformed digests -> REJECTED (2), no empty-array collapse" \
	|| fail "both-malformed expected 2, got $RC"

# ---------- MISSING IDENTITY: empty artifact_name ----------
mk_report "$WORK/rep-noname.json" "$(report_rec "$S1" false true '' org/engine 10 12 1)"
mk_manifest "$WORK/mf-noname.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-noname.json" "$WORK/mf-noname.json"
[ "$RC" = 2 ] && pass "missing artifact_name -> REJECTED (2)" || fail "missing name expected 2, got $RC"

# ---------- MISSING IDENTITY: artifact_id 0 (missing) ----------
mk_report "$WORK/rep-noid.json" "$(report_rec "$S1" false true engine-dist org/engine 10 12 0)"
mk_manifest "$WORK/mf-noid.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-noid.json" "$WORK/mf-noid.json"
[ "$RC" = 2 ] && pass "missing artifact_id (0) -> REJECTED (2)" || fail "missing id expected 2, got $RC"

# ---------- MISSING IDENTITY: repository not owner/name ----------
mk_report "$WORK/rep-norepo.json" "$(report_rec "$S1" false true engine-dist not-a-repo 10 12 1)"
mk_manifest "$WORK/mf-norepo.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-norepo.json" "$WORK/mf-norepo.json"
[ "$RC" = 2 ] && pass "malformed repository -> REJECTED (2)" || fail "bad repo expected 2, got $RC"

# ---------- DUPLICATE: same full record twice ----------
mk_report "$WORK/rep-dup.json" \
	"$(report_rec "$S1" false true engine-dist org/engine 10 12 1)" \
	"$(report_rec "$S1" false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-dup.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-dup.json" "$WORK/mf-dup.json"
[ "$RC" = 2 ] && pass "duplicate artifact record -> REJECTED (2)" || fail "duplicate expected 2, got $RC"

# ---------- CONFLICTING IDENTITY: same run+id, different digest ----------
mk_report "$WORK/rep-conf.json" \
	"$(report_rec "$S1" false true engine-dist org/engine 10 12 1)" \
	"$(report_rec "$S2" false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-conf.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-conf.json" "$WORK/mf-conf.json"
[ "$RC" = 2 ] && pass "conflicting identity (same run+id, different sha) -> REJECTED (2)" \
	|| fail "conflict expected 2, got $RC"

# ---------- EXPIRED ----------
mk_report "$WORK/rep-exp.json" "$(report_rec "$S1" true true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-exp.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-exp.json" "$WORK/mf-exp.json"
[ "$RC" = 2 ] && pass "expired artifact -> REJECTED (2)" || fail "expired expected 2, got $RC"

# ---------- verified:false ----------
mk_report "$WORK/rep-unv.json" "$(report_rec "$S1" false false engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-unv.json" "$(manifest_rec "$S1" engine-dist 12 1)"
call "$WORK/rep-unv.json" "$WORK/mf-unv.json"
[ "$RC" = 2 ] && pass "verified:false artifact -> REJECTED (2)" || fail "verified:false expected 2, got $RC"

# ---------- DIGEST DRIFT: both well-formed but different sets -> rejected (1) ----------
mk_report "$WORK/rep-drift.json" "$(report_rec "$S1" false true engine-dist org/engine 10 12 1)"
mk_manifest "$WORK/mf-drift.json" "$(manifest_rec "$S2" engine-dist 12 1)"
call "$WORK/rep-drift.json" "$WORK/mf-drift.json"
[ "$RC" = 1 ] && pass "well-formed digest drift -> DIGEST_MISMATCH (1)" || fail "drift expected 1, got $RC"

# ---------- ZERO artifacts, no policy -> match (engine-only) ----------
mk_report "$WORK/rep-zero.json"
mk_manifest "$WORK/mf-zero.json"
call "$WORK/rep-zero.json" "$WORK/mf-zero.json"
[ "$RC" = 0 ] && pass "zero artifacts, no policy -> match (0)" || fail "zero/no-policy expected 0, got $RC"

# ---------- ZERO artifacts, policy REQUIRES artifacts -> rejected (1) ----------
printf '{"repository":"org/engine","approved_events":["push"],"required_workflows":[{"workflow_name":"ci-pipeline","artifacts_required":true}]}\n' > "$WORK/pol-req.json"
call "$WORK/rep-zero.json" "$WORK/mf-zero.json" "$WORK/pol-req.json"
[ "$RC" = 1 ] && pass "zero artifacts where policy requires them -> REJECTED (1)" \
	|| fail "zero/required expected 1, got $RC"

# ---------- ZERO artifacts, policy permits (no artifact-producing workflow) -> match ----------
printf '{"repository":"org/engine","approved_events":["push"],"required_workflows":[{"workflow_name":"ci-self-test","artifacts_required":false}]}\n' > "$WORK/pol-opt.json"
call "$WORK/rep-zero.json" "$WORK/mf-zero.json" "$WORK/pol-opt.json"
[ "$RC" = 0 ] && pass "zero artifacts, policy permits -> match (0)" || fail "zero/permitted expected 0, got $RC"

# ---------- Non-array .artifacts in report -> fail closed (2) ----------
printf '{"artifacts":"nope"}\n' > "$WORK/rep-nonarr.json"
call "$WORK/rep-nonarr.json" "$WORK/mf-ok.json"
[ "$RC" = 2 ] && pass "non-array report .artifacts -> fail closed (2)" || fail "non-array expected 2, got $RC"

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
printf '\nall artifact-identity assertions passed\n'
exit 0
