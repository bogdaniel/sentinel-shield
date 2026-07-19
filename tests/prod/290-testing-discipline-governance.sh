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

# --- (2b) policy fallback parser (no mikefarah yq) -----------------------------
# Consumers are NOT required to install yq, so the awk fallback must read the same policy —
# including LIST fields — and fail closed the same way. A shim that reports a non-mikefarah
# version forces the fallback even on a machine where yq v4 is installed.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\necho "yq version 3.4.1 (python)"\n' > "$SHIM/yq"
chmod +x "$SHIM/yq"
FB="$WORK/fallback"; mkdir -p "$FB/.sentinel-shield"
(
	cd "$FB" || exit 1
	git init -q . && git config user.email t@example.com && git config user.name t
	mkdir -p src tests packages
	echo a > src/a.ts; echo t > tests/a.test.ts; echo p > packages/x.ts
	git add -A && git commit -qm base
) >/dev/null 2>&1
cat > "$FB/.sentinel-shield/testing-discipline-policy.yaml" <<'EOF'
testing_discipline:
  enabled: true
  tdd:
    enabled: true
    production_paths:
      - packages
    test_paths:
      - tests
EOF
cd "$FB"
# fb_run <out> — run the proxy with the yq shim first on PATH (fallback parser active).
fb_run() {
	PATH="$SHIM:$PATH" sh "$TCE" --output "$1" --base HEAD~1 >/dev/null 2>&1
	jq -r '"\(.status):\(.production_change_without_test_change)"' "$1"
}
echo x >> src/a.ts; git commit -qam src-only
check "fallback parser reads production_paths (src excluded)" "$(fb_run "$WORK/f1.json")" "pass:0"
echo x >> packages/x.ts; git commit -qam pkg-only
check "fallback parser: declared production path violates" "$(fb_run "$WORK/f2.json")" "findings:1"
echo x >> packages/x.ts; echo x >> tests/a.test.ts; git commit -qam pkg+test
check "fallback parser reads test_paths (test change clears)" "$(fb_run "$WORK/f3.json")" "pass:0"

printf 'testing_discipline:\n  tdd:\n    enabled: maybe\n' > "$FB/.sentinel-shield/testing-discipline-policy.yaml"
PATH="$SHIM:$PATH" sh "$TCE" --output "$WORK/f4.json" --base HEAD~1 >/dev/null 2>&1 && _rc=0 || _rc=$?
check "fallback parser: malformed boolean exits 2" "$_rc" "2"
printf 'testing_discipline:\n  tdd:\n    enabled: &a true\n' > "$FB/.sentinel-shield/testing-discipline-policy.yaml"
PATH="$SHIM:$PATH" sh "$TCE" --output "$WORK/f5.json" --base HEAD~1 >/dev/null 2>&1 && _rc=0 || _rc=$?
check "fallback parser: advanced YAML (anchor) exits 2" "$_rc" "2"
printf 'testing_discipline:\n  tdd:\n    production_paths:\n' > "$FB/.sentinel-shield/testing-discipline-policy.yaml"
PATH="$SHIM:$PATH" sh "$TCE" --output "$WORK/f6.json" --base HEAD~1 >/dev/null 2>&1 && _rc=0 || _rc=$?
check "fallback parser: present-but-empty list exits 2" "$_rc" "2"
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

# Cross-producer aggregation + channel separation. Purpose-built FINDING-bearing fixtures are
# used here rather than templates/raw/*.example.json: those templates are seeded by
# `self-test.sh lifecycle`, which requires them to stay gate-clean, so they cannot double as
# findings fixtures.
AGG="$WORK/agg"; mkdir -p "$AGG/raw"
echo '{"tool":"behavior-specs","producer":"behat","status":"pass","spec_count":12,"scenario_count":34,"orphan_behavior_specifications":0,"missing_behavior_specification":false}' > "$AGG/raw/behat-specs.json"
echo '{"tool":"acceptance-tests","producer":"playwright","status":"findings","tests":48,"failures":2,"skipped":1,"missing_acceptance_evidence":false}' > "$AGG/raw/playwright-acceptance.json"
echo '{"tool":"test-change-evidence","status":"findings","production_changed_files":3,"test_changed_files":0,"production_change_without_test_change":1,"missing_test_change_evidence":false}' > "$AGG/raw/test-change-evidence.json"
sh "$BUILD" --raw-dir "$AGG/raw" --output "$AGG/agg.json" --project-name t >/dev/null 2>&1
check "builder sums behavior_spec_count" "$(jq -r '.summary.behavior_spec_count' "$AGG/agg.json")" "46"
check "builder maps acceptance failures"  "$(jq -r '.summary.acceptance_test_failures' "$AGG/agg.json")" "2"
check "builder maps the TDD proxy count"  "$(jq -r '.summary.production_change_without_test_change' "$AGG/agg.json")" "1"
check "testing discipline never enters security counters" \
	"$(jq -r '[.summary.secrets,.summary.critical_vulnerabilities,.summary.high_vulnerabilities,.summary.architecture_violations]|add' "$AGG/agg.json")" "0"

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

