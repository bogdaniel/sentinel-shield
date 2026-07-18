#!/bin/sh
# Sentinel Shield prod test — engineering quality gates (v2.1).
#
# Covers the full quality-gate feature: resolver mode defaults + overrides, the five
# collectors, the builder's quality aggregation (PHP + JS coverage: summed violations,
# min percentages, clamped regression; quality counters never mixed with vuln counters),
# the enforcer (enable/disable/strict/regulated/override), the quality-policy loader's
# fail-closed behavior, and the Istanbul/Clover coverage adapters.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss270)
trap 'rm -rf -- "$WORK"' EXIT INT TERM

RESOLVE="$ROOT/scripts/resolve-gates.sh"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"
COLL="$ROOT/scripts/collectors"

QUALITY_GATES="coverage_threshold_violations coverage_regression mutation_score_violations complexity_violations duplication_violations dead_code_violations"

# --- (1) resolver mode defaults ----------------------------------------------
gate_val() { # gate_val <env-file> <GATE_KEY_UPPER>
	awk -F= -v k="SENTINEL_SHIELD_FAIL_ON_$2" '$1==k{print $2; exit}' "$1"
}
for m in report-only baseline strict regulated; do
	od="$WORK/mode-$m"; sh "$RESOLVE" --mode "$m" --output-dir "$od" --format env >/dev/null 2>&1
	envf="$od/sentinel-shield-gates.env"
	case "$m" in
		report-only|baseline)
			_bad=""
			for g in COVERAGE_THRESHOLD_VIOLATIONS COVERAGE_REGRESSION MUTATION_SCORE_VIOLATIONS COMPLEXITY_VIOLATIONS DUPLICATION_VIOLATIONS DEAD_CODE_VIOLATIONS; do
				[ "$(gate_val "$envf" "$g")" = "false" ] || _bad="$_bad $g"
			done
			[ -z "$_bad" ] && pass "$m: all quality gates default false" || fail "$m: expected false:$_bad" ;;
		strict)
			ok=1
			for g in COVERAGE_THRESHOLD_VIOLATIONS COVERAGE_REGRESSION COMPLEXITY_VIOLATIONS DUPLICATION_VIOLATIONS; do
				[ "$(gate_val "$envf" "$g")" = "true" ] || ok=0
			done
			for g in MUTATION_SCORE_VIOLATIONS DEAD_CODE_VIOLATIONS; do
				[ "$(gate_val "$envf" "$g")" = "false" ] || ok=0
			done
			[ "$ok" -eq 1 ] && pass "strict: coverage/complexity/duplication on, mutation/dead-code off" || fail "strict: wrong quality defaults" ;;
		regulated)
			ok=1
			for g in COVERAGE_THRESHOLD_VIOLATIONS COVERAGE_REGRESSION MUTATION_SCORE_VIOLATIONS COMPLEXITY_VIOLATIONS DUPLICATION_VIOLATIONS DEAD_CODE_VIOLATIONS; do
				[ "$(gate_val "$envf" "$g")" = "true" ] || ok=0
			done
			[ "$ok" -eq 1 ] && pass "regulated: all quality gates on" || fail "regulated: wrong quality defaults" ;;
	esac
done

# --- (2) resolver overrides ---------------------------------------------------
mkdir -p "$WORK/proj/.sentinel-shield"
cat > "$WORK/proj/.sentinel-shield/profile.yaml" <<'EOF'
project:
  name: demo
gates:
  mode: strict
  fail_on:
    coverage_threshold_violations: false
    mutation_score_violations: true
EOF
sh "$RESOLVE" --profile "$WORK/proj/.sentinel-shield/profile.yaml" --output-dir "$WORK/ovr" --format env >/dev/null 2>&1
envf="$WORK/ovr/sentinel-shield-gates.env"
if [ "$(gate_val "$envf" COVERAGE_THRESHOLD_VIOLATIONS)" = "false" ] && [ "$(gate_val "$envf" MUTATION_SCORE_VIOLATIONS)" = "true" ]; then
	pass "explicit overrides applied (coverage off, mutation on in strict)"
else
	fail "explicit overrides not applied"
fi
# invalid non-boolean override fails closed (exit 2)
cat > "$WORK/proj/.sentinel-shield/bad.yaml" <<'EOF'
gates:
  mode: strict
  fail_on:
    complexity_violations: maybe
EOF
rc=0; sh "$RESOLVE" --profile "$WORK/proj/.sentinel-shield/bad.yaml" --output-dir "$WORK/bad" --format env >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "invalid boolean override fails closed (exit 2)" || fail "invalid override should exit 2, got $rc"

# --- (3) collectors -----------------------------------------------------------
CT="$WORK/coll"; mkdir -p "$CT"
echo '{"tool":"coverage","status":"pass","line_percent":90,"branch_percent":80,"violations":0,"regression":false}' > "$CT/clean.json"
echo '{"tool":"coverage","status":"findings","line_percent":50,"violations":3,"regression":true}' > "$CT/viol.json"
echo '{"tool":"coverage","violations":"NaN","line_percent":"x"}' > "$CT/nonnum.json"
echo 'not json {' > "$CT/bad.json"
echo '{"tool":"coverage","status":"weird","violations":1}' > "$CT/malstatus.json"

v=$(sh "$COLL/coverage.sh" --input "$CT/clean.json" | jq '.summary.coverage_threshold_violations')
[ "$v" = "0" ] && pass "coverage collector: clean -> 0 violations" || fail "coverage clean got $v"
o=$(sh "$COLL/coverage.sh" --input "$CT/viol.json")
if [ "$(echo "$o" | jq '.summary.coverage_threshold_violations')" = "3" ] && [ "$(echo "$o" | jq '.summary.coverage_regression')" = "1" ]; then
	pass "coverage collector: violations=3, regression=1"
else fail "coverage violation mapping wrong"; fi
v=$(sh "$COLL/coverage.sh" --input "$CT/nonnum.json" | jq '.summary.coverage_threshold_violations,.summary.coverage_line_percent' | tr '\n' ' ')
[ "$v" = "0 0 " ] && pass "coverage collector: non-numeric -> 0" || fail "coverage non-numeric got '$v'"
rc=0; sh "$COLL/coverage.sh" --input "$CT/bad.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "coverage collector: invalid JSON -> exit 2" || fail "coverage invalid json got $rc"
st=$(sh "$COLL/coverage.sh" --input "$CT/missing.json" 2>/dev/null | jq -r '.status')
[ "$st" = "unavailable" ] && pass "coverage collector: missing -> unavailable" || fail "coverage missing got $st"
st=$(sh "$COLL/coverage.sh" --input "$CT/malstatus.json" | jq -r '.status')
[ "$st" = "execution-error" ] && pass "coverage collector: malformed/unknown status -> execution-error (fail closed, never a derived pass)" || fail "coverage malstatus got $st"

