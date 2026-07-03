#!/bin/sh
# tests/prod/263-production-readiness.sh — deterministic tests for the production-readiness
# orchestrator + independent evidence-review harness: scripts/run-production-readiness.sh and
# schemas/production-readiness-report.schema.json.
#
# NETWORK-FREE + DETERMINISTIC. Every scenario builds synthetic report / plan / facts fixtures
# in a scratch dir; report freshness uses a pinned "now" (SENTINEL_SHIELD_RELEASE_NOW) with
# fixed generated_at timestamps so the SAME assertions hold on any day. The timeout path is
# exercised by injecting the timeout sentinel exit code (124) from a gate command, so it is
# deterministic on hosts with or without timeout(1).
#
# Coverage:
#   POSITIVE  — complete run fixture -> READY(0), schema-valid report, recommendation v2.0.0;
#               review VERIFIES a complete report; version-decision returns v2.0.0/rc.1/beta.3.
#   NEGATIVE  — review rejects (exit 1) evidence whose source commit / workflow identity /
#               default branch / event / freshness / changed-files / summary consistency /
#               skipped-required-gate / gate result / tag policy / scanner health / compat /
#               adopter / security / limitations / artifact does not hold.
#   FAILURE-INJECTION — malformed/missing report/plan/facts fail closed (exit 2); a failing
#               required gate -> NOT READY (1); an injected timeout -> distinct exit 4.
#
# Self-contained; jq is a hard dependency. Prints "PASS: x" / "FAIL: x"; exits nonzero if any fail.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PR="$ROOT/scripts/run-production-readiness.sh"
SCHEMA="$ROOT/schemas/production-readiness-report.schema.json"

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Deterministic clock for report freshness (widened to T00:00:00Z by pr_now_iso).
SENTINEL_SHIELD_RELEASE_NOW=2026-07-04
export SENTINEL_SHIELD_RELEASE_NOW

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

RC=0
run() { RC=0; sh "$@" >/dev/null 2>&1 || RC=$?; }

SC=$(printf '%040d' 7)
WRONG=$(printf '%040d' 8)
SHA64=$(printf '%064d' 3)
WF=ci-production-readiness

# --- schema is valid JSON ----------------------------------------------------
if jq -e . "$SCHEMA" >/dev/null 2>&1; then pass "schema valid JSON: production-readiness-report.schema.json"; else fail "schema invalid JSON"; fi

# mk_report <path> — a COMPLETE, review-passing report at commit $SC, dated 2026-07-04.
mk_report() {
	jq -n --arg c "$SC" --arg sha "$SHA64" '
		{ schema_version:"1", kind:"production-readiness-report",
		  generated_at:"2026-07-04T00:00:00Z",
		  title:"Sentinel Shield production-readiness — engine-only (framework tracks validated independently)",
		  release_scope:"engine-only",
		  source:{ commit:$c, default_branch:"master", event:"push", workflow:"ci-production-readiness" },
		  changed_files:["scripts/run-production-readiness.sh"],
		  gates:[{ id:"g1", status:"pass", required:true }],
		  summary:{ total:1, passed:1, failed:0, skipped:0, timed_out:0 },
		  compatibility:{ complete:true, covered:["php-8.3"], missing:[] },
		  adopter:{ result:"pass", score:96 },
		  security:{ accepted:true },
		  scanners:[{ tool:"grype", health:"ok" }],
		  artifacts:[{ name:"engine-dist", sha256:$sha, ownership_ok:true, content_verified:true }],
		  limitations:{ documented:true, framework_live_validation:false },
		  evidence:{ default_branch_ci:true, evidence_complete:true, soak_complete:true },
		  tag_policy:{ destructive_ops_performed:false, tag_targets_source_commit:true },
		  version_recommendation:{ version:"v2.0.0", rationale:"complete", blockers:[] } }' > "$1"
}

REP_OK="$WORK/rep-ok.json"; mk_report "$REP_OK"

