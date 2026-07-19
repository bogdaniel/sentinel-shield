#!/bin/sh
# Sentinel Shield prod test — testing discipline governance (v2.2.0).
#
# Covers the TDD-proxy / BDD-evidence / ATDD-acceptance-evidence feature: resolver mode
# defaults for the six new gates (including the app-profile-only BDD/ATDD defaults), the
# changed-file TDD proxy runner (classification, waivers, no-diff-base), all three collectors
# and their fail-closed behavior, the builder's expectation logic (evidence is only "missing"
# when it was EXPECTED), and the enforcer.
#
# Scope honesty: this suite proves the ENGINE and its fixtures. It is not consumer proof, and
# nothing here proves that any developer wrote a test first — TDD is a workflow, and these are
# evidence proxies (docs/testing-discipline-governance.md, docs/tdd-evidence-policy.md).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FAILED=0
# pass <message> — record a passing check.
pass() { printf 'PASS: %s\n' "$1"; }
# fail <message> — record a failing check and mark the suite failed.
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
# check <label> <actual> <expected> — assert equality.
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss290)
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
	e="$od/sentinel-shield-gates.env"
	case "$m" in
		report-only) x_p=false; x_mt=false; x_o=false; x_a=false ;;
		baseline)    x_p=false; x_mt=false; x_o=false; x_a=true ;;
		strict)      x_p=true;  x_mt=true;  x_o=false; x_a=true ;;
		regulated)   x_p=true;  x_mt=true;  x_o=true;  x_a=true ;;
	esac
	check "$m: production_change_without_test_change" "$(gate_val "$e" PRODUCTION_CHANGE_WITHOUT_TEST_CHANGE)" "$x_p"
	check "$m: missing_test_change_evidence"          "$(gate_val "$e" MISSING_TEST_CHANGE_EVIDENCE)" "$x_mt"
	check "$m: orphan_behavior_specifications"        "$(gate_val "$e" ORPHAN_BEHAVIOR_SPECIFICATIONS)" "$x_o"
	check "$m: acceptance_test_failures"              "$(gate_val "$e" ACCEPTANCE_TEST_FAILURES)" "$x_a"
done

# BDD/ATDD evidence is demanded from APP profiles only — a library is never forced into it.
mkdir -p "$WORK/p"
printf 'project:\n  name: app\n  type: laravel\nprofiles:\n  - laravel\ngates:\n  mode: strict\n' > "$WORK/p/app.yaml"
printf 'project:\n  name: lib\n  type: php-library\nprofiles:\n  - php-library\ngates:\n  mode: regulated\n' > "$WORK/p/lib.yaml"
sh "$RESOLVE" --profile "$WORK/p/app.yaml" --output-dir "$WORK/g-app" --format env >/dev/null 2>&1
sh "$RESOLVE" --profile "$WORK/p/lib.yaml" --output-dir "$WORK/g-lib" --format env >/dev/null 2>&1
check "laravel strict requires BDD evidence"  "$(gate_val "$WORK/g-app/sentinel-shield-gates.env" MISSING_BEHAVIOR_SPECIFICATION)" "true"
check "laravel strict requires ATDD evidence" "$(gate_val "$WORK/g-app/sentinel-shield-gates.env" MISSING_ACCEPTANCE_EVIDENCE)" "true"
check "php-library regulated does NOT require BDD"  "$(gate_val "$WORK/g-lib/sentinel-shield-gates.env" MISSING_BEHAVIOR_SPECIFICATION)" "false"
check "php-library regulated does NOT require ATDD" "$(gate_val "$WORK/g-lib/sentinel-shield-gates.env" MISSING_ACCEPTANCE_EVIDENCE)" "false"

# An explicit profile override still wins over the mode default.
printf 'project:\n  name: lib\nprofiles:\n  - php-library\ngates:\n  mode: baseline\n  fail_on:\n    production_change_without_test_change: true\n' > "$WORK/p/ovr.yaml"
sh "$RESOLVE" --profile "$WORK/p/ovr.yaml" --output-dir "$WORK/g-ovr" --format env >/dev/null 2>&1
check "explicit fail_on override applied in baseline" "$(gate_val "$WORK/g-ovr/sentinel-shield-gates.env" PRODUCTION_CHANGE_WITHOUT_TEST_CHANGE)" "true"

