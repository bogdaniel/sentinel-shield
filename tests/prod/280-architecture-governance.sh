#!/bin/sh
# Sentinel Shield prod test — architecture governance (v2.1.0).
#
# Covers the multi-language architecture-evidence feature: resolver mode defaults for the new
# missing_architecture_evidence gate, the enforcer (violations blocking from baseline, missing
# evidence blocking in strict/regulated), every architecture collector (Deptrac native +
# normalized, dependency-cruiser native, ESLint boundary filtering, custom JS/PHP contracts),
# fail-closed behavior on unknown status / unknown shape / invalid JSON / missing report, the
# builder's cross-producer aggregation (violations summed, contexts maxed, never mixed into
# security counters), profile-aware missing architecture evidence, PHP+JS independence in a
# combined profile, and the architecture-policy loader's fail-closed parsing.
#
# Scope honesty: this suite proves the ENGINE and its fixtures. It is not consumer proof —
# a real Laravel/Symfony/Node consumer validation is a separate exercise
# (docs/architecture-governance.md).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FAILED=0
# pass <message> — record a passing check.
pass() { printf 'PASS: %s\n' "$1"; }
# fail <message> — record a failing check and mark the suite failed.
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss280)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

RESOLVE="$ROOT/scripts/resolve-gates.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"
COLL="$ROOT/scripts/collectors"
RUNNERS="$ROOT/scripts/runners"

# --- (1) resolver mode defaults ----------------------------------------------
gate_val() { # gate_val <env-file> <GATE_KEY_UPPER>
	awk -F= -v k="SENTINEL_SHIELD_FAIL_ON_$2" '$1==k{print $2; exit}' "$1"
}
for m in report-only baseline strict regulated; do
	od="$WORK/mode-$m"; sh "$RESOLVE" --mode "$m" --output-dir "$od" --format env >/dev/null 2>&1
	envf="$od/sentinel-shield-gates.env"
	av=$(gate_val "$envf" ARCHITECTURE_VIOLATIONS)
	mae=$(gate_val "$envf" MISSING_ARCHITECTURE_EVIDENCE)
	case "$m" in
		report-only) exp_av=false; exp_mae=false ;;
		baseline)    exp_av=true;  exp_mae=false ;;
		*)           exp_av=true;  exp_mae=true ;;
	esac
	if [ "$av" = "$exp_av" ] && [ "$mae" = "$exp_mae" ]; then
		pass "$m: architecture_violations=$av, missing_architecture_evidence=$mae"
	else
		fail "$m: expected av=$exp_av/mae=$exp_mae, got av=$av/mae=$mae"
	fi
done

# explicit profile override still wins over the mode default
mkdir -p "$WORK/proj/.sentinel-shield"
cat > "$WORK/proj/.sentinel-shield/profile.yaml" <<'EOF'
project:
  name: demo
gates:
  mode: baseline
  fail_on:
    missing_architecture_evidence: true
EOF
sh "$RESOLVE" --profile "$WORK/proj/.sentinel-shield/profile.yaml" --output-dir "$WORK/ovr" --format env >/dev/null 2>&1
[ "$(gate_val "$WORK/ovr/sentinel-shield-gates.env" MISSING_ARCHITECTURE_EVIDENCE)" = "true" ] \
	&& pass "resolver: explicit missing_architecture_evidence override applied in baseline" \
	|| fail "resolver: missing_architecture_evidence override not applied"

# --- (2) collectors: Deptrac (native + normalized + fail-closed) --------------
CT="$WORK/coll"; mkdir -p "$CT"
echo '{"report":{"violations":0}}'                                   > "$CT/dep-clean.json"
echo '{"Report":{"Violations":4}}'                                   > "$CT/dep-viol.json"
echo '{"violations":[{"a":1},{"b":2},{"c":3}]}'                      > "$CT/dep-arr.json"
echo '{"tool":"architecture","status":"findings","violations":2,"rule_count":12,"context_count":4,"failures":[]}' > "$CT/norm.json"
echo '{"tool":"architecture","status":"unavailable","violations":0}'    > "$CT/unavail.json"
echo '{"tool":"architecture","status":"not-configured","violations":0}' > "$CT/notcfg.json"
echo '{"tool":"architecture","status":"execution-error","violations":0}' > "$CT/execerr.json"
echo '{"tool":"architecture","status":"disabled","violations":0}'       > "$CT/disabled.json"
echo '{"tool":"architecture","status":"totally-made-up","violations":9}' > "$CT/unknown-status.json"
echo '{"some":"other","shape":true}'                                 > "$CT/unknown-shape.json"
echo 'not json {'                                                    > "$CT/bad.json"