# ============================================================================
# emit-template — structure-only skeleton, schema-valid, commit=unknown
# ============================================================================
TMPL="$WORK/tmpl.json"
run "$PR" emit-template --out-json "$TMPL" --out-md "$WORK/tmpl.md"
assert_eq "emit-template exit 0" "$RC" "0"
if [ -f "$TMPL" ]; then
	assert_eq "emit-template kind" "$(jq -r '.kind' "$TMPL")" "production-readiness-report"
	assert_eq "emit-template commit placeholder" "$(jq -r '.source.commit' "$TMPL")" "unknown"
	assert_eq "emit-template scope engine-only" "$(jq -r '.release_scope' "$TMPL")" "engine-only"
	# A structure-only template must NEVER satisfy review (unknown commit).
	run "$PR" review --report "$TMPL" --expected-commit "$SC" --expected-workflow "$WF"
	assert_eq "emit-template does NOT pass review (unknown commit)" "$RC" "1"
fi

# ============================================================================
# run — POSITIVE: complete fixture -> READY(0), schema-valid, recommendation v2.0.0
# ============================================================================
printf '[{"id":"a","cmd":"true","required":true},{"id":"b","cmd":"true","required":true}]\n' > "$WORK/plan-ok.json"
jq -n --arg sha "$SHA64" '
	{ compatibility:{complete:true,covered:["php-8.3"],missing:[]}, adopter:{result:"pass",score:96},
	  security:{accepted:true}, scanners:[{tool:"grype",health:"ok"}],
	  artifacts:[{name:"engine-dist",sha256:$sha,ownership_ok:true,content_verified:true}],
	  limitations:{documented:true,framework_live_validation:false},
	  evidence:{default_branch_ci:true,evidence_complete:true,soak_complete:true},
	  tag_policy:{destructive_ops_performed:false,tag_targets_source_commit:true} }' > "$WORK/facts-full.json"
printf 'scripts/run-production-readiness.sh\n' > "$WORK/changed.txt"
REP_RUN="$WORK/rep-run.json"
run "$PR" run --plan "$WORK/plan-ok.json" --facts "$WORK/facts-full.json" --changed-files "$WORK/changed.txt" \
	--source-commit "$SC" --workflow "$WF" --event push --default-branch master \
	--out-json "$REP_RUN" --out-md "$WORK/rep-run.md"
assert_eq "run complete fixture -> READY (exit 0)" "$RC" "0"
if [ -f "$REP_RUN" ]; then
	# Report is schema-valid (structural jq check mirrors pr_validate_report / the schema).
	if jq -e '
		(.schema_version=="1") and (.kind=="production-readiness-report")
		and (.title|test("engine-only")) and (.source.commit|test("^[0-9a-f]{40}$"))
		and (.gates|type=="array") and (.summary.total==2)
		and (.version_recommendation.version|. == "v2.0.0" or . == "v2.0.0-rc.1" or . == "v2.0.0-beta.3")
	' "$REP_RUN" >/dev/null 2>&1; then pass "run report is schema-conformant"; else fail "run report is NOT schema-conformant"; fi
	assert_eq "run recommendation is v2.0.0 (all GA criteria pass)" "$(jq -r '.version_recommendation.version' "$REP_RUN")" "v2.0.0"
	assert_eq "run summary passed=2" "$(jq -r '.summary.passed' "$REP_RUN")" "2"
	# The emitted report round-trips through independent review.
	run "$PR" review --report "$REP_RUN" --expected-commit "$SC" --expected-workflow "$WF" --expected-event push
	assert_eq "run report passes independent review" "$RC" "0"
fi