# --- (2) TDD proxy runner: classification, waivers, no diff base --------------
TCE="$RUNNERS/test-change-evidence.sh"
# mkrepo <dir> — a git repo with production, test, docs and config trees committed.
mkrepo() {
	mkdir -p "$1" && cd "$1" || exit 1
	git init -q . && git config user.email t@example.com && git config user.name t
	mkdir -p src tests docs config src/generated
	echo a > src/a.ts; echo t > tests/a.test.ts; echo d > docs/x.md
	echo c > config/app.yaml; echo g > src/generated/api.ts
	git add -A && git commit -qm base
}
# tce_run <out> — run the proxy against HEAD~1 and echo "status:violations:missing:expired".
tce_run() {
	sh "$TCE" --output "$1" --base HEAD~1 >/dev/null 2>&1
	jq -r '"\(.status):\(.production_change_without_test_change):\(.missing_test_change_evidence):\(.expired_waivers // 0)"' "$1"
}
R="$WORK/repo"; ( mkrepo "$R" ) >/dev/null 2>&1
cd "$R"

echo x >> src/a.ts; git commit -qam prod-only
check "production changed + no test changed -> violation" "$(tce_run "$WORK/t1.json")" "findings:1:false:0"

echo x >> src/a.ts; echo x >> tests/a.test.ts; git commit -qam prod+test
check "production changed + test changed -> pass" "$(tce_run "$WORK/t2.json")" "pass:0:false:0"

echo x >> docs/x.md; git commit -qam docs-only
check "docs-only change -> pass" "$(tce_run "$WORK/t3.json")" "pass:0:false:0"

echo x >> config/app.yaml; git commit -qam config-only
check "config-only change -> pass" "$(tce_run "$WORK/t4.json")" "pass:0:false:0"

mkdir -p .sentinel-shield
printf '{"waivers":[{"id":"TD-001","reason":"generated client","paths":["src/generated/**"],"expires_at":"2099-12-31"}]}\n' \
	> .sentinel-shield/test-discipline-waivers.json
echo x >> src/generated/api.ts; git add -A; git commit -qam gen
check "valid waiver suppresses ONLY matching paths" "$(tce_run "$WORK/t5.json")" "pass:0:false:0"

# A waived tree must not hide an UNWAIVED production change in the same diff.
echo x >> src/generated/api.ts; echo x >> src/a.ts; git add -A; git commit -qam gen+prod
check "waiver does not suppress unwaived production change" "$(tce_run "$WORK/t6.json")" "findings:1:false:0"

printf '{"waivers":[{"id":"TD-001","reason":"generated client","paths":["src/generated/**"],"expires_at":"2000-01-01"}]}\n' \
	> .sentinel-shield/test-discipline-waivers.json
echo x >> src/generated/api.ts; git add -A; git commit -qam expired
check "expired waiver does NOT suppress, and is counted" "$(tce_run "$WORK/t7.json")" "findings:1:false:1"

printf '{"waivers":[{"id":"TD-002","paths":["src/**"],"expires_at":"2099-01-01"}]}\n' \
	> .sentinel-shield/test-discipline-waivers.json
echo x >> src/a.ts; git add -A; git commit -qam noreason
check "waiver without a reason fails closed" "$(tce_run "$WORK/t8.json")" "execution-error:0:true:0"

rm -f .sentinel-shield/test-discipline-waivers.json
# A policy that narrows production_paths must be honoured.
printf 'testing_discipline:\n  tdd:\n    production_paths:\n      - packages\n' > .sentinel-shield/testing-discipline-policy.yaml
echo x >> src/a.ts; git add -A; git commit -qam narrowed
check "policy production_paths narrows what counts as production" "$(tce_run "$WORK/t9.json")" "pass:0:false:0"

printf 'testing_discipline:\n  tdd:\n    enabled: false\n' > .sentinel-shield/testing-discipline-policy.yaml
sh "$TCE" --output "$WORK/t10.json" --base HEAD~1 >/dev/null 2>&1
check "policy can disable the TDD proxy honestly" "$(jq -r '.status' "$WORK/t10.json")" "disabled"

printf 'testing_discipline:\n  tdd:\n    enabled: not-a-boolean\n' > .sentinel-shield/testing-discipline-policy.yaml
sh "$TCE" --output "$WORK/t11.json" --base HEAD~1 >/dev/null 2>&1 && _rc=0 || _rc=$?
check "malformed policy boolean fails closed (exit 2)" "$_rc" "2"
rm -f .sentinel-shield/testing-discipline-policy.yaml