# cv <input> <jq-filter> — run the deptrac collector over <input> and read one field.
cv() { sh "$COLL/deptrac.sh" --input "$1" 2>/dev/null | jq -r "$2"; }
[ "$(cv "$CT/dep-clean.json" '.summary.architecture_violations')" = "0" ] \
	&& [ "$(cv "$CT/dep-clean.json" '.status')" = "pass" ] \
	&& pass "deptrac collector: native clean report -> pass, 0 violations" || fail "deptrac native clean wrong"
[ "$(cv "$CT/dep-viol.json" '.summary.architecture_violations')" = "4" ] \
	&& [ "$(cv "$CT/dep-viol.json" '.status')" = "fail" ] \
	&& pass "deptrac collector: native violation report -> fail, 4 violations" || fail "deptrac native violations wrong"
[ "$(cv "$CT/dep-arr.json" '.summary.architecture_violations')" = "3" ] \
	&& pass "deptrac collector: violations array -> length" || fail "deptrac violations array wrong"
o=$(sh "$COLL/deptrac.sh" --input "$CT/norm.json")
if [ "$(printf '%s' "$o" | jq -r '.summary.architecture_violations')" = "2" ] \
	&& [ "$(printf '%s' "$o" | jq -r '.summary.architecture_rule_count')" = "12" ] \
	&& [ "$(printf '%s' "$o" | jq -r '.summary.architecture_context_count')" = "4" ] \
	&& [ "$(printf '%s' "$o" | jq -r '.summary.architecture_tool_count')" = "1" ]; then
	pass "deptrac collector: normalized architecture shape (violations + rule/context/tool metadata)"
else
	fail "deptrac normalized mapping wrong: $(printf '%s' "$o" | jq -c .summary)"
fi
_status_ok=1
for s in unavailable not-configured execution-error disabled; do
	case "$s" in
		unavailable) f="$CT/unavail.json" ;;
		not-configured) f="$CT/notcfg.json" ;;
		execution-error) f="$CT/execerr.json" ;;
		disabled) f="$CT/disabled.json" ;;
	esac
	got=$(cv "$f" '.status')
	[ "$got" = "$s" ] || { fail "deptrac collector: status '$s' not preserved (got '$got')"; _status_ok=0; }
done
[ "$_status_ok" = 1 ] && pass "deptrac collector: unavailable / not-configured / execution-error / disabled preserved"
# a non-evidence status must NOT credit architecture_tool_count (no evidence was produced)
[ "$(cv "$CT/unavail.json" '.summary.architecture_tool_count // 0')" = "0" ] \
	&& pass "deptrac collector: unavailable contributes no evidence (tool_count 0)" \
	|| fail "unavailable should not count as an evidence-producing tool"
[ "$(cv "$CT/unknown-status.json" '.status')" = "execution-error" ] \
	&& [ "$(cv "$CT/unknown-status.json" '.summary.architecture_violations')" = "0" ] \
	&& pass "deptrac collector: unknown status -> execution-error (fail closed)" || fail "unknown status not failing closed"
[ "$(cv "$CT/unknown-shape.json" '.status')" = "execution-error" ] \
	&& pass "deptrac collector: unknown native shape -> execution-error (never a clean pass)" || fail "unknown shape not failing closed"
# A RECOGNIZED shape whose count is malformed/negative/fractional is not evidence either: it must
# fail closed rather than be coerced to a clean 0 (which would also wrongly credit tool_count).
echo '{"report":{"violations":-3}}' > "$CT/neg.json"
echo '{"tool":"architecture","status":"findings","violations":2.5}' > "$CT/frac.json"
echo '{"tool":"architecture","status":"findings","violations":"many"}' > "$CT/nan.json"
_badcount=0
for _f in neg frac nan; do
	_st=$(cv "$CT/$_f.json" '.status')
	_tc=$(cv "$CT/$_f.json" '.summary.architecture_tool_count // 0')
	{ [ "$_st" = "execution-error" ] && [ "$_tc" = "0" ]; } || { _badcount=1; echo "  ($_f got status=$_st tool_count=$_tc)"; }
done
[ "$_badcount" -eq 0 ] \
	&& pass "collectors: negative / fractional / non-numeric violation counts -> execution-error (never coerced to 0)" \
	|| fail "a malformed violation count was coerced instead of failing closed"
rc=0; sh "$COLL/deptrac.sh" --input "$CT/bad.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "deptrac collector: invalid JSON -> exit 2" || fail "deptrac invalid JSON got exit $rc"
[ "$(cv "$CT/nope.json" '.status')" = "unavailable" ] \
	&& pass "deptrac collector: missing report -> unavailable" || fail "deptrac missing report wrong"
: > "$CT/empty.json"
[ "$(cv "$CT/empty.json" '.status')" = "unavailable" ] \
	&& pass "deptrac collector: empty report -> unavailable" || fail "deptrac empty report wrong"