# ============================================================================
# run — FAILURE-INJECTION
# ============================================================================
printf '[{"id":"ok","cmd":"true","required":true},{"id":"boom","cmd":"false","required":true}]\n' > "$WORK/plan-fail.json"
run "$PR" run --plan "$WORK/plan-fail.json" --source-commit "$SC" --event push --out-json "$WORK/rep-fail.json" --out-md "$WORK/rep-fail.md"
assert_eq "run with failing required gate -> NOT READY (exit 1)" "$RC" "1"
[ -f "$WORK/rep-fail.json" ] && assert_eq "run records failed gate status" "$(jq -r '.gates[] | select(.id=="boom") | .status' "$WORK/rep-fail.json")" "fail"

# Timeout injection: a gate exiting with the timeout sentinel (124) yields a DISTINCT exit 4.
printf '[{"id":"hang","cmd":"exit 124","required":true}]\n' > "$WORK/plan-to.json"
run "$PR" run --plan "$WORK/plan-to.json" --source-commit "$SC" --event push --out-json "$WORK/rep-to.json" --out-md "$WORK/rep-to.md"
assert_eq "run with timed-out required gate -> DISTINCT exit 4" "$RC" "4"
[ -f "$WORK/rep-to.json" ] && assert_eq "run records timeout gate status" "$(jq -r '.gates[0].status' "$WORK/rep-to.json")" "timeout"

# Skipped-when-tool-missing gate is not a failure.
printf '[{"id":"opt","cmd":"false","required":true,"skip_if_missing":"definitely-not-a-real-tool-xyz"}]\n' > "$WORK/plan-skip.json"
run "$PR" run --plan "$WORK/plan-skip.json" --source-commit "$SC" --event push --out-json "$WORK/rep-skip.json" --out-md "$WORK/rep-skip.md"
[ -f "$WORK/rep-skip.json" ] && assert_eq "run skips a gate whose tool is missing" "$(jq -r '.gates[0].status' "$WORK/rep-skip.json")" "skipped"

# Malformed / missing plan + facts fail closed.
printf '{ broken\n' > "$WORK/bad-plan.json"
run "$PR" run --plan "$WORK/bad-plan.json" --source-commit "$SC"
assert_eq "run malformed plan -> exit 2" "$RC" "2"
run "$PR" run --plan "$WORK/does-not-exist.json" --source-commit "$SC"
assert_eq "run missing plan -> exit 2" "$RC" "2"
printf '[]\n' > "$WORK/empty-plan.json"; printf '{ broken\n' > "$WORK/bad-facts.json"
run "$PR" run --plan "$WORK/empty-plan.json" --facts "$WORK/bad-facts.json" --source-commit "$SC"
assert_eq "run malformed facts -> exit 2" "$RC" "2"
run "$PR" run --plan "$WORK/empty-plan.json" --source-commit "not-a-sha"
assert_eq "run bad --source-commit -> exit 2" "$RC" "2"

# ============================================================================
# review — POSITIVE + the two REQUIRED mismatch rejections (source commit, workflow identity)
# ============================================================================
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "$WF" --expected-default-branch master --expected-event push
assert_eq "review complete report -> VERIFIED (exit 0)" "$RC" "0"
run "$PR" review --report "$REP_OK" --expected-commit "$WRONG" --expected-workflow "$WF"
assert_eq "review SOURCE COMMIT mismatch -> REJECTED (exit 1)" "$RC" "1"
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "some-other-workflow"
assert_eq "review WORKFLOW IDENTITY mismatch -> REJECTED (exit 1)" "$RC" "1"
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "$WF" --expected-default-branch release/x
assert_eq "review DEFAULT BRANCH mismatch -> REJECTED (exit 1)" "$RC" "1"
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "$WF" --expected-event workflow_dispatch
assert_eq "review EVENT mismatch -> REJECTED (exit 1)" "$RC" "1"