cd "$WORK"
NOGIT="$WORK/nogit"; mkdir -p "$NOGIT"; cd "$NOGIT"
sh "$TCE" --output "$WORK/t12.json" >/dev/null 2>&1
check "no git base -> unavailable + missing_test_change_evidence" \
	"$(jq -r '"\(.status):\(.missing_test_change_evidence)"' "$WORK/t12.json")" "unavailable:true"
cd "$ROOT"

# --- (3) collectors -----------------------------------------------------------
C="$WORK/coll"; mkdir -p "$C"
echo '{"tool":"test-change-evidence","status":"findings","production_changed_files":3,"test_changed_files":0,"production_change_without_test_change":1,"missing_test_change_evidence":false}' > "$C/tce.json"
echo '{"tool":"behavior-specs","status":"pass","spec_count":12,"scenario_count":34,"orphan_behavior_specifications":0,"missing_behavior_specification":false}' > "$C/bs.json"
echo '{"tool":"behavior-specs","status":"pass","spec_count":3,"scenario_count":5,"orphan_behavior_specifications":2}' > "$C/bs-orphan.json"
echo '{"tool":"behavior-specs","status":"execution-error"}' > "$C/bs-err.json"
echo '{"tool":"behavior-specs","status":"totally-made-up","spec_count":9}' > "$C/bs-unknown.json"
echo '{"tool":"behavior-specs","status":"pass","spec_count":0,"scenario_count":0}' > "$C/bs-empty.json"
echo '{"tool":"acceptance-tests","status":"findings","tests":48,"failures":2,"skipped":1,"missing_acceptance_evidence":false}' > "$C/at.json"
echo '{"tool":"acceptance-tests","status":"pass","tests":10,"failures":0}' > "$C/at-pass.json"
echo '{"tool":"acceptance-tests","status":"execution-error"}' > "$C/at-err.json"
echo '{"tool":"acceptance-tests","status":"pass","tests":0,"failures":0}' > "$C/at-zero.json"
echo '{"some":"other","shape":true}' > "$C/weird.json"
echo 'not json {' > "$C/bad.json"

# cs <collector> <input> <jq> — run a collector and read one field.
cs() { sh "$COLL/$1" --input "$2" 2>/dev/null | jq -r "$3"; }

check "tce collector: violation -> summary count" \
	"$(cs test-change-evidence.sh "$C/tce.json" '.summary.production_change_without_test_change')" "1"
check "tce collector: missing report -> unavailable + report flag" \
	"$(cs test-change-evidence.sh "$C/none.json" '"\(.status):\(.tool_report.missing_test_change_evidence)"')" "unavailable:true"
check "tce collector: unrecognized shape fails closed" \
	"$(cs test-change-evidence.sh "$C/weird.json" '.status')" "execution-error"

check "bdd collector: specs+scenarios -> behavior_spec_count" \
	"$(cs behavior-specs.sh "$C/bs.json" '.summary.behavior_spec_count')" "46"
check "bdd collector: orphan specs counted" \
	"$(cs behavior-specs.sh "$C/bs-orphan.json" '.summary.orphan_behavior_specifications')" "2"
check "bdd collector: execution-error -> missing flag in report" \
	"$(cs behavior-specs.sh "$C/bs-err.json" '"\(.status):\(.tool_report.missing_behavior_specification)"')" "execution-error:true"
check "bdd collector: unknown status fails closed as execution-error" \
	"$(cs behavior-specs.sh "$C/bs-unknown.json" '.status')" "execution-error"
check "bdd collector: ran but zero specs -> missing, never a clean pass" \
	"$(cs behavior-specs.sh "$C/bs-empty.json" '.tool_report.missing_behavior_specification')" "true"

check "atdd collector: tests/failures mapped" \
	"$(cs acceptance-tests.sh "$C/at.json" '"\(.summary.acceptance_test_count):\(.summary.acceptance_test_failures)"')" "48:2"
check "atdd collector: clean run passes" \
	"$(cs acceptance-tests.sh "$C/at-pass.json" '.status')" "pass"
check "atdd collector: execution-error -> missing flag in report" \
	"$(cs acceptance-tests.sh "$C/at-err.json" '"\(.status):\(.tool_report.missing_acceptance_evidence)"')" "execution-error:true"