# --- (3) collector: dependency-cruiser ---------------------------------------
cat > "$CT/dc-viol.json" <<'EOF'
{ "summary": { "violations": [
    {"from":"src/domain/order.ts","to":"src/infrastructure/db.ts","rule":{"name":"no-domain-to-infra","severity":"error"}},
    {"from":"src/domain/user.ts","to":"src/infrastructure/http.ts","rule":{"name":"no-domain-to-infra","severity":"error"}}
  ], "error": 2, "warn": 0, "ruleSetUsed": { "forbidden": [1,2,3,4] } } }
EOF
echo '{"summary":{"violations":[],"error":0,"ruleSetUsed":{"forbidden":[1,2]}}}' > "$CT/dc-clean.json"
echo '{"modules":[{"source":"a.ts"}]}' > "$CT/dc-unknown.json"
# dcv <input> <jq-filter> — run the dependency-cruiser collector and read one field.
dcv() { sh "$COLL/dependency-cruiser.sh" --input "$1" 2>/dev/null | jq -r "$2"; }
[ "$(dcv "$CT/dc-viol.json" '.summary.architecture_violations')" = "2" ] \
	&& [ "$(dcv "$CT/dc-viol.json" '.status')" = "fail" ] \
	&& [ "$(dcv "$CT/dc-viol.json" '.summary.architecture_rule_count')" = "4" ] \
	&& pass "dependency-cruiser collector: native violations -> architecture_violations (+rule_count)" \
	|| fail "dependency-cruiser native violation mapping wrong"
[ "$(dcv "$CT/dc-clean.json" '.status')" = "pass" ] \
	&& pass "dependency-cruiser collector: clean native report -> pass" || fail "dependency-cruiser clean wrong"
[ "$(dcv "$CT/dc-unknown.json" '.status')" = "execution-error" ] \
	&& pass "dependency-cruiser collector: unknown shape -> execution-error" || fail "dependency-cruiser unknown shape not failing closed"
[ "$(dcv "$CT/unavail.json" '.status')" = "unavailable" ] \
	&& pass "dependency-cruiser collector: unavailable preserved" || fail "dependency-cruiser status not preserved"

# --- (4) collector: eslint-boundaries counts ONLY architecture rules ----------
cat > "$CT/es-mixed.json" <<'EOF'
[
  {"filePath":"src/features/a/index.ts","messages":[
    {"ruleId":"boundaries/element-types","message":"feature -> feature"},
    {"ruleId":"no-unused-vars","message":"noise"},
    {"ruleId":"semi","message":"noise"},
    {"ruleId":"import/no-restricted-paths","message":"shared -> feature"}
  ]},
  {"filePath":"src/shared/b.ts","messages":[
    {"ruleId":"no-console","message":"noise"},
    {"ruleId":"boundaries/no-private","message":"private import"}
  ]}
]
EOF
echo '[{"filePath":"a.ts","messages":[{"ruleId":"no-unused-vars"}]}]' > "$CT/es-noise.json"
echo '[]' > "$CT/es-empty.json"
echo '{"not":"eslint"}' > "$CT/es-unknown.json"
# ebv <input> <jq-filter> — run the eslint-boundaries collector and read one field.
ebv() { sh "$COLL/eslint-boundaries.sh" --input "$1" 2>/dev/null | jq -r "$2"; }
[ "$(ebv "$CT/es-mixed.json" '.summary.architecture_violations')" = "3" ] \
	&& pass "eslint-boundaries collector: counts ONLY boundary rules (3 of 6 messages)" \
	|| fail "eslint-boundaries counted the wrong messages: $(ebv "$CT/es-mixed.json" '.summary.architecture_violations')"
[ "$(ebv "$CT/es-noise.json" '.summary.architecture_violations')" = "0" ] \
	&& [ "$(ebv "$CT/es-noise.json" '.status')" = "pass" ] \
	&& pass "eslint-boundaries collector: general ESLint findings are NOT architecture violations" \
	|| fail "eslint-boundaries counted general lint findings"
[ "$(ebv "$CT/es-empty.json" '.status')" = "pass" ] \
	&& pass "eslint-boundaries collector: empty ESLint result -> pass" || fail "eslint-boundaries empty result wrong"
[ "$(ebv "$CT/es-unknown.json" '.status')" = "execution-error" ] \
	&& pass "eslint-boundaries collector: unknown shape -> execution-error" || fail "eslint-boundaries unknown shape not failing closed"

# --- (5) collectors: custom architecture-test contracts (PHP + JS) -----------
cat > "$CT/js-arch.json" <<'EOF'
{ "tool":"architecture", "status":"findings", "violations":2, "rule_count":7, "context_count":3,
  "failures":[ {"rule":"feature-isolation","from":"src/features/cart","to":"src/features/checkout","message":"cross-feature import"} ] }