# review — freshness (stale + future-dated).
jq '.generated_at="2020-01-01T00:00:00Z"' "$REP_OK" > "$WORK/stale.json"
run "$PR" review --report "$WORK/stale.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review STALE report -> REJECTED (exit 1)" "$RC" "1"
jq '.generated_at="2027-01-01T00:00:00Z"' "$REP_OK" > "$WORK/future.json"
run "$PR" review --report "$WORK/future.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review FUTURE-DATED report -> REJECTED (exit 1)" "$RC" "1"
# A generous --max-age-seconds re-accepts a merely-old (but valid) report.
run "$PR" review --report "$WORK/stale.json" --expected-commit "$SC" --expected-workflow "$WF" --max-age-seconds 999999999
assert_eq "review old report within --max-age-seconds -> VERIFIED (exit 0)" "$RC" "0"

# review — ambiguous / inconsistent evidence.
jq '.summary.passed=99' "$REP_OK" > "$WORK/amb.json"
run "$PR" review --report "$WORK/amb.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review AMBIGUOUS summary -> REJECTED (exit 1)" "$RC" "1"

# review — event type: pull_request is never release proof.
jq '.source.event="pull_request"' "$REP_OK" > "$WORK/pr.json"
run "$PR" review --report "$WORK/pr.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review pull_request event -> REJECTED (exit 1)" "$RC" "1"

# review — empty changed-file inventory (test applicability unestablished).
jq '.changed_files=[]' "$REP_OK" > "$WORK/nocf.json"
run "$PR" review --report "$WORK/nocf.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review empty changed-files -> REJECTED (exit 1)" "$RC" "1"

# review — a skipped REQUIRED gate.
jq '.gates=[{"id":"g1","status":"skipped","required":true}] | .summary={total:1,passed:0,failed:0,skipped:1,timed_out:0}' "$REP_OK" > "$WORK/skip.json"
run "$PR" review --report "$WORK/skip.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review skipped REQUIRED gate -> REJECTED (exit 1)" "$RC" "1"

# review — a failing REQUIRED gate.
jq '.gates=[{"id":"g1","status":"fail","required":true}] | .summary={total:1,passed:0,failed:1,skipped:0,timed_out:0}' "$REP_OK" > "$WORK/gf.json"
run "$PR" review --report "$WORK/gf.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review failing REQUIRED gate -> REJECTED (exit 1)" "$RC" "1"

# review — tag-target policy: a destructive op is refused.
jq '.tag_policy.destructive_ops_performed=true' "$REP_OK" > "$WORK/destr.json"
run "$PR" review --report "$WORK/destr.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review DESTRUCTIVE tag op -> REJECTED (exit 1)" "$RC" "1"

# review — scanner health (parser-error is never clean).
jq '.scanners=[{"tool":"grype","health":"parser-error"}]' "$REP_OK" > "$WORK/scan.json"
run "$PR" review --report "$WORK/scan.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review unhealthy scanner -> REJECTED (exit 1)" "$RC" "1"

# review — compatibility coverage incomplete.
jq '.compatibility.complete=false | .compatibility.missing=["php-8.4"]' "$REP_OK" > "$WORK/compat.json"
run "$PR" review --report "$WORK/compat.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review incomplete compatibility -> REJECTED (exit 1)" "$RC" "1"

# review — adopter score below the floor.
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "$WF" --min-adopter-score 99
assert_eq "review adopter score below floor -> REJECTED (exit 1)" "$RC" "1"

# review — production security not accepted.
jq '.security.accepted=false' "$REP_OK" > "$WORK/sec.json"
run "$PR" review --report "$WORK/sec.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review security not accepted -> REJECTED (exit 1)" "$RC" "1"

# review — limitations wrongly claim framework live-validation.
jq '.limitations.framework_live_validation=true' "$REP_OK" > "$WORK/lim.json"
run "$PR" review --report "$WORK/lim.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review claims framework live-validation -> REJECTED (exit 1)" "$RC" "1"

# review — an artifact that is not owned / content-verified.
jq '.artifacts=[{"name":"x","sha256":"'"$SHA64"'","ownership_ok":false,"content_verified":true}]' "$REP_OK" > "$WORK/art.json"
run "$PR" review --report "$WORK/art.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review unverified artifact -> REJECTED (exit 1)" "$RC" "1"