check "atdd collector: tests=0 -> missing evidence (documented behavior)" \
	"$(cs acceptance-tests.sh "$C/at-zero.json" '.tool_report.missing_acceptance_evidence')" "true"

sh "$COLL/acceptance-tests.sh" --input "$C/bad.json" >/dev/null 2>&1 && _rc=0 || _rc=$?
check "atdd collector: invalid JSON exits 2" "$_rc" "2"

# Collectors must never leak testing-discipline findings into security counters.
_leak=$(cs acceptance-tests.sh "$C/at.json" '[.summary.secrets,.summary.critical_vulnerabilities,.summary.high_vulnerabilities,.summary.medium_vulnerabilities]|add')
check "testing-discipline findings never touch vulnerability counters" "$_leak" "0"

# --- (4) builder: evidence is missing only when EXPECTED ----------------------
B="$WORK/build"; mkdir -p "$B/raw" "$B/tgt/.sentinel-shield"
# bflags <output> <profile> — build a summary and echo "mtce:mbs:mae".
bflags() {
	sh "$BUILD" --raw-dir "$B/raw" --output "$1" --profile "$2" --target "$B/tgt" >/dev/null 2>&1
	jq -r '.summary|"\(.missing_test_change_evidence):\(.missing_behavior_specification):\(.missing_acceptance_evidence)"' "$1"
}
check "php-library without BDD/ATDD evidence is NOT missing it" "$(bflags "$B/s1.json" php-library)" "true:false:false"
check "app profile that never opted in is NOT missing BDD/ATDD" "$(bflags "$B/s2.json" laravel)" "true:false:false"

cat > "$B/tgt/.sentinel-shield/testing-discipline-policy.yaml" <<'EOF'
testing_discipline:
  enabled: true
  bdd:
    enabled: true
    require_behavior_specs: true
  atdd:
    enabled: true
    require_acceptance_evidence: true
EOF
check "policy requiring BDD/ATDD makes absent evidence missing" "$(bflags "$B/s3.json" laravel)" "true:true:true"

cp "$ROOT/templates/raw/test-change-evidence.example.json" "$B/raw/test-change-evidence.json"
cp "$ROOT/templates/raw/behavior-specs.example.json" "$B/raw/behavior-specs.json"
cp "$ROOT/templates/raw/acceptance-tests.example.json" "$B/raw/acceptance-tests.json"
check "real evidence clears every missing_* flag" "$(bflags "$B/s4.json" laravel)" "false:false:false"

echo '{"tool":"acceptance-tests","status":"pass","tests":0,"failures":0}' > "$B/raw/acceptance-tests.json"
check "acceptance suite with 0 tests reads as MISSING, not clean" "$(bflags "$B/s5.json" laravel)" "false:false:true"
cp "$ROOT/templates/raw/acceptance-tests.example.json" "$B/raw/acceptance-tests.json"

printf 'testing_discipline:\n  enabled: false\n' > "$B/tgt/.sentinel-shield/testing-discipline-policy.yaml"
rm -f "$B/raw/behavior-specs.json" "$B/raw/acceptance-tests.json"
check "policy can disable the whole channel honestly" "$(bflags "$B/s6.json" laravel)" "false:false:false"
rm -f "$B/tgt/.sentinel-shield/testing-discipline-policy.yaml"

# Cross-producer aggregation + channel separation.
cp "$ROOT/templates/raw/behavior-specs.example.json" "$B/raw/behavior-specs.json"
cp "$ROOT/templates/raw/acceptance-tests.example.json" "$B/raw/acceptance-tests.json"
sh "$BUILD" --raw-dir "$B/raw" --output "$B/agg.json" --project-name t >/dev/null 2>&1
check "builder sums behavior_spec_count" "$(jq -r '.summary.behavior_spec_count' "$B/agg.json")" "46"
check "builder maps acceptance failures"  "$(jq -r '.summary.acceptance_test_failures' "$B/agg.json")" "2"
check "builder maps the TDD proxy count"  "$(jq -r '.summary.production_change_without_test_change' "$B/agg.json")" "1"
check "testing discipline never enters security counters" \
	"$(jq -r '[.summary.secrets,.summary.critical_vulnerabilities,.summary.high_vulnerabilities,.summary.architecture_violations]|add' "$B/agg.json")" "0"