EOF
[ "$(sh "$COLL/js-architecture-tests.sh" --input "$CT/js-arch.json" | jq -r '.summary.architecture_violations')" = "2" ] \
	&& pass "js-architecture-tests collector: custom contract mapped" || fail "js-architecture-tests contract mapping wrong"
[ "$(sh "$COLL/php-arkitect.sh" --input "$CT/norm.json" | jq -r '.summary.architecture_violations')" = "2" ] \
	&& pass "php-arkitect collector: normalized contract mapped" || fail "php-arkitect contract mapping wrong"
# legacy architecture-tests report (pre-v2.1.0 shape) still works
echo '{"violations":2}' > "$CT/legacy.json"
[ "$(sh "$COLL/architecture-tests.sh" --input "$CT/legacy.json" | jq -r '.summary.architecture_violations')" = "2" ] \
	&& pass "architecture-tests collector: legacy {violations:N} shape still mapped (back-compat)" \
	|| fail "legacy architecture-tests shape broke"
# failures[] alone is enough evidence
echo '{"tool":"architecture","status":"findings","failures":[{"rule":"r1"},{"rule":"r2"}]}' > "$CT/fails.json"
[ "$(sh "$COLL/architecture-tests.sh" --input "$CT/fails.json" | jq -r '.summary.architecture_violations')" = "2" ] \
	&& pass "architecture collector: failures[] length counts when violations absent" || fail "failures[] not counted"

# --- (6) runners: honest statuses without the tools installed -----------------
RT="$WORK/runner"; mkdir -p "$RT/reports/raw"
( cd "$RT" && sh "$RUNNERS/js-architecture-tests.sh" >/dev/null 2>&1 )
[ "$(jq -r '.status' "$RT/reports/raw/js-architecture-tests.json")" = "unavailable" ] \
	&& pass "js-architecture-tests runner: no command -> unavailable (never a faked pass)" \
	|| fail "js-architecture-tests runner should report unavailable"
echo '{"tool":"architecture","status":"findings","violations":1,"rule_count":4,"failures":[]}' > "$RT/contract.json"
( cd "$RT" && SENTINEL_SHIELD_JS_ARCH_TEST_CMD="cat $RT/contract.json" \
	sh "$RUNNERS/js-architecture-tests.sh" >/dev/null 2>&1 )
[ "$(jq -r '.violations' "$RT/reports/raw/js-architecture-tests.json")" = "1" ] \
	&& pass "js-architecture-tests runner: stdout JSON contract normalized" \
	|| fail "js-architecture-tests runner did not accept stdout contract"
rm -f "$RT/reports/raw/js-architecture-tests.json"
( cd "$RT" && SENTINEL_SHIELD_JS_ARCH_TEST_CMD='exit 3' sh "$RUNNERS/js-architecture-tests.sh" >/dev/null 2>&1 )
[ "$(jq -r '.status' "$RT/reports/raw/js-architecture-tests.json")" = "execution-error" ] \
	&& pass "js-architecture-tests runner: failing command without JSON -> execution-error" \
	|| fail "js-architecture-tests runner should report execution-error"
( cd "$RT" && sh "$RUNNERS/deptrac.sh" >/dev/null 2>&1 )
dst=$(jq -r '.status' "$RT/reports/raw/deptrac.json")
{ [ "$dst" = "unavailable" ] || [ "$dst" = "not-configured" ]; } \
	&& pass "deptrac runner: no binary/config -> honest '$dst' (never violations:0)" \
	|| fail "deptrac runner emitted '$dst'"
[ "$(jq -r '.violations' "$RT/reports/raw/deptrac.json")" = "0" ] \
	&& [ "$(sh "$COLL/deptrac.sh" --input "$RT/reports/raw/deptrac.json" | jq -r '.summary.architecture_tool_count // 0')" = "0" ] \
	&& pass "deptrac runner: honest status yields NO architecture evidence downstream" \
	|| fail "deptrac runner status leaked into evidence"

# --- (7) builder: cross-producer aggregation ---------------------------------
RAW="$WORK/build/reports/raw"; mkdir -p "$RAW"
echo '{"report":{"violations":3}}' > "$RAW/deptrac.json"
echo '{"summary":{"violations":[{"a":1},{"b":2}],"ruleSetUsed":{"forbidden":[1,2]}}}' > "$RAW/dependency-cruiser.json"
echo '{"tool":"architecture","status":"findings","violations":1,"rule_count":5,"context_count":4}' > "$RAW/js-architecture-tests.json"
echo '{"tool":"architecture","status":"pass","violations":0,"rule_count":3,"context_count":2}' > "$RAW/php-arkitect.json"
sh "$BUILD" --raw-dir "$RAW" --output "$WORK/build/summary.json" >/dev/null 2>&1
S="$WORK/build/summary.json"
[ "$(jq -r '.summary.architecture_violations' "$S")" = "6" ] \
	&& pass "builder: architecture_violations summed across producers (3+2+1+0=6)" \
	|| fail "builder architecture sum got $(jq -r '.summary.architecture_violations' "$S")"