# other collectors map their key
echo '{"violations":2}' > "$CT/m.json"; [ "$(sh "$COLL/mutation.sh" --input "$CT/m.json" | jq '.summary.mutation_score_violations')" = "2" ] && pass "mutation collector maps violations" || fail "mutation map"
echo '{"violations":1,"max_complexity":12}' > "$CT/cx.json"; [ "$(sh "$COLL/complexity.sh" --input "$CT/cx.json" | jq '.summary.complexity_violations,.summary.complexity_max' | tr '\n' ' ')" = "1 12 " ] && pass "complexity collector maps" || fail "complexity map"
echo '{"violations":0,"duplication_percent":4.4}' > "$CT/dup.json"; [ "$(sh "$COLL/duplication.sh" --input "$CT/dup.json" | jq '.summary.duplication_percent')" = "4.4" ] && pass "duplication collector maps" || fail "duplication map"
echo '{"dead_code_count":7}' > "$CT/dc.json"; [ "$(sh "$COLL/dead-code.sh" --input "$CT/dc.json" | jq '.summary.dead_code_violations,.summary.dead_code_count' | tr '\n' ' ')" = "7 7 " ] && pass "dead-code collector maps count->violations" || fail "dead-code map"

# --- (4) builder aggregation (PHP + JS coverage) ------------------------------
RAW="$WORK/build/reports/raw"; mkdir -p "$RAW"
echo '{"tool":"coverage","status":"pass","line_percent":92,"branch_percent":88,"violations":0,"regression":false}' > "$RAW/php-coverage.json"
echo '{"tool":"coverage","status":"findings","line_percent":48,"branch_percent":40,"violations":2,"regression":true}' > "$RAW/js-coverage.json"
sh "$BUILD" --raw-dir "$RAW" --output "$WORK/build/reports/security-summary.json" >/dev/null 2>&1
S="$WORK/build/reports/security-summary.json"
ctv=$(jq '.summary.coverage_threshold_violations' "$S"); creg=$(jq '.summary.coverage_regression' "$S")
line=$(jq '.summary.coverage_line_percent' "$S")
[ "$ctv" = "2" ] && pass "builder: coverage violations summed across stacks (2)" || fail "builder sum got $ctv"
[ "$creg" = "1" ] && pass "builder: coverage_regression clamped to 1 (any stack regressed)" || fail "builder regression got $creg"
[ "$line" = "48" ] && pass "builder: coverage_line_percent = MIN across stacks (48, weakest drives)" || fail "builder min-percent got $line"
# quality counters never mixed into security counters
if [ "$(jq '.summary.secrets' "$S")" = "0" ] && [ "$(jq '.summary.critical_vulnerabilities' "$S")" = "0" ] && [ "$(jq '.summary.medium_vulnerabilities' "$S")" = "0" ]; then
	pass "builder: quality findings NOT folded into security counters"
else fail "builder mixed quality into security counters"; fi
# distinct tool visibility
if [ "$(jq -r '.tools.php_coverage.status' "$S")" = "pass" ] && [ "$(jq -r '.tools.js_coverage.status' "$S")" = "findings" ]; then
	pass "builder: php_coverage and js_coverage kept as distinct tool entries"
else fail "builder lost per-stack coverage visibility"; fi

# --- (5) enforcer -------------------------------------------------------------
mk_summary() { # mk_summary <coverage_thr> <regression> <mutation> <out>
	jq -n --argjson c "$1" --argjson r "$2" --argjson m "$3" '{
		version:"1.0", generated_at:"2026-07-14T00:00:00Z",
		summary:{ secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
			medium_vulnerabilities:0, architecture_violations:0, type_errors:0, test_failures:0,
			unsafe_docker:0, unsafe_github_actions:0, missing_sbom:false, missing_release_evidence:false,
			expired_exceptions:0, coverage_threshold_violations:$c, coverage_regression:$r,
			mutation_score_violations:$m },
		evidence:{ sbom:{present:true}, release_evidence:{present:true} }
	}' > "$4"
}
mk_summary 2 0 1 "$WORK/sum.json"

# strict: coverage_threshold_violations fails, mutation is off (skipped)
sh "$RESOLVE" --mode strict --output-dir "$WORK/enf-strict" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-strict/sentinel-shield-gates.env" --summary "$WORK/sum.json" --output-dir "$WORK/enf-strict" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-strict/sentinel-shield-enforcement.json"
if [ "$rc" -eq 1 ] && [ "$(jq -r '.failed_gates | index("coverage_threshold_violations")' "$ej")" != "null" ] \
	&& [ "$(jq -r '.failed_gates | index("mutation_score_violations")' "$ej")" = "null" ]; then
	pass "enforcer(strict): coverage_threshold_violations fails; mutation skipped (off in strict)"
else fail "enforcer strict wrong (rc=$rc, failed=$(jq -c .failed_gates "$ej"))"; fi
# the mutation gate is present but skipped
[ "$(jq -r '.evaluated_gates[] | select(.key=="mutation_score_violations") | .result' "$ej")" = "skipped" ] \
	&& pass "enforcer(strict): mutation gate evaluated as skipped (disabled)" || fail "enforcer mutation not skipped"

# regulated: mutation now fails too
sh "$RESOLVE" --mode regulated --output-dir "$WORK/enf-reg" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-reg/sentinel-shield-gates.env" --summary "$WORK/sum.json" --output-dir "$WORK/enf-reg" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-reg/sentinel-shield-enforcement.json"
[ "$rc" -eq 1 ] && [ "$(jq -r '.failed_gates | index("mutation_score_violations")' "$ej")" != "null" ] \
	&& pass "enforcer(regulated): mutation_score_violations fails" || fail "enforcer regulated mutation not failing"

# clean quality summary passes when enabled
mk_summary 0 0 0 "$WORK/clean.json"
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-reg/sentinel-shield-gates.env" --summary "$WORK/clean.json" --output-dir "$WORK/enf-clean" --format json >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "enforcer: all quality gates pass at count 0" || fail "enforcer clean should pass, got $rc"

# report-only: quality counts present but all gates skipped
sh "$RESOLVE" --mode report-only --output-dir "$WORK/enf-ro" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-ro/sentinel-shield-gates.env" --summary "$WORK/sum.json" --output-dir "$WORK/enf-ro" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-ro/sentinel-shield-enforcement.json"
if [ "$(jq -r '.evaluated_gates[] | select(.key=="coverage_threshold_violations") | .result' "$ej")" = "skipped" ]; then
	pass "enforcer(report-only): quality gate visible but skipped (non-blocking)"
else fail "enforcer report-only should skip quality gates"; fi