# --- (4b) multi-producer aggregation: distinct raw paths, no overwrite ---------
# Every ATDD/BDD producer writes its OWN raw report. Sharing one path meant the producer that
# ran last silently destroyed the earlier producer's evidence BEFORE the collector saw it,
# undercounting acceptance_test_count / acceptance_test_failures. These assert the fix.
MP="$WORK/multi"; mkdir -p "$MP/raw"
echo '{"tool":"acceptance-tests","producer":"playwright","status":"pass","tests":10,"failures":0,"missing_acceptance_evidence":false}' > "$MP/raw/playwright-acceptance.json"
echo '{"tool":"acceptance-tests","producer":"cypress","status":"findings","tests":7,"failures":2,"missing_acceptance_evidence":false}' > "$MP/raw/cypress-acceptance.json"
echo '{"tool":"behavior-specs","producer":"behat","status":"pass","spec_count":2,"scenario_count":6,"missing_behavior_specification":false}' > "$MP/raw/behat-specs.json"
echo '{"tool":"behavior-specs","producer":"cucumber-js","status":"pass","spec_count":1,"scenario_count":4,"missing_behavior_specification":false}' > "$MP/raw/cucumber-specs.json"
sh "$BUILD" --raw-dir "$MP/raw" --output "$MP/sum.json" --project-name t >/dev/null 2>&1
check "two ATDD producers SUM acceptance_test_count (10+7)" \
	"$(jq -r '.summary.acceptance_test_count' "$MP/sum.json")" "17"
check "two ATDD producers SUM acceptance_test_failures (0+2)" \
	"$(jq -r '.summary.acceptance_test_failures' "$MP/sum.json")" "2"
check "two BDD producers SUM behavior_spec_count (8+5)" \
	"$(jq -r '.summary.behavior_spec_count' "$MP/sum.json")" "13"
check "playwright evidence survives alongside cypress" \
	"$(jq -r '.tools.playwright_acceptance.status' "$MP/sum.json")" "pass"
check "cypress evidence survives alongside playwright" \
	"$(jq -r '.tools.cypress_acceptance.status' "$MP/sum.json")" "findings"
check "behat + cucumber spec evidence both survive" \
	"$(jq -r '"\(.tools.behat_specs.status):\(.tools.cucumber_specs.status)"' "$MP/sum.json")" "pass:pass"