[ "$(jq -r '.summary.architecture_tool_count' "$S")" = "4" ] \
	&& pass "builder: architecture_tool_count = producers with valid evidence (4)" \
	|| fail "builder tool_count got $(jq -r '.summary.architecture_tool_count' "$S")"
[ "$(jq -r '.summary.architecture_rule_count' "$S")" = "10" ] \
	&& pass "builder: architecture_rule_count summed (0+2+5+3=10)" \
	|| fail "builder rule_count got $(jq -r '.summary.architecture_rule_count' "$S")"
[ "$(jq -r '.summary.architecture_context_count' "$S")" = "4" ] \
	&& pass "builder: architecture_context_count = MAX across producers (same codebase, no double count)" \
	|| fail "builder context_count got $(jq -r '.summary.architecture_context_count' "$S")"
if [ "$(jq -r '.summary.secrets' "$S")" = "0" ] \
	&& [ "$(jq -r '.summary.critical_vulnerabilities' "$S")" = "0" ] \
	&& [ "$(jq -r '.summary.high_vulnerabilities' "$S")" = "0" ] \
	&& [ "$(jq -r '.summary.medium_vulnerabilities' "$S")" = "0" ]; then
	pass "builder: architecture findings NOT folded into security counters"
else
	fail "builder mixed architecture into security counters"
fi
# a non-evidence producer contributes nothing but also never zeroes the others
echo '{"tool":"architecture","status":"execution-error","violations":0}' > "$RAW/eslint-boundaries.json"
sh "$BUILD" --raw-dir "$RAW" --output "$S" >/dev/null 2>&1
[ "$(jq -r '.summary.architecture_violations' "$S")" = "6" ] && [ "$(jq -r '.summary.architecture_tool_count' "$S")" = "4" ] \
	&& pass "builder: execution-error producer adds no evidence and no violations" \
	|| fail "builder mishandled an execution-error producer"

# --- (8) enforcer: violations + missing evidence ------------------------------
for m in report-only baseline strict regulated; do
	sh "$RESOLVE" --mode "$m" --output-dir "$WORK/enf-$m" --format env >/dev/null 2>&1
done
mkav() { # mkav <file> <violations> <missing_architecture_evidence>
	jq -n --argjson v "$2" --argjson mae "$3" '
		{ version:"1.0", project:{name:"t",type:"php",criticality:"medium"},
		  generated_at:"2026-07-18T00:00:00Z",
		  summary:{ secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
		            medium_vulnerabilities:0, architecture_violations:$v, type_errors:0,
		            test_failures:0, unsafe_docker:0, unsafe_github_actions:0,
		            missing_sbom:false, missing_release_evidence:false, expired_exceptions:0,
		            missing_architecture_evidence:$mae },
		  tools:{}, exceptions:{active:0,expired:0},
		  evidence:{ sbom:{present:true,path:"x"}, release_evidence:{present:true,path:"y"} } }' > "$1"
}
mkav "$WORK/av.json" 2 false
mkav "$WORK/mae.json" 0 true
mkav "$WORK/clean.json" 0 false

enf() { # enf <mode> <summary> -> exit code, enforcement json in $WORK/out-<mode>
	rc=0
	sh "$ENFORCE" --gates-env "$WORK/enf-$1/sentinel-shield-gates.env" --summary "$2" \
		--output-dir "$WORK/out-$1" --format json >/dev/null 2>&1 || rc=$?
	printf '%s' "$rc"
}
# failed_has <mode> <gate> — non-null when <gate> is in that mode's failed_gates list.
failed_has() { jq -r --arg g "$2" '(.failed_gates // []) | index($g)' "$WORK/out-$1/sentinel-shield-enforcement.json"; }

[ "$(enf report-only "$WORK/av.json")" = "0" ] \
	&& pass "enforcer(report-only): architecture_violations does not block" || fail "report-only should not block on architecture_violations"
rc=$(enf baseline "$WORK/av.json")
[ "$rc" = "1" ] && [ "$(failed_has baseline architecture_violations)" != "null" ] \
	&& pass "enforcer(baseline): architecture_violations=2 blocks" || fail "baseline should block on architecture_violations (rc=$rc)"
rc=$(enf strict "$WORK/av.json")
[ "$rc" = "1" ] && pass "enforcer(strict): architecture_violations blocks" || fail "strict should block on architecture_violations"
rc=$(enf regulated "$WORK/av.json")
[ "$rc" = "1" ] && pass "enforcer(regulated): architecture_violations blocks" || fail "regulated should block on architecture_violations"