# every blocking quality gate exercised: complexity + duplication block in strict, dead-code
# only in regulated. Build a summary with all three nonzero.
q_base=$(jq -nc '{secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0, medium_vulnerabilities:0,
	architecture_violations:0, type_errors:0, test_failures:0, unsafe_docker:0, unsafe_github_actions:0,
	missing_sbom:false, missing_release_evidence:false, expired_exceptions:0}')
jq -n --argjson b "$q_base" '{version:"1.0", generated_at:"2026-07-14T00:00:00Z",
	summary: ($b + {complexity_violations:1, duplication_violations:2, dead_code_violations:3}),
	evidence:{sbom:{present:true}, release_evidence:{present:true}}}' > "$WORK/q3.json"
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-strict/sentinel-shield-gates.env" --summary "$WORK/q3.json" --output-dir "$WORK/enf-q3s" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-q3s/sentinel-shield-enforcement.json"
if [ "$rc" -eq 1 ] \
	&& [ "$(jq -r '.failed_gates | index("complexity_violations")' "$ej")" != "null" ] \
	&& [ "$(jq -r '.failed_gates | index("duplication_violations")' "$ej")" != "null" ] \
	&& [ "$(jq -r '.failed_gates | index("dead_code_violations")' "$ej")" = "null" ]; then
	pass "enforcer(strict): complexity + duplication block; dead-code skipped"
else fail "enforcer strict complexity/duplication/dead-code wrong: $(jq -c .failed_gates "$ej")"; fi
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-reg/sentinel-shield-gates.env" --summary "$WORK/q3.json" --output-dir "$WORK/enf-q3r" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-q3r/sentinel-shield-enforcement.json"
if [ "$rc" -eq 1 ] \
	&& [ "$(jq -r '.failed_gates | index("complexity_violations")' "$ej")" != "null" ] \
	&& [ "$(jq -r '.failed_gates | index("duplication_violations")' "$ej")" != "null" ] \
	&& [ "$(jq -r '.failed_gates | index("dead_code_violations")' "$ej")" != "null" ]; then
	pass "enforcer(regulated): complexity + duplication + dead-code all block"
else fail "enforcer regulated complexity/duplication/dead-code wrong: $(jq -c .failed_gates "$ej")"; fi

# missing_coverage_evidence (unit): true summary blocks strict; skipped in report-only.
jq -n --argjson b "$q_base" '{version:"1.0", generated_at:"2026-07-14T00:00:00Z",
	summary: ($b + {missing_coverage_evidence:true}),
	evidence:{sbom:{present:true}, release_evidence:{present:true}}}' > "$WORK/mce.json"
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-strict/sentinel-shield-gates.env" --summary "$WORK/mce.json" --output-dir "$WORK/enf-mce" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/enf-mce/sentinel-shield-enforcement.json"
[ "$rc" -eq 1 ] && [ "$(jq -r '.failed_gates | index("missing_coverage_evidence")' "$ej")" != "null" ] \
	&& pass "enforcer(strict): missing_coverage_evidence=true blocks (absent coverage fails)" \
	|| fail "enforcer strict missing_coverage_evidence not failing: $(jq -c .failed_gates "$ej")"
rc=0; sh "$ENFORCE" --gates-env "$WORK/enf-ro/sentinel-shield-gates.env" --summary "$WORK/mce.json" --output-dir "$WORK/enf-mcero" --format json >/dev/null 2>&1 || rc=$?
[ "$(jq -r '.evaluated_gates[] | select(.key=="missing_coverage_evidence") | .result' "$WORK/enf-mcero/sentinel-shield-enforcement.json")" = "skipped" ] \
	&& pass "enforcer(report-only): missing_coverage_evidence skipped" || fail "missing_coverage_evidence should skip in report-only"

# missing_coverage_evidence (integration): a profile with an applicable coverage tool but NO
# coverage report -> builder sets it true; adding a coverage report clears it.
if command -v php >/dev/null 2>&1; then
	MT="$WORK/covproj"; mkdir -p "$MT/reports/raw"
	printf '{"name":"x/y"}\n' > "$MT/composer.json"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/reports/security-summary.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_coverage_evidence' "$MT/reports/security-summary.json")" = "true" ] \
		&& pass "builder: missing_coverage_evidence=true when applicable coverage report absent" \
		|| fail "builder should flag missing coverage evidence"
	echo '{"tool":"coverage","status":"pass","line_percent":95,"branch_percent":90,"violations":0,"regression":false}' > "$MT/reports/raw/php-coverage.json"
	( cd "$MT" && sh "$BUILD" --profile laravel --target "$MT" --raw-dir "$MT/reports/raw" --output "$MT/reports/security-summary.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_coverage_evidence' "$MT/reports/security-summary.json")" = "false" ] \
		&& pass "builder: missing_coverage_evidence=false once coverage report present" \
		|| fail "builder should clear missing coverage evidence when report present"
else
	fail "builder missing_coverage_evidence integration: php REQUIRED but not available"
fi

# --- (6) quality-policy loader fails closed on malformed ----------------------
cat > "$WORK/qp-harness.sh" <<EOF
set -eu
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/quality-policy.sh"
qp_load "\$1"
echo "line=\$(qp_num quality.coverage.line_min 80)"
EOF
printf 'quality:\n  coverage:\n    line_min: notanumber\n' > "$WORK/bad-policy.yaml"
rc=0; sh "$WORK/qp-harness.sh" "$WORK/bad-policy.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "quality-policy: malformed threshold fails closed (exit 2)" || fail "quality-policy malformed should exit 2, got $rc"
# stricter numeric validation: each of these must fail closed (finite, in-range only).
_qpbad=0
for _v in '1.2.3' '...' '101' '-1' 'NaN'; do
	printf 'quality:\n  coverage:\n    line_min: %s\n' "$_v" > "$WORK/qpb.yaml"
	rc=0; sh "$WORK/qp-harness.sh" "$WORK/qpb.yaml" >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 2 ] || { _qpbad=1; echo "  (line_min='$_v' got exit $rc, expected 2)"; }
done
[ "$_qpbad" -eq 0 ] && pass "quality-policy: rejects 1.2.3 / ... / 101 / -1 / NaN (exit 2)" || fail "quality-policy accepted a malformed numeric"
# complexity must be an integer >= 1
printf 'quality:\n  complexity:\n    max_cyclomatic_complexity: 10.5\n' > "$WORK/qpc.yaml"
rc=0; sh "$WORK/qp-harness.sh" "$WORK/qpc.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && pass "quality-policy: non-integer complexity threshold fails closed" || fail "quality-policy complexity non-integer should exit 2"
# valid edge values accepted (0 and 100)
printf 'quality:\n  coverage:\n    line_min: 0\n    branch_min: 100\n' > "$WORK/qpok.yaml"
rc=0; sh "$WORK/qp-harness.sh" "$WORK/qpok.yaml" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && pass "quality-policy: valid edge thresholds (0, 100) accepted" || fail "quality-policy rejected valid edges"
# absent policy is fine (defaults)
rc=0; out=$(sh "$WORK/qp-harness.sh" "$WORK/none.yaml" 2>/dev/null) || rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "line=80" ] && pass "quality-policy: absent policy uses defaults" || fail "quality-policy absent should default (rc=$rc out=$out)"