# review — profiles: ci-gate passes on identity+gates only; release rejects the same minimal report.
jq 'del(.compatibility,.adopter,.security,.scanners,.limitations,.evidence)' "$REP_OK" > "$WORK/min.json"
run "$PR" review --report "$WORK/min.json" --expected-commit "$SC" --expected-workflow "$WF" --profile ci-gate
assert_eq "review ci-gate profile passes minimal report -> exit 0" "$RC" "0"
run "$PR" review --report "$WORK/min.json" --expected-commit "$SC" --expected-workflow "$WF" --profile release
assert_eq "review release profile rejects minimal report -> exit 1" "$RC" "1"

# review — fail-closed on malformed / missing report and a non-40-hex expectation.
printf '{ broken\n' > "$WORK/bad.json"
run "$PR" review --report "$WORK/bad.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review malformed report -> exit 2" "$RC" "2"
run "$PR" review --report "$WORK/does-not-exist.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review missing report -> exit 2" "$RC" "2"
run "$PR" review --report "$REP_OK" --expected-commit "not-a-sha" --expected-workflow "$WF"
assert_eq "review non-40-hex --expected-commit -> exit 2" "$RC" "2"
# A title that omits engine-only fails STRUCTURAL validation (fail closed, exit 2).
jq '.title="just a plain title"' "$REP_OK" > "$WORK/title.json"
run "$PR" review --report "$WORK/title.json" --expected-commit "$SC" --expected-workflow "$WF"
assert_eq "review title omitting engine-only -> fail closed (exit 2)" "$RC" "2"

# ============================================================================
# version-decision — v2.0.0 / v2.0.0-rc.1 / v2.0.0-beta.3
# ============================================================================
assert_eq "version-decision complete -> v2.0.0" "$(sh "$PR" version-decision --report "$REP_OK" 2>/dev/null | jq -r '.version')" "v2.0.0"
jq '.evidence.soak_complete=false' "$REP_OK" > "$WORK/rc.json"
assert_eq "version-decision soak remaining -> v2.0.0-rc.1" "$(sh "$PR" version-decision --report "$WORK/rc.json" 2>/dev/null | jq -r '.version')" "v2.0.0-rc.1"
jq '.security.accepted=false' "$REP_OK" > "$WORK/blk.json"
assert_eq "version-decision material blocker -> v2.0.0-beta.3" "$(sh "$PR" version-decision --report "$WORK/blk.json" 2>/dev/null | jq -r '.version')" "v2.0.0-beta.3"
# --strict: when review passes the higher recommendation stands; when it does not, safe floor beta.3.
assert_eq "version-decision --strict (review passes) -> v2.0.0" \
	"$(sh "$PR" version-decision --report "$REP_OK" --strict --expected-commit "$SC" --expected-workflow "$WF" 2>/dev/null | jq -r '.version')" "v2.0.0"
assert_eq "version-decision --strict (review fails) -> v2.0.0-beta.3 floor" \
	"$(sh "$PR" version-decision --report "$REP_OK" --strict --expected-commit "$WRONG" --expected-workflow "$WF" 2>/dev/null | jq -r '.version')" "v2.0.0-beta.3"

# ============================================================================
# global fail-closed: unknown mode + refused destructive op
# ============================================================================
run "$PR" nonsense-mode
assert_eq "fail-closed: unknown mode -> exit 2" "$RC" "2"
run "$PR" run --plan "$WORK/plan-ok.json" --source-commit "$SC" --delete-tag v2.0.0
assert_eq "fail-closed: refused destructive --delete-tag -> exit 2" "$RC" "2"
run "$PR" review --report "$REP_OK" --expected-commit "$SC" --expected-workflow "$WF" --force-push
assert_eq "fail-closed: refused destructive --force-push -> exit 2" "$RC" "2"

printf '\n263-production-readiness: %d failure(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
printf 'All production-readiness assertions passed.\n'
exit 0