[ "$(enf baseline "$WORK/mae.json")" = "0" ] \
	&& pass "enforcer(baseline): missing_architecture_evidence does NOT block yet (adoption ramp)" \
	|| fail "baseline should not block on missing architecture evidence"
rc=$(enf strict "$WORK/mae.json")
[ "$rc" = "1" ] && [ "$(failed_has strict missing_architecture_evidence)" != "null" ] \
	&& pass "enforcer(strict): missing_architecture_evidence=true blocks (absent evidence fails)" \
	|| fail "strict should block on missing_architecture_evidence (rc=$rc, failed=$(jq -c '.failed_gates' "$WORK/out-strict/sentinel-shield-enforcement.json"))"
rc=$(enf regulated "$WORK/mae.json")
[ "$rc" = "1" ] && [ "$(failed_has regulated missing_architecture_evidence)" != "null" ] \
	&& pass "enforcer(regulated): missing_architecture_evidence=true blocks" \
	|| fail "regulated should block on missing_architecture_evidence"
[ "$(enf regulated "$WORK/clean.json")" = "0" ] \
	&& pass "enforcer(regulated): clean architecture evidence passes" || fail "clean summary should pass in regulated"
# an OLD summary that omits the key entirely must stay valid (additive, back-compat)
jq 'del(.summary.missing_architecture_evidence)' "$WORK/clean.json" > "$WORK/old.json"
[ "$(enf strict "$WORK/old.json")" = "0" ] \
	&& pass "enforcer(strict): summary without the new key still passes (absent reads as false)" \
	|| fail "older summary without missing_architecture_evidence must not fail"

# --- (9) profile-aware missing architecture evidence --------------------------
if command -v php >/dev/null 2>&1; then
	MT="$WORK/archproj"; mkdir -p "$MT/reports/raw"
	printf '{"name":"x/y"}\n' > "$MT/composer.json"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_architecture_evidence' "$MT/s.json")" = "true" ] \
		&& pass "builder: missing_architecture_evidence=true when an applicable producer has no report" \
		|| fail "builder should flag missing architecture evidence"
	echo '{"tool":"architecture","status":"unavailable","violations":0}' > "$MT/reports/raw/deptrac.json"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_architecture_evidence' "$MT/s.json")" = "true" ] \
		&& pass "builder: an 'unavailable' report is still MISSING evidence (honest absence)" \
		|| fail "unavailable report must not count as evidence"
	echo '{"report":{"violations":0}}' > "$MT/reports/raw/deptrac.json"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_architecture_evidence' "$MT/s.json")" = "false" ] \
		&& pass "builder: missing_architecture_evidence=false once a producer emits real evidence" \
		|| fail "builder should clear missing architecture evidence"
	# --- BUILDER-level fail-closed: the evidence gate must follow the COLLECTOR status, not the
	# raw file. A report that is present and valid JSON but that the collector could not read
	# (unknown shape / unknown status / malformed count) is NOT evidence — re-parsing the raw file
	# here would silently overrule the collector and let strict/regulated pass on garbage.
	barch() { # barch <raw-json> -> "<tools.deptrac.status>|<missing_architecture_evidence>|<tool_count>|<violations>"
		printf '%s' "$1" > "$MT/reports/raw/deptrac.json"
		( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
		jq -r '[ (.tools.deptrac.status // ""), (.summary.missing_architecture_evidence | tostring),
		         (.summary.architecture_tool_count | tostring), (.summary.architecture_violations | tostring) ] | join("|")' "$MT/s.json"
	}
	# Test 1 — unknown Deptrac/native shape
	[ "$(barch '{"some":"other","shape":true}')" = "execution-error|true|0|0" ] \
		&& pass "builder: unknown Deptrac shape -> tools.deptrac=execution-error + missing evidence" \
		|| fail "builder accepted an unknown-shape report as evidence: $(barch '{"some":"other","shape":true}')"
	# Test 2 — unknown status
	[ "$(barch '{"tool":"architecture","status":"totally-made-up","violations":9}')" = "execution-error|true|0|0" ] \
		&& pass "builder: unknown architecture status -> execution-error + missing evidence" \
		|| fail "builder accepted an unknown status as evidence"
	# Test 3 — malformed violation counts (negative / fractional / non-numeric)
	_bad=0
	for _r in '{"report":{"violations":-3}}' \
	          '{"tool":"architecture","status":"findings","violations":2.5}' \
	          '{"tool":"architecture","status":"findings","violations":"many"}'; do
		_got=$(barch "$_r")
		[ "$_got" = "execution-error|true|0|0" ] || { _bad=1; echo "  ($_r -> $_got)"; }
	done
	[ "$_bad" -eq 0 ] \
		&& pass "builder: negative/fractional/non-numeric counts -> execution-error, missing evidence, tool_count 0" \
		|| fail "builder treated a malformed violation count as evidence"
	# Test 4 — valid violating evidence still counts (fail/findings are both evidence)
	_got=$(barch '{"report":{"violations":2}}')
	case "$_got" in
		findings\|false\|1\|2 | fail\|false\|1\|2) pass "builder: valid violating report is evidence (status=${_got%%|*}, violations=2)" ;;
		*) fail "builder mishandled valid violating evidence: $_got" ;;
	esac
	# Test 5 — valid clean evidence still counts
	[ "$(barch '{"report":{"violations":0}}')" = "pass|false|1|0" ] \
		&& pass "builder: valid clean report is evidence (status=pass, 0 violations)" \
		|| fail "builder mishandled valid clean evidence: $(barch '{"report":{"violations":0}}')"

	# policy opt-out is honest and explicit
	mkdir -p "$MT/.sentinel-shield"; rm -f "$MT/reports/raw/deptrac.json"
	printf 'architecture:\n  enabled: false\n' > "$MT/.sentinel-shield/architecture-policy.yaml"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_architecture_evidence' "$MT/s.json")" = "false" ] \
		&& pass "builder: architecture.enabled=false opts out of the evidence requirement" \
		|| fail "policy opt-out not honored"
	printf 'architecture:\n  enabled: true\n  evidence_required: false\n' > "$MT/.sentinel-shield/architecture-policy.yaml"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_architecture_evidence' "$MT/s.json")" = "false" ] \
		&& pass "builder: evidence_required=false opts out of the evidence requirement" \
		|| fail "evidence_required=false not honored"