# --- (7) coverage adapters (node + php MANDATORY — a missing runtime is a FAIL, not a
#         silent pass; CI runners provide both, so the core coverage adapters are exercised) --
if command -v node >/dev/null 2>&1; then
	A="$ROOT/scripts/adapters/istanbul-summary-to-coverage-json.mjs"
	echo '{"total":{"lines":{"total":100,"covered":78,"pct":78},"branches":{"total":40,"covered":30,"pct":75},"functions":{"total":10,"covered":9,"pct":90}}}' > "$WORK/cov-sum.json"
	echo '{"line_percent":85,"branch_percent":70}' > "$WORK/cov-base.json"
	o=$(node "$A" "$WORK/cov-sum.json" --line-min 80 --branch-min 60 --baseline "$WORK/cov-base.json" --fail-on-decrease true 2>/dev/null)
	if [ "$(echo "$o" | jq '.line_percent')" = "78" ] && [ "$(echo "$o" | jq '.violations')" = "1" ] && [ "$(echo "$o" | jq '.regression')" = "true" ]; then
		pass "istanbul adapter: line 78, 1 threshold violation, regression vs baseline"
	else fail "istanbul adapter wrong: $(echo "$o" | jq -c '{line_percent,violations,regression}')"; fi
	rc=0; echo 'bad' > "$WORK/badcov.json"; node "$A" "$WORK/badcov.json" >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 2 ] && pass "istanbul adapter: invalid input -> exit 2" || fail "istanbul adapter invalid got $rc"
	# hardening: out-of-range/bad-bool thresholds fail closed (never silently disable a gate)
	rc=0; node "$A" "$WORK/cov-sum.json" --line-min 101 >/dev/null 2>&1 || rc=$?; _e1=$rc
	rc=0; node "$A" "$WORK/cov-sum.json" --line-min -1 >/dev/null 2>&1 || rc=$?; _e2=$rc
	rc=0; node "$A" "$WORK/cov-sum.json" --fail-on-decrease maybe >/dev/null 2>&1 || rc=$?; _e3=$rc
	{ [ "$_e1" -eq 2 ] && [ "$_e2" -eq 2 ] && [ "$_e3" -eq 2 ]; } && pass "istanbul adapter: out-of-range/bad-bool options exit 2" || fail "istanbul adapter option validation ($_e1/$_e2/$_e3)"
	# hardening: malformed metric object (present but non-numeric) exits 2
	echo '{"total":{"lines":{"pct":95}}}' > "$WORK/malmetric.json"
	rc=0; node "$A" "$WORK/malmetric.json" >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 2 ] && pass "istanbul adapter: malformed metric object exits 2" || fail "istanbul adapter malformed metric got $rc"
	# hardening: explicitly-configured baseline that is missing/malformed fails closed
	rc=0; node "$A" "$WORK/cov-sum.json" --baseline "$WORK/nobase.json" --fail-on-decrease true >/dev/null 2>&1 || rc=$?; _b1=$rc
	echo 'not json' > "$WORK/badbase.json"; rc=0; node "$A" "$WORK/cov-sum.json" --baseline "$WORK/badbase.json" >/dev/null 2>&1 || rc=$?; _b2=$rc
	{ [ "$_b1" -eq 2 ] && [ "$_b2" -eq 2 ]; } && pass "istanbul adapter: invalid configured baseline fails closed (exit 2)" || fail "istanbul adapter baseline not fail-closed ($_b1/$_b2)"
else
	fail "istanbul adapter: node REQUIRED but not available (core coverage adapter cannot be verified)"
fi

if command -v php >/dev/null 2>&1; then
	A="$ROOT/scripts/adapters/clover-to-coverage-json.php"
	cat > "$WORK/clover.xml" <<'EOF'
<?xml version="1.0"?>
<coverage><project><file name="A.php"><metrics statements="10" coveredstatements="7" conditionals="4" coveredconditionals="2" methods="2" coveredmethods="2"/></file></project></coverage>
EOF
	o=$(php "$A" "$WORK/clover.xml" --line-min 80 --branch-min 60 2>/dev/null)
	# line 7/10 = 70 (< 80 -> violation); branch 2/4 = 50 (< 60 -> violation) => 2 violations
	if [ "$(echo "$o" | jq '.line_percent')" = "70" ] && [ "$(echo "$o" | jq '.violations')" = "2" ]; then
		pass "clover adapter: line 70%, 2 threshold violations"
	else fail "clover adapter wrong: $(echo "$o" | jq -c '{line_percent,branch_percent,violations}')"; fi
	# missing-metrics tolerance: no conditionals -> branch not counted, no false violation
	cat > "$WORK/clover2.xml" <<'EOF'
<?xml version="1.0"?>
<coverage><project><file name="A.php"><metrics statements="10" coveredstatements="10" conditionals="0" coveredconditionals="0" methods="1" coveredmethods="1"/></file></project></coverage>
EOF
	o=$(php "$A" "$WORK/clover2.xml" --line-min 80 --branch-min 60 2>/dev/null)
	[ "$(echo "$o" | jq '.violations')" = "0" ] && pass "clover adapter: unmeasured branch metric not falsely failed" || fail "clover adapter false branch violation"
	# hardening: out-of-range/bad-bool options + invalid configured baseline fail closed
	rc=0; php "$A" "$WORK/clover.xml" --line-min 101 >/dev/null 2>&1 || rc=$?; _p1=$rc
	rc=0; php "$A" "$WORK/clover.xml" --fail-on-decrease nope >/dev/null 2>&1 || rc=$?; _p2=$rc
	rc=0; php "$A" "$WORK/clover.xml" --baseline "$WORK/nobase.json" --fail-on-decrease true >/dev/null 2>&1 || rc=$?; _p3=$rc
	{ [ "$_p1" -eq 2 ] && [ "$_p2" -eq 2 ] && [ "$_p3" -eq 2 ]; } && pass "clover adapter: bad options + invalid baseline fail closed (exit 2)" || fail "clover adapter validation ($_p1/$_p2/$_p3)"
else
	fail "clover adapter: php REQUIRED but not available (core coverage adapter cannot be verified)"
fi