# A summary that predates v2.2.0 must stay valid: absent testing-discipline keys read as
# 0/false and never block. Built from a clean pre-v2.2.0 shape (SBOM/release evidence present)
# so the ONLY thing under test here is the absence of the new keys.
cat > "$B/old.json" <<'EOF'
{"version":"1.0","generated_at":"2026-07-19T00:00:00Z",
 "summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,
  "medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,
  "unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,
  "missing_release_evidence":false,"expired_exceptions":0},
 "exceptions":{"active":0,"expired":0},
 "evidence":{"sbom":{"present":true,"path":"reports/sbom.spdx.json"},
  "release_evidence":{"present":true,"path":"reports/release-evidence.md"}}}
EOF

# --- (5) enforcer -------------------------------------------------------------
# enf <summary> <mode> — enforce and echo the exit code.
enf() {
	sh "$RESOLVE" --mode "$2" --output-dir "$WORK/e" --format env >/dev/null 2>&1
	sh "$ENFORCE" --gates-env "$WORK/e/sentinel-shield-gates.env" --summary "$1" \
		--output-dir "$WORK/e" --format json >/dev/null 2>&1 && printf 0 || printf 1
}
check "pre-v2.2.0 summary still enforces cleanly (absent = 0/false)" "$(enf "$B/old.json" regulated)" "0"

printf '{"version":"1.0","generated_at":"2026-07-19T00:00:00Z","summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,"missing_release_evidence":false,"expired_exceptions":0,%s}}\n' \
	'"production_change_without_test_change":1' > "$WORK/sum-tdd.json"
check "TDD proxy violation does NOT block in baseline" "$(enf "$WORK/sum-tdd.json" baseline)" "0"
check "TDD proxy violation blocks in strict"           "$(enf "$WORK/sum-tdd.json" strict)" "1"

printf '{"version":"1.0","generated_at":"2026-07-19T00:00:00Z","summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,"missing_release_evidence":false,"expired_exceptions":0,%s}}\n' \
	'"acceptance_test_failures":2' > "$WORK/sum-atf.json"
check "acceptance failures block from baseline when evidence exists" "$(enf "$WORK/sum-atf.json" baseline)" "1"

printf '{"version":"1.0","generated_at":"2026-07-19T00:00:00Z","summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,"missing_release_evidence":false,"expired_exceptions":0,%s}}\n' \
	'"orphan_behavior_specifications":3' > "$WORK/sum-orph.json"
check "orphan behavior specs do NOT block in strict"  "$(enf "$WORK/sum-orph.json" strict)" "0"
check "orphan behavior specs block in regulated"      "$(enf "$WORK/sum-orph.json" regulated)" "1"

printf '{"version":"1.0","generated_at":"2026-07-19T00:00:00Z","summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"missing_sbom":false,"missing_release_evidence":false,"expired_exceptions":0,%s}}\n' \
	'"missing_test_change_evidence":true' > "$WORK/sum-mtce.json"
check "missing changed-file evidence blocks in strict" "$(enf "$WORK/sum-mtce.json" strict)" "1"
check "missing changed-file evidence is quiet in baseline" "$(enf "$WORK/sum-mtce.json" baseline)" "0"

# --- (6) documentation honesty ------------------------------------------------
DOC="$ROOT/docs/testing-discipline-governance.md"
if [ -f "$DOC" ]; then
	pass "docs/testing-discipline-governance.md present"
	for _claim in "proves true TDD" "guarantees BDD quality" "replaces product-owner acceptance"; do
		if grep -qi "Sentinel Shield $_claim" "$DOC"; then
			fail "docs make the forbidden claim: 'Sentinel Shield $_claim'"
		else
			pass "docs avoid the claim 'Sentinel Shield $_claim'"
		fi
	done
	grep -qi 'cannot be proven from final code\|cannot prove' "$DOC" \
		&& pass "docs state that TDD cannot be proven from final code" \
		|| fail "docs must state that TDD cannot be proven from final code"
else
	fail "docs/testing-discipline-governance.md missing"
fi

# --- summary ------------------------------------------------------------------
if [ "$FAILED" -eq 0 ]; then
	printf '\n290-testing-discipline-governance: ALL CHECKS PASSED\n'
else
	printf '\n290-testing-discipline-governance: FAILURES PRESENT\n'
fi
exit "$FAILED"