else
	fail "profile-aware architecture evidence: php REQUIRED but not available"
fi

# --- (10) combined PHP+JS profile independence -------------------------------
if command -v php >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
	C="$WORK/combo"; CR="$C/reports/raw"; mkdir -p "$CR"
	printf '{"name":"x/y"}\n' > "$C/composer.json"
	printf '{"name":"x","private":true}\n' > "$C/package.json"
	bmae() { ( cd "$C" && sh "$BUILD" --profile laravel-react-docker --target "$C" --raw-dir "$CR" --output "$C/s.json" ) >/dev/null 2>&1; jq -r '.summary.missing_architecture_evidence' "$C/s.json"; }
	echo '{"report":{"violations":1}}' > "$CR/deptrac.json"
	[ "$(bmae)" = "true" ] \
		&& pass "combined profile: PHP architecture evidence alone does not satisfy the JS producers" \
		|| fail "combined profile: JS architecture evidence should still be missing"
	# A JS report that is present and valid JSON but UNREADABLE by its collector is not evidence:
	# valid PHP evidence must not paper over it, and the builder must follow the collector status.
	echo '{"totally":"unknown"}' > "$CR/dependency-cruiser.json"
	echo '{"tool":"architecture","status":"pass","violations":0}' > "$CR/eslint-boundaries.json"
	_cm=$(bmae)
	_cd=$(jq -r '.tools.dependency_cruiser.status' "$C/s.json")
	_cp=$(jq -r '.tools.deptrac.status' "$C/s.json")
	{ [ "$_cm" = "true" ] && [ "$_cd" = "execution-error" ] && [ "$_cp" != "execution-error" ]; } \
		&& pass "combined profile: unknown-shape JS report -> execution-error + missing evidence (valid PHP evidence does not mask it)" \
		|| fail "combined profile mishandled an unreadable JS report (missing=$_cm depcruise=$_cd deptrac=$_cp)"
	echo '{"summary":{"violations":[],"ruleSetUsed":{"forbidden":[1]}}}' > "$CR/dependency-cruiser.json"
	[ "$(bmae)" = "false" ] \
		&& pass "combined profile: PHP + JS producers together satisfy architecture evidence" \
		|| fail "combined profile should be satisfied once both stacks report"
	( cd "$C" && sh "$BUILD" --profile laravel-react-docker --target "$C" --raw-dir "$CR" --output "$C/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.architecture_violations' "$C/s.json")" = "1" ] \
		&& pass "combined profile: violations summed across PHP and JS producers" \
		|| fail "combined profile violation sum wrong"
else
	fail "combined-profile architecture independence: php and node REQUIRED but not both available"
fi

# --- (11) architecture-policy loader -----------------------------------------
cat > "$WORK/ap-harness.sh" <<EOF
set -eu
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/architecture-policy.sh"
ap_load "\$1"
echo "enabled=\$(ap_bool architecture.enabled true) style=\$(ap_get architecture.style) deptrac=\$(ap_bool architecture.tools.deptrac.enabled true)"
EOF
# absent policy -> defaults, exit 0
rc=0; out=$(sh "$WORK/ap-harness.sh" "$WORK/none.yaml" 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "enabled=true style= deptrac=true" ] \
	&& pass "architecture-policy: absent file defaults safely" || fail "absent policy should default (rc=$rc out=$out)"