# --- (8) §2 collectors -------------------------------------------------------
DC="$WORK/dc"; mkdir -p "$DC"
echo '{"tool":"diff-coverage","status":"findings","changed_lines_coverage_percent":60,"threshold":80,"violations":1}' > "$DC/dcv.json"
o=$(sh "$COLL/diff-coverage.sh" --input "$DC/dcv.json")
[ "$(echo "$o" | jq '.summary.changed_lines_coverage_violations')" = "1" ] && [ "$(echo "$o" | jq '.summary.changed_lines_coverage_percent')" = "60" ] \
	&& pass "diff-coverage collector maps violations + percent" || fail "diff-coverage collector wrong"
echo '{"tool":"source-size","status":"findings","large_file_violations":2,"large_function_violations":1,"max_file_lines":900,"max_function_lines":150}' > "$DC/ss.json"
o=$(sh "$COLL/source-size.sh" --input "$DC/ss.json")
[ "$(echo "$o" | jq '.summary.large_file_violations')" = "2" ] && [ "$(echo "$o" | jq '.summary.max_file_lines')" = "900" ] \
	&& pass "source-size collector maps violations + max lines" || fail "source-size collector wrong"
# negative values in a raw report must clamp to 0 (never emit a negative that violates minimum:0)
echo '{"focused_test_violations":-4,"skipped_test_marker_violations":-1}' > "$DC/neg.json"
o=$(sh "$COLL/focused-tests.sh" --input "$DC/neg.json")
[ "$(echo "$o" | jq '.summary.focused_test_violations')" = "0" ] && [ "$(echo "$o" | jq '.summary.skipped_test_marker_violations')" = "0" ] \
	&& pass "collectors clamp negative counts to 0 (schema minimum:0 upheld)" || fail "collector did not clamp negatives"
echo '{"line_percent":-9,"violations":-3,"regression":false}' > "$DC/negcov.json"
o=$(sh "$COLL/coverage.sh" --input "$DC/negcov.json")
[ "$(echo "$o" | jq '.summary.coverage_threshold_violations')" = "0" ] && [ "$(echo "$o" | jq '.summary.coverage_line_percent')" = "0" ] \
	&& pass "coverage collector clamps negative violations + percent to 0" || fail "coverage collector did not clamp negatives"

# --- (9) resolver mode defaults for the §2 gates -----------------------------
gv() { awk -F= -v k="SENTINEL_SHIELD_FAIL_ON_$2" '$1==k{print $2;exit}' "$1"; }
for m in report-only baseline strict regulated; do
	od="$WORK/m2-$m"; sh "$RESOLVE" --mode "$m" --output-dir "$od" --format env >/dev/null 2>&1
	e="$od/sentinel-shield-gates.env"; ok=1
	case "$m" in
		report-only)
			[ "$(gv "$e" FOCUSED_TEST_VIOLATIONS)" = "true" ] || ok=0
			for g in CHANGED_LINES_COVERAGE_VIOLATIONS MISSING_TEST_EVIDENCE EMPTY_TEST_SUITE SKIPPED_TESTS SKIPPED_TEST_MARKER_VIOLATIONS DEBUG_CODE_VIOLATIONS LARGE_FILE_VIOLATIONS LARGE_FUNCTION_VIOLATIONS; do [ "$(gv "$e" "$g")" = "false" ] || ok=0; done ;;
		baseline)
			for g in CHANGED_LINES_COVERAGE_VIOLATIONS MISSING_TEST_EVIDENCE EMPTY_TEST_SUITE FOCUSED_TEST_VIOLATIONS DEBUG_CODE_VIOLATIONS; do [ "$(gv "$e" "$g")" = "true" ] || ok=0; done
			for g in SKIPPED_TESTS SKIPPED_TEST_MARKER_VIOLATIONS LARGE_FILE_VIOLATIONS LARGE_FUNCTION_VIOLATIONS; do [ "$(gv "$e" "$g")" = "false" ] || ok=0; done ;;
		strict)
			for g in CHANGED_LINES_COVERAGE_VIOLATIONS MISSING_TEST_EVIDENCE EMPTY_TEST_SUITE FOCUSED_TEST_VIOLATIONS DEBUG_CODE_VIOLATIONS SKIPPED_TEST_MARKER_VIOLATIONS LARGE_FILE_VIOLATIONS LARGE_FUNCTION_VIOLATIONS; do [ "$(gv "$e" "$g")" = "true" ] || ok=0; done
			[ "$(gv "$e" SKIPPED_TESTS)" = "false" ] || ok=0 ;;
		regulated)
			for g in CHANGED_LINES_COVERAGE_VIOLATIONS MISSING_TEST_EVIDENCE EMPTY_TEST_SUITE FOCUSED_TEST_VIOLATIONS DEBUG_CODE_VIOLATIONS SKIPPED_TEST_MARKER_VIOLATIONS LARGE_FILE_VIOLATIONS LARGE_FUNCTION_VIOLATIONS SKIPPED_TESTS; do [ "$(gv "$e" "$g")" = "true" ] || ok=0; done ;;
	esac
	[ "$ok" -eq 1 ] && pass "resolver($m): §2 gate defaults correct" || fail "resolver($m): §2 gate defaults wrong"
done

# --- (10) enforcer §2 failure paths ------------------------------------------
qsum() { jq -n --argjson b "$q_base" --argjson o "$2" '{version:"1.0",generated_at:"2026-07-14T00:00:00Z",summary:($b+$o),evidence:{sbom:{present:true},release_evidence:{present:true}}}' > "$1"; }
_q2ov=$(jq -nc '{changed_lines_coverage_violations:1, debug_code_violations:2, focused_test_violations:1, missing_test_evidence:true, empty_test_suite:true, skipped_test_marker_violations:1, large_file_violations:1, large_function_violations:1, skipped_tests:2}')
qsum "$WORK/q2.json" "$_q2ov"
# baseline: changed/debug/focused/missing_test/empty block; skipped_marker/large/skipped_tests do NOT
sh "$RESOLVE" --mode baseline --output-dir "$WORK/e2b" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/e2b/sentinel-shield-gates.env" --summary "$WORK/q2.json" --output-dir "$WORK/e2b" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/e2b/sentinel-shield-enforcement.json"; ok=1
for g in changed_lines_coverage_violations debug_code_violations focused_test_violations missing_test_evidence empty_test_suite; do [ "$(jq -r --arg g "$g" '.failed_gates|index($g)' "$ej")" != "null" ] || ok=0; done
for g in skipped_test_marker_violations large_file_violations skipped_tests; do [ "$(jq -r --arg g "$g" '.failed_gates|index($g)' "$ej")" = "null" ] || ok=0; done
{ [ "$rc" -eq 1 ] && [ "$ok" -eq 1 ]; } && pass "enforcer(baseline): §2 baseline gates block; strict/regulated-only gates skip" || fail "enforcer baseline §2 wrong: $(jq -c .failed_gates "$ej")"
# strict adds large_file/large_function/skipped_marker; skipped_tests still off
sh "$RESOLVE" --mode strict --output-dir "$WORK/e2s" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/e2s/sentinel-shield-gates.env" --summary "$WORK/q2.json" --output-dir "$WORK/e2s" --format json >/dev/null 2>&1 || rc=$?
ej="$WORK/e2s/sentinel-shield-enforcement.json"; ok=1
for g in large_file_violations large_function_violations skipped_test_marker_violations; do [ "$(jq -r --arg g "$g" '.failed_gates|index($g)' "$ej")" != "null" ] || ok=0; done
[ "$(jq -r '.failed_gates|index("skipped_tests")' "$ej")" = "null" ] || ok=0
{ [ "$rc" -eq 1 ] && [ "$ok" -eq 1 ]; } && pass "enforcer(strict): §2 maintainability + skip-marker block; skipped_tests off" || fail "enforcer strict §2 wrong: $(jq -c .failed_gates "$ej")"
# regulated adds skipped_tests
sh "$RESOLVE" --mode regulated --output-dir "$WORK/e2r" --format env >/dev/null 2>&1
rc=0; sh "$ENFORCE" --gates-env "$WORK/e2r/sentinel-shield-gates.env" --summary "$WORK/q2.json" --output-dir "$WORK/e2r" --format json >/dev/null 2>&1 || rc=$?
[ "$(jq -r '.failed_gates|index("skipped_tests")' "$WORK/e2r/sentinel-shield-enforcement.json")" != "null" ] \
	&& pass "enforcer(regulated): skipped_tests blocks" || fail "enforcer regulated skipped_tests not blocking"