# Within ANY single profile, no two testing-discipline producers may declare the same raw report
# path — that is the overwrite defect class. (The same path recurring ACROSS profiles is fine and
# expected: laravel and symfony both use behat-specs.json, but they never run together.)
_dupe=""
for f in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.json; do
	_d=$(jq -r '(.tools // {}) | to_entries[]
			| select((.value.category // "") | IN("bdd","atdd","testing-discipline"))
			| .value.report // empty' "$f" | sort | uniq -d)
	[ -n "$_d" ] && _dupe="$_dupe$(basename "$f"):$(printf '%s' "$_d" | tr '\n' ',') "
done
check "no profile declares two producers writing the same raw report" "${_dupe:-none}" "none"

# The generic contract file stays supported for a custom/manual producer and must not collide
# with any profile-declared producer path.
_generic=$(for f in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.json; do
		jq -r '(.tools // {}) | to_entries[] | .value.report // empty' "$f"
	done | grep -cE '/(acceptance-tests|behavior-specs)\.json$' || true)
check "no profile tool claims the generic acceptance-tests/behavior-specs path" "${_generic:-0}" "0"

# --- (4c) policy channel switches vs a REQUIRED profile producer ---------------
# An explicit `bdd.enabled: false` / `atdd.enabled: false` is the project stating the channel
# does not apply. That must beat a profile that declares a required producer — otherwise a
# profile default silently overrides an explicit project decision.
CH="$WORK/chan"; mkdir -p "$CH/raw" "$CH/tgt/.sentinel-shield"
CHOV="$CH/tgt/.sentinel-shield/tool-policy-override.json"
printf '{"tools":{"cucumber-specs":{"policy":"required"},"playwright-acceptance":{"policy":"required"}}}\n' > "$CHOV"
CHPOL="$CH/tgt/.sentinel-shield/testing-discipline-policy.yaml"
# chan_flags — build with the required-producer override and echo "mbs:mae".
chan_flags() {
	sh "$BUILD" --raw-dir "$CH/raw" --output "$CH/sum.json" --profile react --target "$CH/tgt" \
		--override "$CHOV" >/dev/null 2>&1
	jq -r '.summary|"\(.missing_behavior_specification):\(.missing_acceptance_evidence)"' "$CH/sum.json"
}
rm -f "$CHPOL"
check "required producers + no policy + no reports -> both missing" "$(chan_flags)" "true:true"

printf 'testing_discipline:\n  enabled: true\n  bdd:\n    enabled: false\n  atdd:\n    enabled: false\n' > "$CHPOL"
check "policy bdd/atdd enabled:false vetoes a REQUIRED producer" "$(chan_flags)" "false:false"

printf 'testing_discipline:\n  enabled: false\n' > "$CHPOL"
check "master switch enabled:false disables all channels" "$(chan_flags)" "false:false"

printf 'testing_discipline:\n  enabled: true\n  bdd:\n    enabled: true\n    require_behavior_specs: true\n  atdd:\n    enabled: true\n    require_acceptance_evidence: true\n' > "$CHPOL"
check "policy requiring both channels + no reports -> both missing" "$(chan_flags)" "true:true"

echo '{"tool":"behavior-specs","producer":"cucumber-js","status":"pass","spec_count":2,"scenario_count":6,"missing_behavior_specification":false}' > "$CH/raw/cucumber-specs.json"
echo '{"tool":"acceptance-tests","producer":"playwright","status":"pass","tests":10,"failures":0,"missing_acceptance_evidence":false}' > "$CH/raw/playwright-acceptance.json"
check "required producers reporting evidence clear both flags" "$(chan_flags)" "false:false"

rm -f "$CH/raw/playwright-acceptance.json"
check "one expected ATDD producer missing -> acceptance evidence missing" "$(chan_flags)" "false:true"

# --- (4d) seeded-fixture corpus stays gate-clean -------------------------------
# scripts/self-test.sh lifecycle seeds EVERY templates/raw/*.example.json and asserts a passing
# BASELINE gate run. A fixture carrying a baseline-blocking finding turns the whole pipeline
# self-test red (this is exactly what broke CI on the first push of this feature).
LC="$WORK/lifecycle"; mkdir -p "$LC/raw"
cp "$ROOT"/templates/raw/*.example.json "$LC/raw/" 2>/dev/null || true
for _f in "$LC"/raw/*.example.json; do mv "$_f" "${_f%.example.json}.json"; done
sh "$BUILD" --raw-dir "$LC/raw" --output "$LC/sum.json" --project-name t >/dev/null 2>&1
sh "$RESOLVE" --mode baseline --output-dir "$LC" --format env >/dev/null 2>&1
sh "$ENFORCE" --gates-env "$LC/sentinel-shield-gates.env" --summary "$LC/sum.json" \
	--output-dir "$LC" --format json >/dev/null 2>&1 && _lc=0 || _lc=1
check "seeded templates/raw fixture corpus passes a BASELINE gate run" "$_lc" "0"
check "fixture corpus reports no acceptance failures" \
	"$(jq -r '.summary.acceptance_test_failures' "$LC/sum.json")" "0"
check "fixture corpus reports no TDD-proxy violation" \
	"$(jq -r '.summary.production_change_without_test_change' "$LC/sum.json")" "0"

# --- (4e) adoption ramp: the TDD proxy must not use the required-tool channel --
# REGRESSION GUARD. Shipping test-change-evidence as policy `required` made every profile's PR
# gate fail the moment the report was absent — via required_tool_failures, which is ALWAYS on and
# ignores the mode. That defeats the whole report-only -> baseline -> strict ramp and broke all
# five e2e fixtures. It must ship as `recommended` (the deptrac/v2.1.0 precedent): evidence is
# still EXPECTED, but only the MODE decides whether its absence blocks.
_badpol=""
for f in "$ROOT"/profiles/*/profile.manifest.json; do
	_p=$(jq -r '(.tools["test-change-evidence"].policy) // "absent"' "$f")
	[ "$_p" = "required" ] && _badpol="$_badpol$(basename "$(dirname "$f")") "
done
check "test-change-evidence is never profile-policy 'required'" "${_badpol:-none}" "none"

# ...and it must STILL be expected, or the gate would be inert.
RAMP="$WORK/ramp"; mkdir -p "$RAMP/raw" "$RAMP/tgt"
sh "$BUILD" --raw-dir "$RAMP/raw" --output "$RAMP/s.json" --profile laravel --target "$RAMP/tgt" >/dev/null 2>&1
check "a RECOMMENDED TDD producer still yields missing evidence when absent" \
	"$(jq -r '.summary.missing_test_change_evidence' "$RAMP/s.json")" "true"
# The claim is about THIS tool, not the raw-dir as a whole (an empty raw dir naturally leaves
# every other required tool unavailable): test-change-evidence must not be gate-enforced through
# the required-tool channel, so its absence is judged by the mode-tiered gate alone.
check "an absent TDD producer is not gate-enforced via the required-tool channel" \
	"$(jq -r '.tools.test_change_evidence.gate_enforced // false' "$RAMP/s.json")" "false"
cp "$ROOT/templates/raw/test-change-evidence.example.json" "$RAMP/raw/test-change-evidence.json"
sh "$BUILD" --raw-dir "$RAMP/raw" --output "$RAMP/s.json" --profile laravel --target "$RAMP/tgt" >/dev/null 2>&1
check "real TDD evidence clears missing_test_change_evidence" \
	"$(jq -r '.summary.missing_test_change_evidence' "$RAMP/s.json")" "false"

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