# valid policy parses
cat > "$WORK/ap-ok.yaml" <<'EOF'
architecture:
  enabled: true
  style: clean-architecture
  evidence_required: true
  bounded_contexts:
    enabled: true
    paths:
      - src
      - app
  tools:
    deptrac:
      enabled: false
      config: deptrac.yaml
EOF
rc=0; out=$(sh "$WORK/ap-harness.sh" "$WORK/ap-ok.yaml" 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "enabled=true style=clean-architecture deptrac=false" ] \
	&& pass "architecture-policy: canonical YAML parsed without yq" || fail "valid policy misparsed (rc=$rc out=$out)"
# present-but-empty known boolean -> fail closed
printf 'architecture:\n  enabled:\n' > "$WORK/ap-empty-bool.yaml"
rc=0; sh "$WORK/ap-harness.sh" "$WORK/ap-empty-bool.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "architecture-policy: empty known boolean fails closed (exit 2)" || fail "empty boolean should exit 2, got $rc"
# present-but-empty known scalar -> fail closed
printf 'architecture:\n  style:\n' > "$WORK/ap-empty-scalar.yaml"
rc=0; sh "$WORK/ap-harness.sh" "$WORK/ap-empty-scalar.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "architecture-policy: empty known scalar fails closed (exit 2)" || fail "empty scalar should exit 2, got $rc"
# malformed boolean -> fail closed
_apbad=0
for _v in maybe 2 yesno ''; do
	[ -n "$_v" ] || continue
	printf 'architecture:\n  tools:\n    deptrac:\n      enabled: %s\n' "$_v" > "$WORK/ap-bad.yaml"
	rc=0; sh "$WORK/ap-harness.sh" "$WORK/ap-bad.yaml" >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 2 ] || { _apbad=1; echo "  (enabled='$_v' got exit $rc, expected 2)"; }
done
[ "$_apbad" -eq 0 ] && pass "architecture-policy: non-boolean tool flag fails closed" || fail "architecture-policy accepted a non-boolean"
# tabs / advanced YAML need real yq -> fail closed without it
printf 'architecture:\n\tenabled: true\n' > "$WORK/ap-tab.yaml"
# Tabs are invalid YAML indentation in BOTH parser paths, so the expected result is exit 2
# either way — with yq it is rejected as malformed YAML, without yq by the explicit tab check.
rc=0; sh "$WORK/ap-harness.sh" "$WORK/ap-tab.yaml" >/dev/null 2>&1 || rc=$?
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
	[ "$rc" -eq 2 ] && pass "architecture-policy: tab indentation fails closed with mikefarah yq (exit 2)" \
		|| fail "tab YAML should exit 2 with yq installed, got $rc"
else
	[ "$rc" -eq 2 ] && pass "architecture-policy: tab indentation fails closed without yq (exit 2)" \
		|| fail "tab YAML should exit 2, got $rc"
fi

# --- (12) template + schema wiring -------------------------------------------
[ -f "$ROOT/templates/architecture-policy.example.yaml" ] \
	&& pass "template: templates/architecture-policy.example.yaml present" || fail "architecture-policy template missing"
for k in missing_architecture_evidence architecture_rule_count architecture_tool_count architecture_context_count; do
	jq -e --arg k "$k" '.properties.summary.properties | has($k)' "$ROOT/schemas/security-summary.schema.json" >/dev/null 2>&1 \
		|| fail "schema: summary key '$k' missing from security-summary.schema.json"
done
pass "schema: all four new architecture summary keys declared"
# every architecture producer declared by a profile has a runner + collector on disk
_missing=""
for _r in deptrac php-arkitect php-architecture-tests dependency-cruiser eslint-boundaries js-architecture-tests architecture-tests; do
	[ -f "$ROOT/scripts/runners/$_r.sh" ] || _missing="$_missing runner:$_r"
done
for _c in deptrac php-arkitect php-architecture-tests dependency-cruiser eslint-boundaries js-architecture-tests architecture-tests architecture; do
	[ -f "$ROOT/scripts/collectors/$_c.sh" ] || _missing="$_missing collector:$_c"
done
[ -z "$_missing" ] && pass "all architecture runners + collectors present" || fail "missing:$_missing"

if [ "$FAILED" -eq 0 ]; then
	printf '\n280-architecture-governance: ALL CHECKS PASSED\n'
else
	printf '\n280-architecture-governance: FAILURES PRESENT\n'
fi
exit "$FAILED"