# --- (11) builder §2 integration (profile-aware test evidence + diff aggregation) ----
if command -v php >/dev/null 2>&1; then
	P="$WORK/p11"; PR="$P/reports/raw"; mkdir -p "$PR"; printf '{"name":"x/y"}\n' > "$P/composer.json"
	# no tests.json -> missing_test_evidence true
	( cd "$P" && sh "$BUILD" --profile laravel --target "$P" --raw-dir "$PR" --output "$P/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.missing_test_evidence' "$P/s.json")" = "true" ] && pass "builder: missing_test_evidence true when no test report" || fail "builder missing_test_evidence should be true"
	# empty suite
	echo '{"failures":0,"errors":0,"tests":0,"skipped":0}' > "$PR/tests.json"
	( cd "$P" && sh "$BUILD" --profile laravel --target "$P" --raw-dir "$PR" --output "$P/s.json" ) >/dev/null 2>&1
	if [ "$(jq -r '.summary.missing_test_evidence' "$P/s.json")" = "false" ] && [ "$(jq -r '.summary.empty_test_suite' "$P/s.json")" = "true" ]; then
		pass "builder: empty_test_suite true when report present with 0 tests"
	else fail "builder empty_test_suite wrong"; fi
	# non-empty clears both
	echo '{"failures":0,"errors":0,"tests":42,"skipped":0}' > "$PR/tests.json"
	( cd "$P" && sh "$BUILD" --profile laravel --target "$P" --raw-dir "$PR" --output "$P/s.json" ) >/dev/null 2>&1
	[ "$(jq -r '.summary.empty_test_suite' "$P/s.json")" = "false" ] && [ "$(jq -r '.summary.test_count' "$P/s.json")" = "42" ] \
		&& pass "builder: non-empty suite clears empty_test_suite (test_count=42)" || fail "builder non-empty suite wrong"
else
	fail "builder §2 test-evidence integration: php REQUIRED but unavailable"
fi
# diff-coverage aggregation (php + js): violations sum, percent min. No profile needed (canonical rows).
DA="$WORK/da/reports/raw"; mkdir -p "$DA"
echo '{"tool":"diff-coverage","status":"pass","changed_lines_coverage_percent":90,"violations":0}' > "$DA/php-diff-coverage.json"
echo '{"tool":"diff-coverage","status":"findings","changed_lines_coverage_percent":55,"violations":1}' > "$DA/js-diff-coverage.json"
sh "$BUILD" --raw-dir "$DA" --output "$WORK/da/s.json" >/dev/null 2>&1
[ "$(jq '.summary.changed_lines_coverage_violations' "$WORK/da/s.json")" = "1" ] && [ "$(jq '.summary.changed_lines_coverage_percent' "$WORK/da/s.json")" = "55" ] \
	&& pass "builder: diff-coverage aggregates (violations sum=1, percent MIN=55)" || fail "builder diff-coverage aggregation wrong"
# no quality counter leaked into security
if [ "$(jq '.summary.secrets' "$WORK/da/s.json")" = "0" ] && [ "$(jq '.summary.critical_vulnerabilities' "$WORK/da/s.json")" = "0" ]; then
	pass "builder: §2 quality counters not mixed into security counters"
else fail "builder mixed §2 quality into security"; fi

# --- (12) combined-profile coverage independence (PHP vs JS) ------------------
if command -v php >/dev/null 2>&1; then
	C="$WORK/comb"; CR="$C/reports/raw"; mkdir -p "$CR"
	printf '{"name":"x/y"}\n' > "$C/composer.json"; printf '{"name":"x","version":"1.0.0"}\n' > "$C/package.json"
	bmce() { ( cd "$C" && sh "$BUILD" --profile laravel-react-docker --target "$C" --raw-dir "$CR" --output "$C/s.json" ) >/dev/null 2>&1; jq -r '.summary.missing_coverage_evidence' "$C/s.json"; }
	rm -f "$CR"/*coverage.json 2>/dev/null || true
	echo '{"tool":"coverage","status":"pass","line_percent":95,"violations":0,"regression":false}' > "$CR/php-coverage.json"
	[ "$(bmce)" = "true" ] && pass "combined: only PHP coverage present -> missing_coverage_evidence true (JS missing)" || fail "combined PHP-only should flag missing JS coverage"
	rm -f "$CR/php-coverage.json"
	echo '{"tool":"coverage","status":"pass","line_percent":95,"violations":0,"regression":false}' > "$CR/js-coverage.json"
	[ "$(bmce)" = "true" ] && pass "combined: only JS coverage present -> missing_coverage_evidence true (PHP missing)" || fail "combined JS-only should flag missing PHP coverage"
	echo '{"tool":"coverage","status":"pass","line_percent":95,"violations":0,"regression":false}' > "$CR/php-coverage.json"
	[ "$(bmce)" = "false" ] && pass "combined: both PHP + JS coverage present -> missing_coverage_evidence false" || fail "combined both-present should clear missing coverage"
else
	fail "combined-profile coverage independence: php REQUIRED but unavailable"
fi

# --- (13) runners: focused/debug/source-size + js-coverage no-dir + php diff-coverage ----
R="$WORK/run"; mkdir -p "$R/src" "$R/tests"; cd "$R"
printf 'describe.only("a", () => { it.only("b", () => {}); });\n' > tests/a.test.js
printf 'it.skip("c", () => {});\n' > tests/b.test.js
sh "$ROOT/scripts/runners/focused-tests.sh" >/dev/null 2>&1
[ "$(jq '.focused_test_violations' reports/raw/focused-tests.json)" -ge 2 ] && [ "$(jq '.skipped_test_marker_violations' reports/raw/focused-tests.json)" -ge 1 ] \
	&& pass "focused-tests runner: counts .only markers + skip markers" || fail "focused-tests runner wrong"
printf '<?php\nfunction f(){ dd($x); var_dump($y); }\n' > src/prod.php
sh "$ROOT/scripts/runners/debug-code.sh" >/dev/null 2>&1
[ "$(jq '.debug_code_violations' reports/raw/debug-code.json)" -ge 2 ] && pass "debug-code runner: counts debug residue" || fail "debug-code runner wrong"
mkdir -p .sentinel-shield; printf 'quality:\n  maintainability:\n    max_file_lines: 100\n    max_function_lines: 80\n' > .sentinel-shield/quality-policy.yaml
seq 1 200 | sed 's/^/x/' > src/big.js
sh "$ROOT/scripts/runners/source-size.sh" >/dev/null 2>&1
[ "$(jq '.large_file_violations' reports/raw/source-size.json)" -ge 1 ] && pass "source-size runner: flags file over max_file_lines" || fail "source-size runner wrong"
cd "$ROOT"
# js-coverage.sh with reports/raw NOT pre-existing: must not crash on the run-log redirect
JD="$WORK/jsnodir"; mkdir -p "$JD/coverage"; printf '{"name":"x","scripts":{}}\n' > "$JD/package.json"
echo '{"total":{"lines":{"total":10,"covered":9,"pct":90},"branches":{"total":4,"covered":3,"pct":75},"functions":{"total":2,"covered":2,"pct":100}}}' > "$JD/coverage/coverage-summary.json"
rc=0; ( cd "$JD" && sh "$ROOT/scripts/runners/js-coverage.sh" ) >/dev/null 2>&1 || rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$JD/reports/raw/js-coverage.json" ]; } && pass "js-coverage.sh: works when reports/raw did not pre-exist" || fail "js-coverage.sh failed with missing reports/raw (rc=$rc)"
# php diff-coverage runner: deterministic git+clover path
if command -v php >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
	G="$WORK/gitproj"; mkdir -p "$G/src"; cd "$G"
	git init -q; git config user.email t@t; git config user.name t
	printf '<?php\nclass A { public function f(){ return 1; } }\n' > src/A.php
	git add -A; git commit -qm init
	# stub pest emitting per-line clover for the changed lines
	mkdir -p vendor/bin
	cat > vendor/bin/pest <<'STUB'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do case "$1" in --coverage-clover) out="$2"; shift 2;; *) shift;; esac; done
cat > "$out" <<XML
<?xml version="1.0"?>
<coverage><project><file name="$(pwd)/src/A.php"><line num="2" type="stmt" count="0"/><line num="3" type="stmt" count="0"/></file></project></coverage>
XML
STUB
	chmod +x vendor/bin/pest
	printf '<?php\nclass A { public function f(){ return 1; } public function g(){ return 2; } }\n' > src/A.php
	git add -A; git commit -qm change
	SENTINEL_SHIELD_DIFF_BASE=HEAD~1 sh "$ROOT/scripts/runners/php-diff-coverage.sh" >/dev/null 2>&1
	if [ -f reports/raw/php-diff-coverage.json ]; then
		pass "php-diff-coverage runner: produced a report from git diff + clover (percent=$(jq -r '.changed_lines_coverage_percent' reports/raw/php-diff-coverage.json))"
	else fail "php-diff-coverage runner produced no report"; fi
	cd "$ROOT"
else
	fail "php-diff-coverage runner: php+git REQUIRED but unavailable"
fi

# --- (14) builder status preservation: honest error statuses must NOT become pass ----------
# A present, valid-JSON report with an error status must drive the evidence gates, never a
# clean pass. Requires php (laravel profile applicability).
if command -v php >/dev/null 2>&1; then
	sp_build() { # <coverage.json|-> <tests.json|-> ; sets SP_JSON to the summary path
		_w=$(mktemp -d); mkdir -p "$_w/reports/raw"; printf '{"name":"x/y"}\n' > "$_w/composer.json"
		[ "$1" != "-" ] && printf '%s' "$1" > "$_w/reports/raw/php-coverage.json"
		[ "$2" != "-" ] && printf '%s' "$2" > "$_w/reports/raw/tests.json"
		( cd "$_w" && sh "$BUILD" --profile laravel --target "$_w" --raw-dir "$_w/reports/raw" --output "$_w/s.json" ) >/dev/null 2>&1
		SP_JSON="$_w/s.json"
	}
	# 4.1A coverage execution-error -> missing evidence + preserved status + executed:false
	sp_build '{"tool":"coverage","status":"execution-error"}' '-'
	if [ "$(jq -r '.summary.missing_coverage_evidence' "$SP_JSON")" = "true" ] \
		&& [ "$(jq -r '.tools.php_coverage.status' "$SP_JSON")" = "execution-error" ] \
		&& [ "$(jq -r '.tools.php_coverage.executed' "$SP_JSON")" = "false" ]; then
		pass "builder: coverage execution-error -> missing_coverage_evidence + status preserved + executed=false"
	else fail "builder: coverage execution-error not preserved ($(jq -c '{mce:.summary.missing_coverage_evidence,s:.tools.php_coverage.status,e:.tools.php_coverage.executed}' "$SP_JSON"))"; fi
	# 4.1B unavailable, 4.1C not-configured
	sp_build '{"tool":"coverage","status":"unavailable"}' '-'
	{ [ "$(jq -r '.summary.missing_coverage_evidence' "$SP_JSON")" = "true" ] && [ "$(jq -r '.tools.php_coverage.status' "$SP_JSON")" = "unavailable" ]; } \
		&& pass "builder: coverage unavailable -> missing evidence + status unavailable" || fail "builder: coverage unavailable not preserved"
	sp_build '{"tool":"coverage","status":"not-configured"}' '-'
	{ [ "$(jq -r '.summary.missing_coverage_evidence' "$SP_JSON")" = "true" ] && [ "$(jq -r '.tools.php_coverage.status' "$SP_JSON")" = "not-configured" ]; } \
		&& pass "builder: coverage not-configured -> missing evidence + status not-configured" || fail "builder: coverage not-configured not preserved"
	# 4.1D findings -> evidence EXISTS (false), violation still counted
	sp_build '{"tool":"coverage","status":"findings","line_percent":50,"violations":1,"regression":false}' '-'
	{ [ "$(jq -r '.summary.missing_coverage_evidence' "$SP_JSON")" = "false" ] && [ "$(jq '.summary.coverage_threshold_violations' "$SP_JSON")" = "1" ] && [ "$(jq -r '.tools.php_coverage.status' "$SP_JSON")" = "findings" ]; } \
		&& pass "builder: coverage findings -> evidence present (mce=false), violation counted" || fail "builder: coverage findings wrong"
	# 4.3 unknown status fails closed as execution-error
	sp_build '{"tool":"coverage","status":"weird"}' '-'
	{ [ "$(jq -r '.tools.php_coverage.status' "$SP_JSON")" = "execution-error" ] && [ "$(jq -r '.summary.missing_coverage_evidence' "$SP_JSON")" = "true" ]; } \
		&& pass "builder: unknown coverage status fails closed (execution-error, missing evidence)" || fail "builder: unknown coverage status not fail-closed"
	# 4.2A tests execution-error -> missing_test_evidence, NOT empty_test_suite
	sp_build '{"tool":"coverage","status":"pass","line_percent":90,"violations":0,"regression":false}' '{"status":"execution-error"}'
	if [ "$(jq -r '.summary.missing_test_evidence' "$SP_JSON")" = "true" ] \
		&& [ "$(jq -r '.summary.empty_test_suite' "$SP_JSON")" = "false" ] \
		&& [ "$(jq -r '.tools.tests.status' "$SP_JSON")" = "execution-error" ]; then
		pass "builder: tests execution-error -> missing_test_evidence, empty_test_suite=false, status preserved"
	else fail "builder: tests execution-error not handled ($(jq -c '{mte:.summary.missing_test_evidence,es:.summary.empty_test_suite,s:.tools.tests.status}' "$SP_JSON"))"; fi
	# 4.2B tests empty (0) -> empty_test_suite, not missing
	sp_build '{"tool":"coverage","status":"pass","line_percent":90,"violations":0,"regression":false}' '{"failures":0,"errors":0,"tests":0,"skipped":0}'
	{ [ "$(jq -r '.summary.missing_test_evidence' "$SP_JSON")" = "false" ] && [ "$(jq -r '.summary.empty_test_suite' "$SP_JSON")" = "true" ]; } \
		&& pass "builder: tests with 0 tests -> empty_test_suite (not missing)" || fail "builder: empty suite wrong"
	# 4.2C tests 42 -> both false, test_count=42
	sp_build '{"tool":"coverage","status":"pass","line_percent":90,"violations":0,"regression":false}' '{"failures":0,"errors":0,"tests":42,"skipped":0}'
	{ [ "$(jq -r '.summary.missing_test_evidence' "$SP_JSON")" = "false" ] && [ "$(jq -r '.summary.empty_test_suite' "$SP_JSON")" = "false" ] && [ "$(jq '.summary.test_count' "$SP_JSON")" = "42" ]; } \
		&& pass "builder: tests with 42 -> evidence present, test_count=42" || fail "builder: 42-test case wrong"
else
	fail "builder status-preservation tests: php REQUIRED but unavailable"
fi
# collector-level: unknown status fails closed (no php needed)
echo '{"tool":"coverage","status":"weird"}' > "$WORK/uc.json"
[ "$(sh "$COLL/coverage.sh" --input "$WORK/uc.json" | jq -r '.status')" = "execution-error" ] \
	&& pass "coverage collector: unknown status -> execution-error (fail closed)" || fail "coverage collector unknown status not fail-closed"
echo '{"tool":"coverage","status":"execution-error"}' > "$WORK/ec.json"
[ "$(sh "$COLL/coverage.sh" --input "$WORK/ec.json" | jq -r '.status')" = "execution-error" ] \
	&& pass "coverage collector: execution-error passed through" || fail "coverage collector execution-error not preserved"

# --- (15) quality-policy fallback: present-but-empty value fails closed (no yq) --------------
# Force the awk fallback with a fake non-mikefarah yq so the yq path is not taken.
QSHIM="$WORK/qshim"; mkdir -p "$QSHIM"; printf '#!/bin/sh\necho "yq version 3.4.1"\n' > "$QSHIM/yq"; chmod +x "$QSHIM/yq"
# The harness prints the loaded values on success so tests can assert defaults are applied and
# explicit values load (exit 0 alone would not prove the fallback actually read/defaulted values).
cat > "$WORK/qpfh.sh" <<EOF
set -eu
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/quality-policy.sh"
qp_load "\$1"
printf 'VALS line_min=%s branch_min=%s enabled=%s fod=%s\n' \\
	"\$(qp_num quality.coverage.line_min 80)" \\
	"\$(qp_num quality.coverage.branch_min 60)" \\
	"\$(qp_bool quality.coverage.enabled true)" \\
	"\$(qp_bool quality.coverage.fail_on_decrease false)"
EOF
# qpf <label> <yaml> <expected-exit> [<expected VALS substring for exit-0 cases>]
qpf() {
	printf '%b' "$2" > "$WORK/qpf.yaml"; rc=0
	_out=$(PATH="$QSHIM:$PATH" sh "$WORK/qpfh.sh" "$WORK/qpf.yaml" 2>&1) || rc=$?
	# confirm the fallback (awk) path actually ran, not the yq path.
	if [ "$rc" != "$3" ]; then fail "quality-policy fallback: $1 (exit $rc, want $3)"; return; fi
	if [ "$rc" = "0" ] && [ -n "${4:-}" ]; then
		case "$_out" in *"$4"*) pass "quality-policy fallback: $1 (values: $4)" ;; *) fail "quality-policy fallback: $1 — expected values '$4', got '$(printf '%s' "$_out" | grep VALS || echo none)'" ;; esac
	else
		pass "quality-policy fallback: $1"
	fi
}
qpf "empty numeric line_min fails closed" 'quality:\n  coverage:\n    line_min:\n' 2
qpf "empty boolean enabled fails closed"  'quality:\n  coverage:\n    enabled:\n' 2
qpf "empty maintainability size fails closed" 'quality:\n  maintainability:\n    max_file_lines:\n' 2
qpf "malformed 1.2.3 fails closed"        'quality:\n  coverage:\n    line_min: 1.2.3\n' 2
# absent line_min defaults to 80, absent enabled defaults to true; explicit branch_min=60 loads
qpf "valid absent keys use defaults"      'quality:\n  coverage:\n    branch_min: 60\n' 0 'line_min=80 branch_min=60 enabled=true fod=false'
# explicit values load; unspecified branch_min still defaults to 60
qpf "valid explicit values load"          'quality:\n  coverage:\n    enabled: false\n    line_min: 55\n    fail_on_decrease: true\n' 0 'line_min=55 branch_min=60 enabled=false fod=true'

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
