#!/bin/sh
# Sentinel Shield — self-test harness.
#
# Exercises the core enforcement lifecycle against fixture data so Sentinel Shield
# continuously tests ITSELF (YAML validity alone does not prove behavior). Used by
# .github/workflows/ci-self-test.yml and runnable locally.
#
# Subcommands:
#   syntax     sh -n over all scripts + jq-validate templates/ and schemas/ JSON
#   lifecycle  build -> resolve -> select -> enforce -> generate-report (clean run)
#   fallback   assert the fallback policy exit codes (fail-closed outside report-only)
#   all        run all of the above (default)
#
# POSIX sh, set -eu, jq required. Exits non-zero on any failure.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
cd "$ROOT"

command_exists jq || { log_error "jq is required for the self-test"; exit 2; }

SUB="${1:-all}"

# --- syntax ------------------------------------------------------------------
run_syntax() {
	log_info "syntax: sh -n over scripts (incl. runners/ audits/ adapters/ — required by v2 validation)"
	# scripts/adapters/*.sh may not match (adapters are .mjs/.php); the [ -e ] guard skips the
	# literal-pattern case POSIX sh leaves behind when a glob has no match.
	for f in scripts/*.sh scripts/lib/*.sh scripts/collectors/*.sh \
		scripts/runners/*.sh scripts/audits/*.sh scripts/adapters/*.sh; do
		[ -e "$f" ] || continue
		sh -n "$f" || { log_error "sh -n failed: $f"; return 1; }
	done
	log_info "syntax: jq-validate templates/ schemas/ profiles/ JSON"
	for f in $(find templates schemas profiles -name '*.json' 2>/dev/null); do
		jq -e . "$f" >/dev/null 2>&1 || { log_error "invalid JSON: $f"; return 1; }
	done
	log_info "syntax: .semgrepignore templates carry the key SAST exclusions"
	for f in profiles/laravel/.semgrepignore profiles/react/.semgrepignore examples/laravel-react-docker/.semgrepignore; do
		[ -f "$f" ] || { log_error "missing .semgrepignore: $f"; return 1; }
		for pat in 'vendor/' 'node_modules/'; do
			grep -q "$pat" "$f" || { log_error "$f missing exclusion: $pat"; return 1; }
		done
	done
	# The example (Laravel+Filament) must exclude the published Filament JS that
	# motivated this — guard against regressions.
	grep -q 'public/js/filament/' examples/laravel-react-docker/.semgrepignore \
		|| { log_error "example .semgrepignore missing public/js/filament/"; return 1; }

	# v0.1.6 rule-tree separation: app rules and third-party rules are physically
	# separate, and no workflow uses the broad semgrep/ catch-all for the app scan.
	log_info "syntax: app vs third-party Semgrep rule trees are separated (v0.1.6)"
	[ -d semgrep/app ] || { log_error "missing semgrep/app (app rules)"; return 1; }
	[ -d semgrep/supply-chain/third-party ] || { log_error "missing semgrep/supply-chain/third-party"; return 1; }
	[ ! -d semgrep/third-party ] || { log_error "stale semgrep/third-party still present (must move under supply-chain/)"; return 1; }
	[ ! -d semgrep/php ] || { log_error "stale semgrep/php still present (must move under semgrep/app/)"; return 1; }
	# No app config may reference third-party rules; no broad semgrep/ catch-all.
	_wf=".github/workflows/ci-security.yml .github/workflows/ci-pipeline.yml examples/laravel-react-docker/.github/workflows/sentinel-shield.yml"
	for f in $_wf; do
		# 1) app Semgrep config must point at semgrep/app, never the bare semgrep/ root.
		if grep -nE -- "--config [^ ]*/semgrep( |\\\\|\"|\$)" "$f" >/dev/null 2>&1; then
			log_error "$f uses broad 'semgrep/' catch-all config (must be semgrep/app)"; return 1
		fi
		# 2) no app-scan step may load third-party rules.
		if grep -nE -- "--config [^ ]*/semgrep/app[^ ]*third-party" "$f" >/dev/null 2>&1; then
			log_error "$f app scan references third-party rules"; return 1
		fi
		# 3) the third-party step must use the supply-chain path.
		grep -q 'semgrep/supply-chain/third-party' "$f" \
			|| { log_error "$f missing third-party scan config (semgrep/supply-chain/third-party)"; return 1; }
		# 4) app scan must reference semgrep/app.
		grep -q 'semgrep/app' "$f" \
			|| { log_error "$f missing app scan config (semgrep/app)"; return 1; }
	done
	log_info "syntax: OK"
}

# --- lifecycle ---------------------------------------------------------------
run_lifecycle() {
	log_info "lifecycle: seeding fixtures into reports/raw/"
	rm -rf reports
	mkdir -p reports/raw
	cp templates/raw/*.example.json reports/raw/
	for f in reports/raw/*.example.json; do
		mv "$f" "${f%.example.json}.json"
	done

	log_info "lifecycle: build-security-summary"
	sh scripts/build-security-summary.sh \
		--project-name proxyflux \
		--project-type laravel \
		--criticality high \
		--commit testcommit \
		--branch master \
		--workflow self-test

	log_info "lifecycle: resolve-gates"
	sh scripts/resolve-gates.sh --profile templates/profile.yaml --format all

	log_info "lifecycle: select-security-summary"
	sh scripts/select-security-summary.sh

	log_info "lifecycle: enforce-gates"
	sh scripts/enforce-gates.sh --format all

	log_info "lifecycle: generate-report"
	sh scripts/generate-report.sh .

	log_info "lifecycle: validate generated JSON"
	for f in reports/security-summary.json reports/sentinel-shield-gates.json reports/sentinel-shield-enforcement.json; do
		jq -e . "$f" >/dev/null 2>&1 || { log_error "invalid generated JSON: $f"; return 1; }
	done
	log_info "lifecycle: OK"
}

# --- fallback policy ---------------------------------------------------------
FAILS=0

# assert_select — test assertion helper (assert_select).
assert_select() {
	# assert_select <description> <expected-exit> <select args...>
	_desc=$1
	_exp=$2
	shift 2
	if sh scripts/select-security-summary.sh "$@" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	if [ "$_rc" -eq "$_exp" ]; then
		log_info "PASS: $_desc (exit $_rc)"
	else
		log_error "FAIL: $_desc (got exit $_rc, expected $_exp)"
		FAILS=$((FAILS + 1))
	fi
}

# run_fallback — self-test group 'fallback' (wired into the dispatch + 'all').
run_fallback() {
	log_info "fallback: building a real summary fixture"
	_work=$(mktemp -d)
	mkdir -p "$_work/raw"
	cp templates/raw/*.example.json "$_work/raw/"
	for f in "$_work"/raw/*.example.json; do
		mv "$f" "${f%.example.json}.json"
	done
	sh scripts/build-security-summary.sh \
		--raw-dir "$_work/raw" \
		--output "$_work/real-summary.json" \
		--project-name selftest --commit c --workflow self-test >/dev/null 2>&1

	_ex="templates/security-summary.example.json"
	cp "$_ex" "$_work/copied.json"

	# missing real summary
	assert_select "report-only + missing real summary" 0 --mode report-only --summary "$_work/none-report.json" --example "$_ex"
	assert_select "baseline + missing real summary"     1 --mode baseline    --summary "$_work/none-base.json"   --example "$_ex"
	assert_select "strict + missing real summary"       1 --mode strict      --summary "$_work/none-strict.json" --example "$_ex"
	assert_select "regulated + missing real summary"    1 --mode regulated   --summary "$_work/none-reg.json"    --example "$_ex"
	# example copied in (anti-spoof) must be rejected in baseline+
	assert_select "baseline + copied example summary"   1 --mode baseline    --summary "$_work/copied.json"      --example "$_ex"
	# a real generated summary is accepted
	assert_select "baseline + real generated summary"   0 --mode baseline    --summary "$_work/real-summary.json" --example "$_ex"

	rm -rf "$_work"

	if [ "$FAILS" -ne 0 ]; then
		log_error "fallback: $FAILS case(s) failed"
		return 1
	fi
	log_info "fallback: OK (all cases as expected)"
}

# --- negative (finding-bearing) ---------------------------------------------
# Prove that real findings actually drive enforcement: clean fixtures pass, but a
# summary carrying a gated finding fails in the relevant mode. Summaries are crafted
# deterministically from the committed example via jq (committed fixtures are never
# mutated in place).
NEG_FAILS=0

# expect_exit_code — test assertion helper (expect_exit_code).
expect_exit_code() {
	# expect_exit_code <description> <expected-exit> <command...>
	_desc=$1
	_exp=$2
	shift 2
	if "$@" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	if [ "$_rc" -eq "$_exp" ]; then
		log_info "PASS: $_desc (exit $_rc)"
	else
		log_error "FAIL: $_desc (got exit $_rc, expected $_exp)"
		NEG_FAILS=$((NEG_FAILS + 1))
	fi
}

# make_summary_with_key <outfile> <jq-mutation>
# Write a security summary derived from the example with one mutation applied.
make_summary_with_key() {
	jq "$2" templates/security-summary.example.json > "$1" \
		|| { log_error "could not craft summary: $1"; NEG_FAILS=$((NEG_FAILS + 1)); }
}

# run_enforcement_case <description> <mode> <expected-exit> <jq-mutation>
# Resolve gates for <mode>, craft a mutated summary, enforce, assert the exit code.
run_enforcement_case() {
	_d=$(mktemp -d)
	sh scripts/resolve-gates.sh --mode "$2" --output-dir "$_d" --format env >/dev/null 2>&1
	make_summary_with_key "$_d/security-summary.json" "$4"
	expect_exit_code "$1" "$3" \
		sh scripts/enforce-gates.sh \
		--gates-env "$_d/sentinel-shield-gates.env" \
		--summary "$_d/security-summary.json" \
		--output-dir "$_d" --format json
	rm -rf "$_d"
}

# run_build_case <description> <mode> <expected-exit> <raw-filename> <raw-content>
# End-to-end through a collector: write one raw artifact, BUILD the summary (so the
# collector's mapping is exercised), resolve gates for <mode>, enforce, assert.
run_build_case() {
	_d=$(mktemp -d)
	mkdir -p "$_d/raw"
	printf '%s' "$5" > "$_d/raw/$4"
	sh scripts/build-security-summary.sh --raw-dir "$_d/raw" --output "$_d/security-summary.json" \
		--project-name selftest --commit c --workflow self-test >/dev/null 2>&1
	sh scripts/resolve-gates.sh --mode "$2" --output-dir "$_d" --format env >/dev/null 2>&1
	expect_exit_code "$1" "$3" \
		sh scripts/enforce-gates.sh \
		--gates-env "$_d/sentinel-shield-gates.env" \
		--summary "$_d/security-summary.json" \
		--output-dir "$_d" --format json
	rm -rf "$_d"
}

# run_negative — self-test group 'negative' (wired into the dispatch + 'all').
run_negative() {
	log_info "negative: enforcing finding-bearing summaries"
	# Control: clean summary passes in baseline.
	run_enforcement_case "baseline + clean (control)"            baseline 0 '.'
	# Case 1
	run_enforcement_case "baseline + high vulnerability"         baseline 1 '.summary.high_vulnerabilities = 1'
	# Case 2 — medium is NOT gated in baseline
	run_enforcement_case "baseline + medium vulnerability only"  baseline 0 '.summary.medium_vulnerabilities = 1'
	# Case 3 — medium IS gated in strict
	run_enforcement_case "strict + medium vulnerability"         strict   1 '.summary.medium_vulnerabilities = 1'
	# Case 4
	run_enforcement_case "baseline + secret finding"             baseline 1 '.summary.secrets = 1'
	# Case 5
	run_enforcement_case "baseline + type errors"                baseline 1 '.summary.type_errors = 1'
	# Case 6
	run_enforcement_case "baseline + test failures"              baseline 1 '.summary.test_failures = 1'
	# Case 7
	run_enforcement_case "baseline + architecture violations"    baseline 1 '.summary.architecture_violations = 1'

	# Node/React collector mappings, exercised end-to-end through the builder.
	log_info "negative: Node/React collector mappings (build -> enforce)"
	run_build_case "baseline + typescript errors (type_errors gated)" baseline 1 \
		typescript.json '{"errors":2}'
	run_build_case "baseline + eslint security error (high_vulnerabilities gated)" baseline 1 \
		eslint.json '[{"filePath":"a.tsx","messages":[{"ruleId":"security/detect-object-injection","severity":2,"message":"x"}],"errorCount":1,"warningCount":0}]'
	run_build_case "baseline + eslint warning only (medium not gated -> pass)" baseline 0 \
		eslint.json '[{"filePath":"a.tsx","messages":[{"ruleId":"no-console","severity":1,"message":"x"}],"errorCount":0,"warningCount":1}]'
	run_build_case "strict + eslint warning only (medium gated -> fail)" strict 1 \
		eslint.json '[{"filePath":"a.tsx","messages":[{"ruleId":"no-console","severity":1,"message":"x"}],"errorCount":0,"warningCount":1}]'

	if [ "$NEG_FAILS" -ne 0 ]; then
		log_error "negative: $NEG_FAILS case(s) failed"
		return 1
	fi
	log_info "negative: OK (findings fail closed; ungated findings pass)"
}

# --- accepted-risk suppression ----------------------------------------------
# Uses fixed far-future/far-past expiry dates (deterministic, no date arithmetic):
#   2999-12-31 >= today  -> valid ; 2000-01-01 < today -> expired.
SUP_FAILS=0

# run_suppression_case <desc> <mode> <expected-exit> <summary-jq> <accepted-risks-json>
run_suppression_case() {
	_d=$(mktemp -d)
	sh scripts/resolve-gates.sh --mode "$2" --output-dir "$_d" --format env >/dev/null 2>&1
	jq "$4" templates/security-summary.example.json > "$_d/security-summary.json"
	printf '%s' "$5" > "$_d/accepted-risks.json"
	if sh scripts/enforce-gates.sh \
		--gates-env "$_d/sentinel-shield-gates.env" \
		--summary "$_d/security-summary.json" \
		--accepted-risks "$_d/accepted-risks.json" \
		--output-dir "$_d" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	if [ "$_rc" -eq "$3" ]; then
		log_info "PASS: $1 (exit $_rc)"
	else
		log_error "FAIL: $1 (got exit $_rc, expected $3)"
		SUP_FAILS=$((SUP_FAILS + 1))
	fi
	rm -rf "$_d"
}

# run_suppression — self-test group 'suppression' (wired into the dispatch + 'all').
run_suppression() {
	log_info "suppression: accepted-risk gate suppression (unsafe_docker)"
	_ad='.summary.unsafe_docker = 1'
	# v0.1.8: broad suppression requires explicit scope:gate. A legacy unscoped record no
	# longer suppresses (see run_finding_scope for the legacy/finding cases).
	_valid='{"version":"1.1","risks":[{"id":"d","gate":"unsafe_docker","scope":"gate","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2999-12-31","status":"approved"}]}'
	_pending='{"version":"1.1","risks":[{"id":"d","gate":"unsafe_docker","scope":"gate","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2999-12-31","status":"pending"}]}'
	_expired='{"version":"1.1","risks":[{"id":"d","gate":"unsafe_docker","scope":"gate","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2000-01-01","status":"approved"}]}'
	_secret='{"version":"1.1","risks":[{"id":"s","gate":"secrets","scope":"gate","owner":"plat","severity":"high","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'

	run_suppression_case "baseline + unsafe_docker=1 + no accepted risk -> fail"             baseline 1 "$_ad" '{"version":"1.1","risks":[]}'
	run_suppression_case "baseline + unsafe_docker=1 + pending risk -> fail"                 baseline 1 "$_ad" "$_pending"
	run_suppression_case "baseline + unsafe_docker=1 + expired approved risk -> fail"        baseline 1 "$_ad" "$_expired"
	run_suppression_case "baseline + unsafe_docker=1 + valid scope:gate risk -> pass"        baseline 0 "$_ad" "$_valid"
	run_suppression_case "baseline + secrets=1 + approved scope:gate risk for secrets -> fail" baseline 1 '.summary.secrets = 1' "$_secret"

	if [ "$SUP_FAILS" -ne 0 ]; then
		log_error "suppression: $SUP_FAILS case(s) failed"
		return 1
	fi
	log_info "suppression: OK (only approved/unexpired suppress; secrets never)"
}

# --- finding-scoped accepted-risk (v0.1.8) ----------------------------------
FS_FAILS=0
# run_fs_case <desc> <expected-exit> <summary-unsafe_docker> <hadolint-json> <risks-json> [expected-accepted] [expected-unaccepted]
run_fs_case() {
	_d=$(mktemp -d); mkdir -p "$_d/raw"
	sh scripts/resolve-gates.sh --mode baseline --output-dir "$_d" --format env >/dev/null 2>&1
	jq ".summary.unsafe_docker = $3" templates/security-summary.example.json > "$_d/security-summary.json"
	printf '%s' "$4" > "$_d/raw/hadolint.json"
	printf '%s' "$5" > "$_d/accepted-risks.json"
	if sh scripts/enforce-gates.sh \
		--gates-env "$_d/sentinel-shield-gates.env" \
		--summary "$_d/security-summary.json" \
		--accepted-risks "$_d/accepted-risks.json" \
		--hadolint-raw "$_d/raw/hadolint.json" \
		--output-dir "$_d" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	_ok=1
	[ "$_rc" -eq "$2" ] || _ok=0
	if [ -n "${6:-}" ]; then
		_a=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)
		_u=$(jq -r '.accepted_risks.unsafe_docker.unaccepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)
		[ "$_a" = "$6" ] || _ok=0
		[ "$_u" = "$7" ] || _ok=0
	fi
	if [ "$_ok" -eq 1 ]; then
		log_info "PASS: $1 (exit $_rc${6:+, accepted=$6, unaccepted=$7})"
	else
		log_error "FAIL: $1 (got exit $_rc, expected $2${6:+; accepted=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)/$6 unaccepted=$(jq -r '.accepted_risks.unsafe_docker.unaccepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)/$7})"
		FS_FAILS=$((FS_FAILS + 1))
	fi
	rm -rf "$_d"
}

# run_finding_scope — self-test group 'finding-scope' (wired into the dispatch + 'all').
run_finding_scope() {
	log_info "finding-scope: v0.1.8 unsafe_docker per-finding suppression"
	# Hadolint fixtures
	_h_df='[{"file":"Dockerfile","line":2,"code":"DL3018","level":"warning"}]'
	_h_prod='[{"file":"Dockerfile.prod","line":3,"code":"DL3018","level":"warning"}]'
	_h_other='[{"file":"docker/8.3/Dockerfile","line":4,"code":"DL3008","level":"warning"}]'
	_h_mix='[{"file":"Dockerfile","line":2,"code":"DL3018","level":"warning"},{"file":"Dockerfile.prod","line":3,"code":"DL3018","level":"warning"},{"file":"Dockerfile.prod","line":5,"code":"DL3018","level":"warning"},{"file":"docker/8.3/Dockerfile","line":4,"code":"DL3008","level":"warning"},{"file":"docker/8.3/Dockerfile","line":6,"code":"DL3016","level":"warning"},{"file":"docker/8.3/Dockerfile","line":7,"code":"DL4006","level":"warning"},{"file":"docker/Dockerfile.node","line":2,"code":"DL3008","level":"warning"}]'
	# Risk records
	_r_fs='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["Dockerfile","Dockerfile.prod"],"owner":"plat","severity":"medium","reason":"brittle","expires_at":"2999-12-31","status":"approved"}]}'
	_r_legacy='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","owner":"plat","severity":"medium","reason":"brittle","expires_at":"2999-12-31","status":"approved"}]}'
	_r_gate='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"gate","owner":"plat","severity":"medium","reason":"brittle","expires_at":"2999-12-31","status":"approved"}]}'
	_r_pending='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["Dockerfile","Dockerfile.prod"],"owner":"plat","severity":"medium","reason":"brittle","expires_at":"2999-12-31","status":"pending"}]}'
	_r_expired='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["Dockerfile","Dockerfile.prod"],"owner":"plat","severity":"medium","reason":"brittle","expires_at":"2000-01-01","status":"approved"}]}'
	_r_secret='{"version":"1.1","risks":[{"id":"s","gate":"secrets","scope":"finding","rule_id":"X","files":["a"],"owner":"plat","severity":"high","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'

	run_fs_case "DL3018 in Dockerfile + matching finding-scope risk -> accepted-risk"        0 1 "$_h_df"   "$_r_fs"     1 0
	run_fs_case "DL3018 in Dockerfile.prod + matching finding-scope risk -> accepted-risk"   0 1 "$_h_prod" "$_r_fs"     1 0
	run_fs_case "DL3008 in docker/8.3/Dockerfile + only DL3018 risk -> fail"                 1 1 "$_h_other" "$_r_fs"    0 1
	run_fs_case "mixed: 3 DL3018 accepted, 4 others unaccepted -> fail"                      1 7 "$_h_mix"  "$_r_fs"     3 4
	run_fs_case "legacy risk without scope -> does NOT suppress (fail)"                      1 1 "$_h_df"   "$_r_legacy" 0 1
	run_fs_case "legacy risk scope:gate -> suppresses whole gate (accepted-risk)"           0 7 "$_h_mix"  "$_r_gate"   7 0
	run_fs_case "pending finding-scope risk -> no suppression (fail)"                        1 1 "$_h_df"   "$_r_pending" 0 1
	run_fs_case "expired finding-scope risk -> no suppression (fail)"                        1 1 "$_h_df"   "$_r_expired" 0 1

	# secrets can never be suppressed — even by a (finding- or gate-scope) record.
	_sd=$(mktemp -d); mkdir -p "$_sd/raw"
	sh scripts/resolve-gates.sh --mode baseline --output-dir "$_sd" --format env >/dev/null 2>&1
	jq '.summary.secrets = 1' templates/security-summary.example.json > "$_sd/security-summary.json"
	printf '%s' "$_r_secret" > "$_sd/accepted-risks.json"
	if sh scripts/enforce-gates.sh --gates-env "$_sd/sentinel-shield-gates.env" --summary "$_sd/security-summary.json" --accepted-risks "$_sd/accepted-risks.json" --output-dir "$_sd" --format json >/dev/null 2>&1; then _src=0; else _src=$?; fi
	if [ "$_src" -eq 1 ]; then log_info "PASS: secrets=1 + accepted-risk for secrets -> fail (never suppressed) (exit $_src)"; else log_error "FAIL: secrets suppression (got exit $_src, expected 1)"; FS_FAILS=$((FS_FAILS + 1)); fi
	rm -rf "$_sd"

	if [ "$FS_FAILS" -ne 0 ]; then
		log_error "finding-scope: $FS_FAILS case(s) failed"
		return 1
	fi
	log_info "finding-scope: OK (per-finding rule_id+file matching; legacy unscoped & secrets never broad-suppress)"
}

# --- third-party supply-chain scan ------------------------------------------
TP_FAILS=0
tp_check() { # tp_check <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; TP_FAILS=$((TP_FAILS + 1)); fi
}

# run_third_party — self-test group 'third-party' (wired into the dispatch + 'all').
run_third_party() {
	log_info "third-party: collector + gates (fixture-driven, no real Semgrep)"
	_d=$(mktemp -d)

	# 1. Missing raw -> unavailable, counts 0.
	_u=$(sh scripts/collectors/third-party-semgrep.sh --input "$_d/none.json" --tool-name third_party_semgrep 2>/dev/null)
	tp_check "missing raw -> status unavailable" "$(printf '%s' "$_u" | jq -r .status)" "unavailable"

	# 2/3. Fixture -> category counts (3 suspicious incl. metadata fallback, 1 each others).
	_c=$(sh scripts/collectors/third-party-semgrep.sh --input templates/raw/third-party-semgrep.example.json --tool-name third_party_semgrep 2>/dev/null)
	tp_check "fixture -> third_party_suspicious_code"     "$(printf '%s' "$_c" | jq -r .summary.third_party_suspicious_code)"     "3"
	tp_check "fixture -> third_party_install_script_risk" "$(printf '%s' "$_c" | jq -r .summary.third_party_install_script_risk)" "1"
	tp_check "fixture -> third_party_obfuscation"         "$(printf '%s' "$_c" | jq -r .summary.third_party_obfuscation)"         "1"
	tp_check "fixture -> third_party_network_behavior"    "$(printf '%s' "$_c" | jq -r .summary.third_party_network_behavior)"    "1"

	# Build a summary that carries third-party findings (from the fixture only).
	mkdir -p "$_d/raw"
	cp templates/raw/third-party-semgrep.example.json "$_d/raw/third-party-semgrep.json"
	sh scripts/build-security-summary.sh --raw-dir "$_d/raw" --output "$_d/security-summary.json" \
		--project-name tp --commit c --workflow self-test >/dev/null 2>&1
	tp_check "build -> summary carries third_party_install_script_risk" \
		"$(jq -r '.summary.third_party_install_script_risk' "$_d/security-summary.json")" "1"

	# 4. report-only does NOT block third-party findings.
	sh scripts/resolve-gates.sh --mode report-only --output-dir "$_d" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/security-summary.json" --output-dir "$_d" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tp_check "report-only does not block third-party" "$_rc" "0"

	# 5. regulated blocks third-party findings; the four gates appear in failed_gates.
	sh scripts/resolve-gates.sh --mode regulated --output-dir "$_d" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/security-summary.json" --output-dir "$_d" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tp_check "regulated blocks (exit 1)" "$_rc" "1"
	_failed=$(jq -r '[.failed_gates[]|select(startswith("third_party"))]|length' "$_d/sentinel-shield-enforcement.json")
	tp_check "regulated: all 4 third-party gates failed" "$_failed" "4"

	rm -rf "$_d"
	if [ "$TP_FAILS" -ne 0 ]; then
		log_error "third-party: $TP_FAILS case(s) failed"
		return 1
	fi
	log_info "third-party: OK (separate channel; report-only non-blocking; regulated blocks)"
}

# --- hadolint multi-Dockerfile discovery (v0.1.7) ---------------------------
HL_FAILS=0
hl_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; HL_FAILS=$((HL_FAILS + 1)); fi; }

# run_hadolint — self-test group 'hadolint' (wired into the dispatch + 'all').
run_hadolint() {
	log_info "hadolint: multi-Dockerfile discovery + merge (no real Hadolint needed)"
	_rh="$PWD/scripts/run-hadolint.sh"
	_d=$(mktemp -d)
	# Fixture: root Dockerfile + Dockerfile.prod, a docker/** Dockerfile, and
	# generated dirs that MUST be excluded.
	mkdir -p "$_d/docker/php" "$_d/vendor" "$_d/node_modules/p"
	printf 'FROM alpine:3.20\n' > "$_d/Dockerfile"
	printf 'FROM alpine:3.20\n' > "$_d/Dockerfile.prod"
	printf 'FROM php:8.3-fpm-alpine\n' > "$_d/docker/php/Dockerfile"
	printf 'FROM x\n' > "$_d/vendor/Dockerfile"
	printf 'FROM x\n' > "$_d/node_modules/p/Dockerfile"
	_list=$( cd "$_d" && sh "$_rh" --list )
	hl_check "discovery includes Dockerfile"        "$(printf '%s\n' "$_list" | grep -c '^\./Dockerfile$')" "1"
	hl_check "discovery includes Dockerfile.prod"   "$(printf '%s\n' "$_list" | grep -c 'Dockerfile\.prod$')" "1"
	hl_check "discovery includes docker/** Dockerfile" "$(printf '%s\n' "$_list" | grep -c 'docker/php/Dockerfile$')" "1"
	hl_check "discovery EXCLUDES vendor/node_modules" "$(printf '%s\n' "$_list" | grep -c -E 'vendor/|node_modules/')" "0"

	# Missing Dockerfiles -> --list prints nothing, exits 0.
	_empty=$(mktemp -d)
	# `_out=$(...); _rc=$?` is unsafe under `set -eu` (line 15): the assignment is itself a
	# simple command, so a non-zero exit aborts the whole harness BEFORE _rc is read — and
	# it aborts silently, producing no FAIL line, in exactly the failure case the next two
	# assertions exist to detect. Capture the status explicitly instead.
	_rc=0; _out=$( cd "$_empty" && sh "$_rh" --list ) || _rc=$?
	hl_check "no Dockerfiles -> empty list" "$(printf '%s' "$_out" | wc -c | tr -d ' ')" "0"
	hl_check "no Dockerfiles -> exit 0" "$_rc" "0"

	# Merged Hadolint JSON (two files) stays valid and the collector maps unsafe_docker.
	mkdir -p "$_d/reports/raw"
	cat > "$_d/reports/raw/hadolint.json" <<'JSON'
[
  {"file":"Dockerfile","line":2,"code":"DL3018","level":"warning","message":"Pin versions in apk add"},
  {"file":"Dockerfile.prod","line":3,"code":"DL3018","level":"warning","message":"Pin versions in apk add"},
  {"file":"Dockerfile.prod","line":5,"code":"DL3008","level":"info","message":"info-only"}
]
JSON
	jq -e 'type=="array"' "$_d/reports/raw/hadolint.json" >/dev/null 2>&1 \
		&& hl_check "merged hadolint.json is valid array" "ok" "ok" \
		|| hl_check "merged hadolint.json is valid array" "bad" "ok"
	_ud=$(sh scripts/collectors/hadolint.sh --input "$_d/reports/raw/hadolint.json" --tool-name hadolint | jq -r '.summary.unsafe_docker')
	hl_check "collector maps merged findings -> unsafe_docker (2 warnings, info ignored)" "$_ud" "2"

	rm -rf "$_d" "$_empty"
	if [ "$HL_FAILS" -ne 0 ]; then log_error "hadolint: $HL_FAILS case(s) failed"; return 1; fi
	log_info "hadolint: OK (multi-Dockerfile discovery, exclusions, merge, collector mapping)"
}

# --- consolidation pieces (v0.1.9): adapters, runner, audits, templates -----
AD_FAILS=0
ad_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; AD_FAILS=$((AD_FAILS + 1)); fi; }

# run_adapters — self-test group 'adapters' (wired into the dispatch + 'all').
run_adapters() {
	log_info "consolidation: test adapters, runner, pin audit, base-digest detector, templates"
	_d=$(mktemp -d)

	# --- test adapters -> {failures, errors} ---
	# Vitest / Jest (Node).
	if command -v node >/dev/null 2>&1; then
		printf '%s' '{"numFailedTests":2,"numFailedTestSuites":1}' > "$_d/vitest.json"
		node scripts/adapters/vitest-to-tests-json.mjs "$_d/vitest.json" "$_d/tv.json" >/dev/null 2>&1
		ad_check "vitest adapter parses JSON (failures)" "$(jq -r '.failures' "$_d/tv.json" 2>/dev/null)" "2"
		ad_check "vitest adapter parses JSON (errors)"   "$(jq -r '.errors' "$_d/tv.json" 2>/dev/null)" "1"
		printf '%s' '{"numFailedTests":3,"numRuntimeErrorTestSuites":1}' > "$_d/jest.json"
		node scripts/adapters/jest-to-tests-json.mjs "$_d/jest.json" "$_d/tj.json" >/dev/null 2>&1
		ad_check "jest adapter parses JSON (failures)" "$(jq -r '.failures' "$_d/tj.json" 2>/dev/null)" "3"
		if printf 'not json' | node scripts/adapters/vitest-to-tests-json.mjs - "$_d/x.json" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
		ad_check "vitest adapter fails on invalid input (no fake)" "$_rc" "2"
	else
		log_warn "node not found; SKIPPING vitest/jest adapter tests"
	fi
	# PHPUnit (PHP).
	if command -v php >/dev/null 2>&1; then
		printf '%s' '<?xml version="1.0"?><testsuites tests="3" failures="1" errors="1"><testsuite failures="1" errors="1"/></testsuites>' > "$_d/junit.xml"
		php scripts/adapters/phpunit-to-tests-json.php "$_d/junit.xml" "$_d/tp.json" >/dev/null 2>&1
		ad_check "phpunit adapter parses JUnit XML (failures)" "$(jq -r '.failures' "$_d/tp.json" 2>/dev/null)" "1"
		ad_check "phpunit adapter parses JUnit XML (errors)"   "$(jq -r '.errors' "$_d/tp.json" 2>/dev/null)" "1"
	else
		log_warn "php not found; SKIPPING phpunit adapter test (validate with: php -l / docker php)"
	fi

	# --- Laravel PHPStan runner: missing PHPStan -> unavailable, no fake report ---
	_pd=$(mktemp -d)
	( cd "$_pd" && SENTINEL_SHIELD_PHPSTAN_BIN="" sh "$OLDPWD/scripts/runners/laravel-phpstan.sh" --output reports/raw/phpstan.json >/dev/null 2>&1 ) || true
	if [ -f "$_pd/reports/raw/phpstan.json" ]; then
		ad_check "laravel-phpstan runner: no PHPStan -> NO fake report" "exists" "absent"
	else
		ad_check "laravel-phpstan runner: no PHPStan -> NO fake report (unavailable)" "absent" "absent"
	fi
	rm -rf "$_pd"

	# --- GitHub Actions pin audit ---
	mkdir -p "$_d/wf"
	printf 'on: [push]\njobs:\n  a:\n    container: node:20-alpine\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/setup-node@main\n' > "$_d/wf/bad.yml"
	printf 'on: [push]\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4\n      - uses: ./.github/actions/x\n      - run: |\n          grep -E "image:[[:space:]]*\\S+:latest" f || true\n          echo "uses: a/b@v1 and container: x:latest are just text"\n' > "$_d/wf/good.yml"
	sh scripts/audit-github-actions-pins.sh --output "$_d/ghbad.json" "$_d/wf/bad.yml" >/dev/null 2>&1
	ad_check "GH pin audit flags tag/branch/container refs" "$(jq 'length' "$_d/ghbad.json" 2>/dev/null)" "3"
	sh scripts/audit-github-actions-pins.sh --output "$_d/ghgood.json" "$_d/wf/good.yml" >/dev/null 2>&1
	ad_check "GH pin audit passes SHA + local refs, ignores run: block text" "$(jq 'length' "$_d/ghgood.json" 2>/dev/null)" "0"
	ad_check "GH pin collector -> unsafe_github_actions" "$(sh scripts/collectors/github-actions-pins.sh --input "$_d/ghbad.json" 2>/dev/null | jq -r '.summary.unsafe_github_actions')" "3"

	# --- Docker base digest detector ---
	mkdir -p "$_d/dfbad" "$_d/dfgood"
	printf 'FROM php:8.3-fpm-alpine AS base\nRUN echo x\n' > "$_d/dfbad/Dockerfile"
	printf 'FROM php:8.3-fpm-alpine@sha256:1b440e9804209491713035c4859d434f55e5cf8b0fb8c88a58f2f73d8e18b420 AS base\nFROM base AS final\n' > "$_d/dfgood/Dockerfile"
	( cd "$_d/dfbad" && sh "$OLDPWD/scripts/audit-docker-base-digest.sh" --output db.json >/dev/null 2>&1 )
	ad_check "Docker base-digest flags tag-only FROM" "$(jq 'length' "$_d/dfbad/db.json" 2>/dev/null)" "1"
	( cd "$_d/dfgood" && sh "$OLDPWD/scripts/audit-docker-base-digest.sh" --output db.json >/dev/null 2>&1 )
	ad_check "Docker base-digest passes digest FROM + stage alias" "$(jq 'length' "$_d/dfgood/db.json" 2>/dev/null)" "0"
	ad_check "Docker base-digest collector -> unsafe_docker" "$(sh scripts/collectors/docker-base-digest.sh --input "$_d/dfbad/db.json" 2>/dev/null | jq -r '.summary.unsafe_docker')" "1"

	# --- templates / guides exist ---
	for t in templates/security-debt-register.md templates/sentinel-shield-rollout-status.md \
		templates/security-triage-report.md templates/third-party-install-script-review.md \
		templates/pinned-ci-references.md \
		docs/remediation/react-dangerously-set-inner-html.md docs/remediation/phpstan-baseline-strategy.md \
		docs/remediation/docker-dl3018-decision-tree.md docs/remediation/browser-stack-isolation.md \
		docs/remediation/third-party-install-script-review.md docs/remediation/github-actions-sha-pinning.md \
		docs/remediation/docker-base-digest-pinning.md; do
		ad_check "template/guide exists: $t" "$([ -f "$t" ] && echo yes || echo no)" "yes"
	done

	rm -rf "$_d"
	if [ "$AD_FAILS" -ne 0 ]; then log_error "consolidation: $AD_FAILS case(s) failed"; return 1; fi
	log_info "consolidation: OK (adapters, runner, audits, detectors, templates/guides)"
}

# --- Laravel PHPStan runner robustness (v0.1.10) ----------------------------
PR_FAILS=0
pr_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; PR_FAILS=$((PR_FAILS + 1)); fi; }

# run_phpstan_runner — self-test group 'phpstan-runner' (wired into the dispatch + 'all').
run_phpstan_runner() {
	log_info "phpstan-runner: robustness (fake php/phpstan; no real Laravel app)"
	_runner="$PWD/scripts/runners/laravel-phpstan.sh"
	_d=$(mktemp -d); mkdir -p "$_d/bin"
	# Fake `php` so command_exists php passes (no artisan in proj -> discover skipped).
	printf '#!/bin/sh\nexit 0\n' > "$_d/bin/php"; chmod +x "$_d/bin/php"
	# Fake phpstan variants (ignore args; emit to stdout).
	printf '#!/bin/sh\nprintf "%%s\\n" '\''{"totals":{"errors":0,"file_errors":0},"files":{},"errors":[]}'\''\n' > "$_d/bin/ps-clean"; chmod +x "$_d/bin/ps-clean"
	printf '#!/bin/sh\nprintf "%%s\\n" '\''{"totals":{"errors":2,"file_errors":2},"files":{"a.php":{"errors":2}},"errors":[]}'\''\nexit 1\n' > "$_d/bin/ps-errs"; chmod +x "$_d/bin/ps-errs"
	printf '#!/bin/sh\necho "PHP Deprecated: something on stdout"\nprintf "%%s\\n" '\''{"totals":{"errors":0,"file_errors":0},"files":{},"errors":[]}'\''\n' > "$_d/bin/ps-noise"; chmod +x "$_d/bin/ps-noise"
	printf '#!/bin/sh\necho "Fatal error: bootstrap blew up"\nexit 255\n' > "$_d/bin/ps-fatal"; chmod +x "$_d/bin/ps-fatal"

	mkdir -p "$_d/proj"
	_run() { # _run <case-dir> <phpstan-bin|""> ; sets exit in $_rc, output at proj/reports/raw/phpstan.json
		( cd "$_d/proj" && rm -rf reports && PATH="$_d/bin:$PATH" \
			SENTINEL_SHIELD_PHPSTAN_BIN="$1" SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER=false \
			sh "$_runner" >/dev/null 2>&1 ); printf '%s' "$?"
	}
	# 1. PHPStan missing -> unavailable (exit 0, NO report).
	_rc=$(_run "/nonexistent/phpstan")
	pr_check "phpstan missing -> exit 0" "$_rc" "0"
	pr_check "phpstan missing -> NO report (unavailable)" "$([ -f "$_d/proj/reports/raw/phpstan.json" ] && echo present || echo absent)" "absent"
	# 2. Clean JSON -> report written + valid + errors 0.
	_rc=$(_run "$_d/bin/ps-clean")
	pr_check "clean JSON -> report written" "$([ -f "$_d/proj/reports/raw/phpstan.json" ] && echo yes || echo no)" "yes"
	pr_check "clean JSON -> valid + errors 0" "$(jq -r '(.totals.errors)+(.totals.file_errors)' "$_d/proj/reports/raw/phpstan.json" 2>/dev/null)" "0"
	# 3. JSON with errors -> report written + valid + errors>0 (not faked to 0).
	_rc=$(_run "$_d/bin/ps-errs")
	pr_check "errors JSON -> report written" "$([ -f "$_d/proj/reports/raw/phpstan.json" ] && echo yes || echo no)" "yes"
	pr_check "errors JSON -> errors preserved (4)" "$(jq -r '(.totals.errors)+(.totals.file_errors)' "$_d/proj/reports/raw/phpstan.json" 2>/dev/null)" "4"
	# 4. stdout noise + JSON -> JSON extracted, valid.
	_rc=$(_run "$_d/bin/ps-noise")
	pr_check "noise+JSON -> extracted valid report" "$(jq -e 'type=="object"' "$_d/proj/reports/raw/phpstan.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
	# 5. non-JSON fatal -> NO fake report (unavailable), debug artifacts kept.
	_rc=$(_run "$_d/bin/ps-fatal")
	pr_check "non-JSON fatal -> NO fake report" "$([ -f "$_d/proj/reports/raw/phpstan.json" ] && echo present || echo absent)" "absent"
	pr_check "non-JSON fatal -> exit 0 (artifact upload not skipped)" "$_rc" "0"
	pr_check "non-JSON fatal -> debug stdout kept" "$([ -f "$_d/proj/reports/raw/phpstan.stdout.raw" ] && echo yes || echo no)" "yes"

	rm -rf "$_d"
	if [ "$PR_FAILS" -ne 0 ]; then log_error "phpstan-runner: $PR_FAILS case(s) failed"; return 1; fi
	log_info "phpstan-runner: OK (missing/clean/errors/noise/fatal — never fakes a clean report)"
}

# --- unsafe_docker multi-source finding-scope (v0.1.10) ----------------------
MS_FAILS=0
# ms_case <desc> <exit> <summary-ud> <hadolint-json> <base-json> <risks-json> [acc] [unacc]
ms_case() {
	_d=$(mktemp -d); mkdir -p "$_d/raw"
	sh scripts/resolve-gates.sh --mode baseline --output-dir "$_d" --format env >/dev/null 2>&1
	jq ".summary.unsafe_docker = $3" templates/security-summary.example.json > "$_d/security-summary.json"
	printf '%s' "$4" > "$_d/raw/hadolint.json"
	printf '%s' "$5" > "$_d/raw/docker-base-digest.json"
	printf '%s' "$6" > "$_d/accepted-risks.json"
	if sh scripts/enforce-gates.sh --gates-env "$_d/sentinel-shield-gates.env" \
		--summary "$_d/security-summary.json" --accepted-risks "$_d/accepted-risks.json" \
		--hadolint-raw "$_d/raw/hadolint.json" --docker-base-digest-raw "$_d/raw/docker-base-digest.json" \
		--output-dir "$_d" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	_ok=1; [ "$_rc" -eq "$2" ] || _ok=0
	if [ -n "${7:-}" ]; then
		_a=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)
		_u=$(jq -r '.accepted_risks.unsafe_docker.unaccepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)
		[ "$_a" = "$7" ] || _ok=0; [ "$_u" = "$8" ] || _ok=0
	fi
	if [ "$_ok" -eq 1 ]; then log_info "PASS: $1 (exit $_rc${7:+, acc=$7/unacc=$8})"; else
		log_error "FAIL: $1 (exit $_rc/exp $2; acc=$(jq -r '.accepted_risks.unsafe_docker.accepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)/$7 unacc=$(jq -r '.accepted_risks.unsafe_docker.unaccepted' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)/$8)"; MS_FAILS=$((MS_FAILS + 1)); fi
	rm -rf "$_d"
}

# run_ud_multisource — self-test group 'ud-multisource' (wired into the dispatch + 'all').
run_ud_multisource() {
	log_info "ud-multisource: unsafe_docker matching across hadolint + docker-base-digest"
	_h='[{"file":"Dockerfile","line":2,"code":"DL3018","level":"warning"}]'
	_b='[{"file":"docker/8.3/Dockerfile","line":1,"image":"ubuntu:24.04","code":"SS_DOCKER_BASE_DIGEST","reason":"tag"}]'
	_r_dl3018='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["Dockerfile"],"owner":"p","severity":"medium","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'
	_r_base='{"version":"1.1","risks":[{"id":"rb","gate":"unsafe_docker","scope":"finding","rule_id":"SS_DOCKER_BASE_DIGEST","files":["docker/8.3/Dockerfile"],"owner":"p","severity":"medium","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'
	_r_both='{"version":"1.1","risks":[{"id":"r1","gate":"unsafe_docker","scope":"finding","rule_id":"DL3018","files":["Dockerfile"],"owner":"p","severity":"medium","reason":"x","expires_at":"2999-12-31","status":"approved"},{"id":"rb","gate":"unsafe_docker","scope":"finding","rule_id":"SS_DOCKER_BASE_DIGEST","files":["docker/8.3/Dockerfile"],"owner":"p","severity":"medium","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'
	_r_gate='{"version":"1.1","risks":[{"id":"rg","gate":"unsafe_docker","scope":"gate","owner":"p","severity":"medium","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'

	ms_case "Hadolint DL3018 accepted, base-digest UNACCEPTED -> fail"        1 2 "$_h" "$_b" "$_r_dl3018" 1 1
	ms_case "base-digest accepted via SS_DOCKER_BASE_DIGEST+file -> pass"     0 1 '[]' "$_b" "$_r_base"    1 0
	ms_case "mixed hadolint + base-digest all accepted -> pass"              0 2 "$_h" "$_b" "$_r_both"   2 0
	ms_case "DL3018 record does NOT suppress base-digest finding -> fail"    1 2 "$_h" "$_b" "$_r_dl3018" 1 1
	ms_case "legacy scope:gate still suppresses whole gate (broad)"          0 2 "$_h" "$_b" "$_r_gate"   2 0
	# unaccounted source: summary says 2 but base raw is empty -> 1 unaccounted -> fail
	ms_case "missing base raw counted as unaccounted -> fail"               1 2 "$_h" '[]' "$_r_dl3018"  1 1

	if [ "$MS_FAILS" -ne 0 ]; then log_error "ud-multisource: $MS_FAILS case(s) failed"; return 1; fi
	log_info "ud-multisource: OK (hadolint + docker-base-digest; DL3018 never suppresses base-digest; unaccounted fails closed)"
}

# --- profile-driven install/sync (v0.1.11) ----------------------------------
IS_FAILS=0
is_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; IS_FAILS=$((IS_FAILS + 1)); fi; }

# run_install_sync — self-test group 'install-sync' (wired into the dispatch + 'all').
run_install_sync() {
	log_info "install-sync: profile-driven install/sync + detect-stack (temp dirs, no network)"

	# --- detect-stack on a Laravel+React+Docker fixture ---
	_p=$(mktemp -d)
	: > "$_p/artisan"
	printf '{"dependencies":{"react":"^18"}}' > "$_p/package.json"
	printf 'FROM alpine\n' > "$_p/Dockerfile"
	_stacks=$(sh scripts/detect-stack.sh "$_p" 2>/dev/null | sed -n 's/^detected: //p' | sort | tr '\n' ' ')
	is_check "detect-stack finds laravel" "$(printf '%s' "$_stacks" | grep -c laravel)" "1"
	is_check "detect-stack finds react" "$(printf '%s' "$_stacks" | grep -c react)" "1"
	is_check "detect-stack finds docker" "$(printf '%s' "$_stacks" | grep -c docker)" "1"
	rm -rf "$_p"

	# --- install dry-run creates nothing ---
	_t=$(mktemp -d)
	sh scripts/install-baseline.sh --target "$_t" >/dev/null 2>&1
	is_check "install dry-run writes no files" "$(find "$_t" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

	# --- install --apply --mode report-only creates expected files + stamps mode ---
	sh scripts/install-baseline.sh --target "$_t" --apply --mode report-only >/dev/null 2>&1
	is_check "install --apply creates profile.yaml" "$([ -f "$_t/.sentinel-shield/profile.yaml" ] && echo yes || echo no)" "yes"
	is_check "install --apply creates workflow" "$([ -f "$_t/.github/workflows/sentinel-shield.yml" ] && echo yes || echo no)" "yes"
	is_check "install --apply creates accepted-risks EXAMPLE" "$([ -f "$_t/.sentinel-shield/accepted-risks.example.json" ] && echo yes || echo no)" "yes"
	is_check "install --apply creates .semgrepignore" "$([ -f "$_t/.semgrepignore" ] && echo yes || echo no)" "yes"
	is_check "profile mode written = report-only" "$(grep -m1 '^  mode:' "$_t/.sentinel-shield/profile.yaml" | sed -E 's/.*mode:[[:space:]]*//')" "report-only"
	is_check "install NEVER created accepted-risks.json" "$([ -f "$_t/.sentinel-shield/accepted-risks.json" ] && echo yes || echo no)" "no"

	# --- install never overwrites a real accepted-risks.json (even with --force) ---
	printf '{"version":"1.1","risks":[{"id":"KEEPME"}]}' > "$_t/.sentinel-shield/accepted-risks.json"
	sh scripts/install-baseline.sh --target "$_t" --apply --force >/dev/null 2>&1
	is_check "install --force preserves real accepted-risks.json" "$(grep -c KEEPME "$_t/.sentinel-shield/accepted-risks.json")" "1"

	# --- install --force overwrites MANAGED workflow only (not project-owned profile.yaml) ---
	printf '\n# PROJECT_EDIT\n' >> "$_t/.github/workflows/sentinel-shield.yml"
	# project-owned profile.yaml: change mode to baseline; --force must NOT revert it
	awk '/^  mode: report-only$/{sub(/report-only/,"baseline")} {print}' "$_t/.sentinel-shield/profile.yaml" > "$_t/.sentinel-shield/profile.yaml.x" && mv "$_t/.sentinel-shield/profile.yaml.x" "$_t/.sentinel-shield/profile.yaml"
	sh scripts/install-baseline.sh --target "$_t" --apply --force >/dev/null 2>&1
	is_check "install --force overwrites managed workflow" "$(grep -c PROJECT_EDIT "$_t/.github/workflows/sentinel-shield.yml")" "0"
	is_check "install --force does NOT touch project-owned profile.yaml" "$(grep -m1 '^  mode:' "$_t/.sentinel-shield/profile.yaml" | sed -E 's/.*mode:[[:space:]]*//')" "baseline"

	# --- sync dry-run reports drift on a mutated managed workflow ---
	printf '\n# DRIFT\n' >> "$_t/.github/workflows/sentinel-shield.yml"
	_dr=$(sh scripts/sync-baseline.sh --target "$_t" 2>/dev/null | grep -c 'manual-review-needed (managed drift' || true)
	is_check "sync dry-run reports managed drift" "$_dr" "1"
	is_check "sync dry-run does NOT modify (drift still present)" "$(grep -c DRIFT "$_t/.github/workflows/sentinel-shield.yml")" "1"

	# --- sync --apply --force updates managed file ---
	sh scripts/sync-baseline.sh --target "$_t" --apply --force >/dev/null 2>&1
	is_check "sync --apply --force updates managed workflow" "$(grep -c DRIFT "$_t/.github/workflows/sentinel-shield.yml")" "0"

	# --- sync never overwrites accepted-risks.json ---
	sh scripts/sync-baseline.sh --target "$_t" --apply --force >/dev/null 2>&1
	is_check "sync preserves real accepted-risks.json" "$(grep -c KEEPME "$_t/.sentinel-shield/accepted-risks.json")" "1"

	rm -rf "$_t"
	if [ "$IS_FAILS" -ne 0 ]; then log_error "install-sync: $IS_FAILS case(s) failed"; return 1; fi
	log_info "install-sync: OK (dry-run safe; profile mode; managed vs project-local; accepted-risks never touched)"
}

# --- enterprise scanner matrix (v0.1.12) ------------------------------------
SM_FAILS=0
sm_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; SM_FAILS=$((SM_FAILS + 1)); fi; }

# run_scanner_matrix — self-test group 'scanner-matrix' (wired into the dispatch + 'all').
run_scanner_matrix() {
	log_info "scanner-matrix: collectors, resolver/enforcer gates, DAST safety, AI non-gating"
	_d=$(mktemp -d); _r="$_d/raw"; mkdir -p "$_r"
	C="$ROOT/scripts/collectors"

	# --- collector parsing (fixtures -> expected key counts) ---
	echo '{"summary":{"failed":2}}' > "$_r/checkov.json"
	sm_check "checkov -> iac_violations" "$(sh "$C/checkov.sh" --input "$_r/checkov.json" | jq '.summary.iac_violations')" "2"
	echo '{"matches":[{"vulnerability":{"severity":"Critical"}},{"vulnerability":{"severity":"Medium"}}]}' > "$_r/grype.json"
	sm_check "grype -> critical" "$(sh "$C/grype.sh" --input "$_r/grype.json" | jq '.summary.critical_vulnerabilities')" "1"
	echo '{"details":[{"level":"FATAL"},{"level":"INFO"}]}' > "$_r/dockle.json"
	sm_check "dockle -> container_image_violations" "$(sh "$C/dockle.sh" --input "$_r/dockle.json" | jq '.summary.container_image_violations')" "1"
	# ASSERTION CHANGED (audit PR B), because the behaviour it pinned WAS the defect: the
	# collector counted only Verified:true findings. TruffleHog reports unverified findings
	# by default and non-verifiable custom detectors ALWAYS report Verified:false, so real
	# leaked credentials contributed nothing to `secrets` — a gate that blocks in every
	# mode, including report-only. Both findings must now be counted; the verified/
	# unverified split is preserved in the tool_report for triage.
	echo '[{"Verified":true},{"Verified":false}]' > "$_r/trufflehog.json"
	sm_check "trufflehog -> secrets (verified AND unverified)" "$(sh "$C/trufflehog.sh" --input "$_r/trufflehog.json" | jq '.summary.secrets')" "2"
	sm_check "trufflehog -> verified/unverified split reported" "$(sh "$C/trufflehog.sh" --input "$_r/trufflehog.json" | jq -r '"\(.tool_report.verified):\(.tool_report.unverified)"')" "1:1"
	echo '{"errors":3}' > "$_r/php-syntax.json"
	sm_check "php-syntax -> php_syntax_errors" "$(sh "$C/php-syntax.sh" --input "$_r/php-syntax.json" | jq '.summary.php_syntax_errors')" "3"
	echo '{"site":[{"alerts":[{"riskcode":"3"},{"riskcode":"1"}]}]}' > "$_r/zap.json"
	sm_check "zap -> dast_findings (riskcode>=2)" "$(sh "$C/zap.sh" --input "$_r/zap.json" | jq '.summary.dast_findings')" "1"
	echo '{"checks":[{"name":"a","score":1},{"name":"b","score":9}]}' > "$_r/scorecard.json"
	sm_check "scorecard -> repository_health_warnings" "$(sh "$C/scorecard.sh" --input "$_r/scorecard.json" | jq '.summary.repository_health_warnings')" "1"
	echo '{"findings":[{"x":1},{"y":2}]}' > "$_r/ai-security-review.json"
	sm_check "ai-review -> ai_review_findings, status warn" "$(sh "$C/ai-security-review.sh" --input "$_r/ai-security-review.json" | jq -r '"\(.summary.ai_review_findings):\(.status)"')" "2:warn"

	# --- missing report -> unavailable, exit 0 ---
	_rc=0; _o=$(sh "$C/grype.sh" --input "$_r/nope.json") || _rc=$?
	sm_check "missing report exit 0" "$_rc" "0"
	sm_check "missing report -> unavailable" "$(printf '%s' "$_o" | jq -r .status)" "unavailable"

	# --- invalid JSON -> exit 2 ---
	echo 'NOT JSON' > "$_r/bad.json"
	_rc=0; sh "$C/checkov.sh" --input "$_r/bad.json" >/dev/null 2>&1 || _rc=$?; sm_check "invalid JSON exit 2" "$_rc" "2"

	# --- resolver: new flags by mode (read each resolved file directly) ---
	for _m in report-only baseline strict regulated; do
		printf 'project:\n  name: t\ngates:\n  mode: %s\n' "$_m" > "$_d/p.yaml"
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$_m" --format json --output-dir "$_d" >/dev/null 2>&1
		cp "$_d/sentinel-shield-gates.json" "$_d/gates-$_m.json"
	done
	rg_flag() { jq -r ".fail_on.$2" "$_d/gates-$1.json"; }
	sm_check "resolver report-only php_syntax=false" "$(rg_flag report-only php_syntax_errors)" "false"
	sm_check "resolver baseline php_syntax=true"     "$(rg_flag baseline php_syntax_errors)"    "true"
	sm_check "resolver baseline iac=false"           "$(rg_flag baseline iac_violations)"       "false"
	sm_check "resolver strict iac=true"              "$(rg_flag strict iac_violations)"         "true"
	sm_check "resolver strict dast=false"            "$(rg_flag strict dast_findings)"          "false"
	sm_check "resolver regulated dast=true"          "$(rg_flag regulated dast_findings)"       "true"
	sm_check "resolver regulated AI non-gating"      "$(rg_flag regulated ai_review_findings)"  "false"

	# --- enforcer: new gates across modes ---
	mkdir -p "$_d/eraw"; echo '{"errors":2}' > "$_d/eraw/php-syntax.json"; echo '{"summary":{"failed":1}}' > "$_d/eraw/checkov.json"; echo '{"findings":[{"x":1}]}' > "$_d/eraw/ai-security-review.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/eraw" --output "$_d/sum.json" --project-name t >/dev/null 2>&1
	for _m in baseline strict regulated; do
		printf 'project:\n  name: t\ngates:\n  mode: %s\n' "$_m" > "$_d/p.yaml"
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$_m" --format env --output-dir "$_d" >/dev/null 2>&1
		sh "$ROOT/scripts/enforce-gates.sh" --summary "$_d/sum.json" --gates-env "$_d/sentinel-shield-gates.env" --output-dir "$_d" --format json >/dev/null 2>&1 || true
		_E="$_d/sentinel-shield-enforcement.json"
		eval "_e_$(echo "$_m" | tr '-' '_')=\"$(jq -r '[.evaluated_gates[]|select(.key=="iac_violations")][0].result' "$_E")|$(jq -r '[.evaluated_gates[]|select(.key=="ai_review_findings")][0].result' "$_E")\""
	done
	sm_check "enforcer baseline iac skipped"   "$(echo "$_e_baseline"  | cut -d'|' -f1)" "skipped"
	sm_check "enforcer strict iac fail"        "$(echo "$_e_strict"    | cut -d'|' -f1)" "fail"
	sm_check "enforcer AI skipped (regulated)" "$(echo "$_e_regulated" | cut -d'|' -f2)" "skipped"

	# --- DAST safety ---
	DG="$ROOT/scripts/runners"
	_rc=0; ( unset SENTINEL_SHIELD_DAST_TARGET_URL; sh "$DG/zap-baseline.sh" "$_d/z.json" >/dev/null 2>&1 ) || _rc=$?; sm_check "DAST no target -> skip exit 0" "$_rc" "0"
	_rc=0; ( SENTINEL_SHIELD_DAST_TARGET_URL=https://evil.test SENTINEL_SHIELD_DAST_ALLOWED_HOST=staging.app sh "$DG/nuclei.sh" "$_d/n.json" >/dev/null 2>&1 ) || _rc=$?; sm_check "DAST host mismatch -> fail closed exit 3" "$_rc" "3"
	_rc=0; ( SENTINEL_SHIELD_DAST_TARGET_URL=https://staging.app/x SENTINEL_SHIELD_DAST_ALLOWED_HOST=staging.app sh "$DG/zap-baseline.sh" "$_d/z.json" >/dev/null 2>&1 ) || _rc=$?; sm_check "DAST allowlisted host -> exit 0" "$_rc" "0"

	rm -rf "$_d"
	if [ "$SM_FAILS" -ne 0 ]; then log_error "scanner-matrix: $SM_FAILS case(s) failed"; return 1; fi
	log_info "scanner-matrix: OK (collectors, gates by mode, DAST fail-closed, AI non-gating)"
}

# --- fixture consumer projects (v0.1.13) ------------------------------------
FX_FAILS=0
fx_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; FX_FAILS=$((FX_FAILS + 1)); fi; }

# run_fixtures — self-test group 'fixtures' (wired into the dispatch + 'all').
run_fixtures() {
	log_info "fixtures: detect-stack + install/sync + profile resolution + enforcement over offline fixtures"
	FXB="$ROOT/tests/fixtures/projects"
	[ -d "$FXB" ] || { log_error "fixtures: $FXB missing"; return 1; }

	# detect-stack per fixture (sorted detected stacks)
	ds() { sh "$ROOT/scripts/detect-stack.sh" "$FXB/$1" 2>/dev/null | sed -n 's/^detected: //p' | sort | tr '\n' ' ' | sed 's/ $//'; }
	fx_check "detect laravel-react-docker" "$(ds laravel-react-docker)" "docker laravel node react"
	fx_check "detect node-react"           "$(ds node-react)"           "node react"
	fx_check "detect docker-only"          "$(ds docker-only)"          "docker"
	fx_check "detect php-library"          "$(ds php-library)"          "php"

	# install/sync round-trip on a COPY of the laravel-react-docker fixture (never mutate the fixture)
	_t=$(mktemp -d); cp -R "$FXB/laravel-react-docker/." "$_t/"
	sh "$ROOT/scripts/install-baseline.sh" --target "$_t" >/dev/null 2>&1
	fx_check "install dry-run writes nothing new" "$([ -f "$_t/.sentinel-shield/profile.yaml" ] && echo yes || echo no)" "no"
	sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --apply --mode baseline >/dev/null 2>&1
	fx_check "install --apply creates profile.yaml" "$([ -f "$_t/.sentinel-shield/profile.yaml" ] && echo yes || echo no)" "yes"
	fx_check "install --apply creates managed workflow" "$([ -f "$_t/.github/workflows/sentinel-shield.yml" ] && echo yes || echo no)" "yes"
	fx_check "profile mode = baseline" "$(grep -m1 '^  mode:' "$_t/.sentinel-shield/profile.yaml" | sed -E 's/.*mode:[[:space:]]*//')" "baseline"
	fx_check "install did NOT create accepted-risks.json" "$([ -f "$_t/.sentinel-shield/accepted-risks.json" ] && echo yes || echo no)" "no"

	# profile resolution against the installed fixture profile
	sh "$ROOT/scripts/resolve-gates.sh" --profile "$_t/.sentinel-shield/profile.yaml" --output-dir "$_t/r" --format json >/dev/null 2>&1
	fx_check "resolve baseline secrets=true" "$(jq -r '.fail_on.secrets' "$_t/r/sentinel-shield-gates.json" 2>/dev/null)" "true"

	# enforcement with the example summary (clean) -> pass
	sh "$ROOT/scripts/resolve-gates.sh" --profile "$_t/.sentinel-shield/profile.yaml" --output-dir "$_t/r" --format env >/dev/null 2>&1
	sh "$ROOT/scripts/enforce-gates.sh" --summary "$ROOT/templates/security-summary.example.json" --gates-env "$_t/r/sentinel-shield-gates.env" --output-dir "$_t/r" --format json >/dev/null 2>&1 || true
	fx_check "enforce example summary = pass" "$(jq -r .result "$_t/r/sentinel-shield-enforcement.json" 2>/dev/null)" "pass"

	# sync: clean copy is up-to-date; mutate managed workflow -> drift -> update
	sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" >/dev/null 2>&1; fx_check "sync dry-run exit 0" "$?" "0"
	printf '\n# DRIFT\n' >> "$_t/.github/workflows/sentinel-shield.yml"
	_dr=$(sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" 2>/dev/null | grep -c 'manual-review-needed (managed drift')
	fx_check "sync detects managed drift" "$_dr" "1"
	sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" --apply --force >/dev/null 2>&1
	fx_check "sync --apply --force clears drift" "$(grep -c DRIFT "$_t/.github/workflows/sentinel-shield.yml")" "0"

	# node-react fixture: install dry-run with react profile lists files, writes nothing
	_t2=$(mktemp -d); cp -R "$FXB/node-react/." "$_t2/"
	sh "$ROOT/scripts/install-baseline.sh" --target "$_t2" --profile react >/dev/null 2>&1
	fx_check "node-react dry-run writes nothing" "$([ -f "$_t2/.sentinel-shield/profile.yaml" ] && echo yes || echo no)" "no"

	rm -rf "$_t" "$_t2"
	if [ "$FX_FAILS" -ne 0 ]; then log_error "fixtures: $FX_FAILS case(s) failed"; return 1; fi
	log_info "fixtures: OK (detect-stack, install/sync round-trip, profile resolution, enforcement)"
}

# --- workflow sanity (v0.1.13) ----------------------------------------------
WS_FAILS=0
ws_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; WS_FAILS=$((WS_FAILS + 1)); fi; }

# run_workflow_sanity — self-test group 'workflow-sanity' (wired into the dispatch + 'all').
run_workflow_sanity() {
	log_info "workflow-sanity: no pull_request_target trigger, permissions present, DAST allowlist, AI non-gating"
	WF_GH="$ROOT/.github/workflows"; WF_TPL="$ROOT/templates/workflows"

	# 1. No ACTUAL pull_request_target TRIGGER anywhere (comments are fine).
	_prt=$(grep -rlE '^[[:space:]]+pull_request_target:' "$WF_GH" "$WF_TPL" 2>/dev/null | wc -l | tr -d ' ')
	ws_check "no pull_request_target trigger" "$_prt" "0"

	# 2. Every workflow has a permissions: block.
	_noperm=0
	for f in "$WF_GH"/*.yml "$WF_TPL"/*.yml; do
		[ -f "$f" ] || continue
		grep -qE '^permissions:|^[[:space:]]+permissions:' "$f" || { log_error "  no permissions block: $f"; _noperm=$((_noperm + 1)); }
	done
	ws_check "all workflows declare permissions" "$_noperm" "0"

	# 3. DAST template requires the allowlist env + uses the guarded runners.
	_dast="$WF_TPL/sentinel-shield-dast.yml"
	ws_check "DAST template references ALLOWED_HOST" "$(grep -c 'SENTINEL_SHIELD_DAST_ALLOWED_HOST' "$_dast" 2>/dev/null)" "1"
	ws_check "DAST template uses guarded runners" "$([ "$(grep -cE 'runners/(zap-baseline|zap-full|nuclei)\.sh' "$_dast" 2>/dev/null)" -ge 1 ] && echo yes || echo no)" "yes"

	# 4. AI review template is non-gating by default (labeled, no fail_on ai true).
	_ai="$WF_TPL/sentinel-shield-ai-review.yml"
	ws_check "AI review template marked NON-GATING" "$([ "$(grep -c 'NON-GATING' "$_ai" 2>/dev/null)" -ge 1 ] && echo yes || echo no)" "yes"
	# Ignore comment lines (a doc note that says "to enable, set ... true" is fine);
	# only an ACTIVE (non-comment) enable would be a violation.
	ws_check "AI review template does not force-enable ai gate" "$(grep -vE '^[[:space:]]*#' "$_ai" 2>/dev/null | grep -c 'fail_on.ai_review_findings: true')" "0"

	# 5. DAST/AI templates are not PR-triggered by default (manual/controlled).
	ws_check "DAST template is workflow_dispatch-only (no pull_request:)" "$(grep -cE '^[[:space:]]*pull_request:' "$_dast" 2>/dev/null)" "0"

	# 6. (v0.1.22) Every consumer template that uploads artifacts does so with `if: always()`
	#    so a failing gate/scan never erases the raw reports.
	_noalways=0
	for f in "$WF_TPL"/*.yml; do
		[ -f "$f" ] || continue
		grep -q 'upload-artifact' "$f" || continue
		grep -q 'if: always()' "$f" || { log_error "  upload without if: always(): $(basename "$f")"; _noalways=$((_noalways + 1)); }
	done
	ws_check "all artifact uploads use if: always()" "$_noalways" "0"

	# 7. (v0.1.22) workflow `name:` matches its filename (stem).
	_namemismatch=0
	for f in "$WF_TPL"/*.yml; do
		[ -f "$f" ] || continue
		_stem=$(basename "$f" .yml); _name=$(grep -m1 '^name:' "$f" | sed -E 's/^name:[[:space:]]*//')
		[ "$_stem" = "$_name" ] || { log_error "  name '$_name' != filename '$_stem'"; _namemismatch=$((_namemismatch + 1)); }
	done
	ws_check "workflow name matches filename" "$_namemismatch" "0"

	# 8. (v0.1.22) Scanner-image digest override env vars are exposed across templates.
	ws_check "templates expose SEMGREP image override" "$([ "$(grep -rl 'SENTINEL_SHIELD_SEMGREP_IMAGE' "$WF_TPL" | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
	ws_check "templates expose GRYPE image override"   "$([ "$(grep -rl 'SENTINEL_SHIELD_GRYPE_IMAGE' "$WF_TPL" | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"
	ws_check "templates expose DOCKLE image override"  "$([ "$(grep -rl 'SENTINEL_SHIELD_DOCKLE_IMAGE' "$WF_TPL" | wc -l | tr -d ' ')" -ge 1 ] && echo yes || echo no)" "yes"

	# 9. (v0.1.22) Dedicated Dependency-Check evidence workflow: dispatch-only, cached, foreground, always-upload.
	_dce="$WF_TPL/sentinel-shield-dependency-check.yml"
	ws_check "dep-check evidence workflow exists" "$([ -f "$_dce" ] && echo yes || echo no)" "yes"
	ws_check "dep-check evidence has workflow_dispatch" "$(grep -cE '^[[:space:]]*workflow_dispatch:' "$_dce" 2>/dev/null)" "1"
	ws_check "dep-check evidence uses actions/cache" "$([ "$(grep -c 'uses: actions/cache' "$_dce" 2>/dev/null)" -ge 1 ] && echo yes || echo no)" "yes"
	ws_check "dep-check evidence uploads if: always()" "$([ "$(grep -c 'if: always()' "$_dce" 2>/dev/null)" -ge 1 ] && echo yes || echo no)" "yes"
	ws_check "dep-check evidence has no pull_request_target" "$(grep -cE '^[[:space:]]*pull_request_target:' "$_dce" 2>/dev/null)" "0"

	if [ "$WS_FAILS" -ne 0 ]; then log_error "workflow-sanity: $WS_FAILS case(s) failed"; return 1; fi
	log_info "workflow-sanity: OK (no PRT, permissions, DAST allowlisted, AI non-gating, if:always uploads, name==file, digest overrides, dep-check evidence wf)"
}

# --- feature completion (v0.1.14) -------------------------------------------
FC_FAILS=0
fc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; FC_FAILS=$((FC_FAILS + 1)); fi; }

# run_feature_completion — self-test group 'feature-completion' (wired into the dispatch + 'all').
run_feature_completion() {
	log_info "feature-completion: dependency-policy detector, architecture-tests collector, new runners present"
	_d=$(mktemp -d); _r="$_d/raw"; mkdir -p "$_r"
	DP="$ROOT/scripts/audits/dependency-policy.sh"; C="$ROOT/scripts/collectors"

	# dependency-policy: manifest WITHOUT lockfile -> violation; WITH lockfile -> 0; no manifest -> 0.
	_p=$(mktemp -d); echo '{}' > "$_p/composer.json"
	sh "$DP" "$_p/dp.json" "$_p" >/dev/null 2>&1
	fc_check "dep-policy: composer.json w/o lock -> 1" "$(jq '.count' "$_p/dp.json")" "1"
	echo '{}' > "$_p/composer.lock"
	sh "$DP" "$_p/dp2.json" "$_p" >/dev/null 2>&1
	fc_check "dep-policy: with lock -> 0" "$(jq '.count' "$_p/dp2.json")" "0"
	_e=$(mktemp -d)
	sh "$DP" "$_e/dp.json" "$_e" >/dev/null 2>&1
	fc_check "dep-policy: no manifests -> 0 (clean, honest)" "$(jq '.count' "$_e/dp.json")" "0"
	# collector mapping + missing/invalid behavior
	fc_check "dep-policy collector -> dependency_policy_violations" "$(sh "$C/dependency-policy.sh" --input "$_p/dp.json" | jq '.summary.dependency_policy_violations')" "1"
	_rc=0; _o=$(sh "$C/dependency-policy.sh" --input "$_r/nope.json") || _rc=$?
	fc_check "dep-policy collector missing -> unavailable exit 0" "$_rc" "0"
	fc_check "dep-policy collector missing -> unavailable" "$(printf '%s' "$_o" | jq -r .status)" "unavailable"
	echo 'NOT JSON' > "$_r/bad.json"; _rc=0; sh "$C/dependency-policy.sh" --input "$_r/bad.json" >/dev/null 2>&1 || _rc=$?
	fc_check "dep-policy collector invalid JSON -> exit 2" "$_rc" "2"

	# architecture-tests collector -> architecture_violations
	echo '{"violations":2}' > "$_r/architecture-tests.json"
	fc_check "arch-tests collector -> architecture_violations" "$(sh "$C/architecture-tests.sh" --input "$_r/architecture-tests.json" | jq '.summary.architecture_violations')" "2"

	# v2.1.0 architecture governance: every producer has a runner + collector, the normalized
	# contract is honored, and an unknown shape fails closed. Full coverage lives in
	# tests/prod/280-architecture-governance.sh (run by `self-test.sh production-readiness`).
	_miss=0
	for r in deptrac php-arkitect php-architecture-tests dependency-cruiser eslint-boundaries js-architecture-tests architecture-tests; do
		[ -f "$ROOT/scripts/runners/$r.sh" ] && sh -n "$ROOT/scripts/runners/$r.sh" || { log_error "  arch runner missing/bad: $r"; _miss=$((_miss + 1)); }
	done
	for c in architecture deptrac php-arkitect php-architecture-tests dependency-cruiser eslint-boundaries js-architecture-tests architecture-tests; do
		[ -f "$ROOT/scripts/collectors/$c.sh" ] && sh -n "$ROOT/scripts/collectors/$c.sh" || { log_error "  arch collector missing/bad: $c"; _miss=$((_miss + 1)); }
	done
	fc_check "all v2.1.0 architecture producers present + valid" "$_miss" "0"
	echo '{"tool":"architecture","status":"findings","violations":3,"rule_count":9,"context_count":2}' > "$_r/arch-norm.json"
	fc_check "architecture collector -> normalized contract" "$(sh "$C/architecture.sh" --input "$_r/arch-norm.json" | jq '.summary.architecture_violations')" "3"
	echo '{"unrecognized":"shape"}' > "$_r/arch-unknown.json"
	fc_check "architecture collector: unknown shape -> execution-error (no fake clean)" "$(sh "$C/architecture.sh" --input "$_r/arch-unknown.json" | jq -r '.status')" "execution-error"
	[ -f "$ROOT/tests/prod/280-architecture-governance.sh" ] && _p280=present || _p280=missing
	fc_check "prod suite 280-architecture-governance.sh present (production-readiness)" "$_p280" "present"

	# new runners exist + are syntactically valid
	_miss=0
	for r in psalm php-style eslint typescript actionlint zizmor deptrac codeql-export architecture-tests; do
		[ -f "$ROOT/scripts/runners/$r.sh" ] && sh -n "$ROOT/scripts/runners/$r.sh" || { log_error "  runner missing/bad: $r"; _miss=$((_miss + 1)); }
	done
	fc_check "all v0.1.14 runners present + valid" "$_miss" "0"
	# new audits exist
	_miss=0
	for a in syft trivy-fs trivy-image dependency-policy; do
		[ -f "$ROOT/scripts/audits/$a.sh" ] && sh -n "$ROOT/scripts/audits/$a.sh" || { log_error "  audit missing/bad: $a"; _miss=$((_miss + 1)); }
	done
	fc_check "all v0.1.14 audits present + valid" "$_miss" "0"

	# IaC detector skips cleanly: an audit wrapper with no binary present is a clean no-op (exit 0).
	_rc=0; ( sh "$ROOT/scripts/audits/checkov.sh" "$_e/checkov.json" >/dev/null 2>&1 ) || _rc=$?
	fc_check "IaC audit (no binary) -> clean no-op exit 0" "$_rc" "0"
	fc_check "IaC audit (no binary) wrote no fake report" "$([ -f "$_e/checkov.json" ] && echo wrote || echo none)" "none"

	rm -rf "$_d" "$_p" "$_e"
	if [ "$FC_FAILS" -ne 0 ]; then log_error "feature-completion: $FC_FAILS case(s) failed"; return 1; fi
	log_info "feature-completion: OK (dependency-policy detector, arch-tests collector, runners/audits present, IaC clean-skip)"
}

# --- main-gate harness (v0.1.17) --------------------------------------------
MGH_FAILS=0
mgh_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; MGH_FAILS=$((MGH_FAILS + 1)); fi; }

# run_main_gate_harness — self-test group 'main-gate-harness' (wired into the dispatch + 'all').
run_main_gate_harness() {
	log_info "main-gate-harness: branch-safe main-gate wrappers; missing->unavailable (no fake), tool selection, JSON contract"
	H="$ROOT/scripts/run-main-gate-validation.sh"
	FX="$ROOT/tests/fixtures/projects/laravel-react-docker"
	[ -f "$H" ] || { log_error "main-gate-harness: $H missing"; return 1; }

	# unknown tool / no selection -> exit 2 (clear error)
	_rc=0; sh "$H" --target "$FX" --tool bogus >/dev/null 2>&1 || _rc=$?
	mgh_check "unknown tool -> exit 2" "$_rc" "2"
	_rc=0; sh "$H" --target "$FX" >/dev/null 2>&1 || _rc=$?
	mgh_check "no --all/--tool -> exit 2" "$_rc" "2"

	# NO DAST/Nuclei/AI tool is selectable (they are not in the harness)
	for bad in zap zap-baseline zap-full nuclei ai-security-review kuzushi; do
		_rc=0; sh "$H" --target "$FX" --tool "$bad" >/dev/null 2>&1 || _rc=$?
		mgh_check "DAST/AI tool '$bad' rejected" "$_rc" "2"
	done

	# --tool selection: selected processed, others skipped; output dir + valid JSON contract
	_o="$(mktemp -d)/raw"
	sh "$H" --target "$FX" --output-dir "$_o" --tool codeql-export >/dev/null 2>&1
	J="$_o/main-gate-validation-tools.json"
	mgh_check "output dir created" "$([ -d "$_o" ] && echo yes || echo no)" "yes"
	mgh_check "tools JSON version 1.1" "$(jq -r .version "$J" 2>/dev/null)" "1.1"
	mgh_check "selected tool processed" "$(jq -r '.tools["codeql-export"].status' "$J" 2>/dev/null)" "unavailable"
	mgh_check "unselected tool -> skipped" "$(jq -r '.tools["osv-scanner"].status' "$J" 2>/dev/null)" "skipped"
	mgh_check "no fake codeql.json on unavailable" "$([ -f "$_o/codeql.json" ] && echo wrote || echo none)" "none"

	# --all: every deterministic main-gate tool present, none skipped; dockle deterministically
	# unavailable without an image and writes no fake report
	_o2="$(mktemp -d)/raw"
	sh "$H" --target "$FX" --output-dir "$_o2" --all >/dev/null 2>&1
	J2="$_o2/main-gate-validation-tools.json"
	mgh_check "--all -> 12 tools" "$(jq -r '.tools | keys | length' "$J2" 2>/dev/null)" "12"
	mgh_check "--all none skipped" "$(jq -r '[ .tools[] | select(.status == "skipped") ] | length' "$J2" 2>/dev/null)" "0"
	mgh_check "dockle unavailable (no image)" "$(jq -r '.tools.dockle.status' "$J2" 2>/dev/null)" "unavailable"
	mgh_check "no fake dockle.json" "$([ -f "$_o2/dockle.json" ] && echo wrote || echo none)" "none"

	# fake-binary PASS path: a stub osv-scanner that honors --output proves the pass branch + report
	_bin=$(mktemp -d)
	cat > "$_bin/osv-scanner" <<'STUB'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "$out" ] && printf '{"results":[]}' > "$out"
exit 0
STUB
	chmod +x "$_bin/osv-scanner"
	_o3="$(mktemp -d)/raw"
	PATH="$_bin:$PATH" sh "$H" --target "$FX" --output-dir "$_o3" --tool osv-scanner >/dev/null 2>&1
	mgh_check "fake osv-scanner -> pass" "$(jq -r '.tools["osv-scanner"].status' "$_o3/main-gate-validation-tools.json" 2>/dev/null)" "pass"
	mgh_check "osv report written" "$([ -s "$_o3/osv-scanner.json" ] && echo yes || echo no)" "yes"

	# build-security-summary consumes the harness output dir -> schema-valid summary
	_sum="$(dirname "$_o2")/security-summary.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_o2" --output "$_sum" --project-name demo --project-type laravel >/dev/null 2>&1
	mgh_check "builder consumes harness raw-dir" "$(jq -r '.summary | type' "$_sum" 2>/dev/null)" "object"

	rm -rf "$(dirname "$_o")" "$(dirname "$_o2")" "$(dirname "$_o3")" "$_bin"
	if [ "$MGH_FAILS" -ne 0 ]; then log_error "main-gate-harness: $MGH_FAILS case(s) failed"; return 1; fi
	log_info "main-gate-harness: OK (branch-safe wrappers, unavailable-not-fake, tool selection, JSON contract, builder-compatible)"
}

# --- main-gate evidence + Semgrep strategy (v0.1.18) ------------------------
MGE_FAILS=0
mge_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; MGE_FAILS=$((MGE_FAILS + 1)); fi; }

# run_main_gate_evidence — self-test group 'main-gate-evidence' (wired into the dispatch + 'all').
run_main_gate_evidence() {
	log_info "main-gate-evidence: Semgrep image strategy, no --config=auto, no DAST/AI in main, evidence registry"
	PRF="$ROOT/templates/workflows/sentinel-shield-pr-fast.yml"
	COMBINED="$ROOT/templates/workflows/sentinel-shield.yml"
	MAIN="$ROOT/templates/workflows/sentinel-shield-main.yml"
	REG="$ROOT/docs/main-gate-live-evidence.md"

	# 1. Semgrep image variable is used (overridable), not a hardcoded :latest in app-scan run blocks.
	mge_check "pr-fast template uses SENTINEL_SHIELD_SEMGREP_IMAGE" "$([ "$(grep -c 'SENTINEL_SHIELD_SEMGREP_IMAGE' "$PRF")" -ge 1 ] && echo yes || echo no)" "yes"
	mge_check "combined template uses SENTINEL_SHIELD_SEMGREP_IMAGE" "$([ "$(grep -c 'SENTINEL_SHIELD_SEMGREP_IMAGE' "$COMBINED")" -ge 1 ] && echo yes || echo no)" "yes"
	mge_check "no semgrep :latest in pr-fast/combined run blocks" "$(grep -hE 'docker run.*semgrep/semgrep:latest' "$PRF" "$COMBINED" | wc -l | tr -d ' ')" "0"

	# 2. No ACTIVE --config=auto app scan (comments / step-names saying "never auto" are fine).
	mge_check "no active --config=auto in templates" "$(grep -rhE 'semgrep[^#]*--config[= ]auto' "$ROOT/templates/workflows" 2>/dev/null | grep -vE '^[[:space:]]*#' | wc -l | tr -d ' ')" "0"

	# 3. Main-gate template runs no DAST/Nuclei/AI (defense-in-depth: must not gate on those).
	mge_check "main template has no ZAP/Nuclei/AI runner calls" "$(grep -ciE 'runners/(zap|nuclei)|zap-baseline|nuclei\.sh|ai-security-review\.sh|kuzushi\.sh' "$MAIN")" "0"

	# 4. Evidence registry contains the four promoted main-gate tools + the run ID.
	for t in CodeQL OSV-Scanner Trivy Syft; do
		mge_check "evidence registry cites $t" "$([ "$(grep -c "$t" "$REG")" -ge 1 ] && echo yes || echo no)" "yes"
	done
	mge_check "evidence registry cites run 27214865086" "$([ "$(grep -c '27214865086' "$REG")" -ge 1 ] && echo yes || echo no)" "yes"
	# 5. Baseline-failure (npm critical) documented as correct gate behavior, not suppressed.
	mge_check "registry documents baseline FAIL run 27214863297" "$([ "$(grep -c '27214863297' "$REG")" -ge 1 ] && echo yes || echo no)" "yes"

	if [ "$MGE_FAILS" -ne 0 ]; then log_error "main-gate-evidence: $MGE_FAILS case(s) failed"; return 1; fi
	log_info "main-gate-evidence: OK (Semgrep var, no auto/DAST/AI, registry cites CodeQL/OSV/Trivy/Syft + runs)"
}

# --- main-gate execution hardening (v0.1.19) --------------------------------
MX_FAILS=0
mx_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; MX_FAILS=$((MX_FAILS + 1)); fi; }
# Build a controlled PATH dir: real jq symlinked in, plus any fake binaries we drop.
_mx_fakebin() { _b=$(mktemp -d); ln -s "$(command -v jq)" "$_b/jq" 2>/dev/null || cp "$(command -v jq)" "$_b/jq"; echo "$_b"; }

# run_main_gate_exec — self-test group 'main-gate-exec' (wired into the dispatch + 'all').
run_main_gate_exec() {
	log_info "main-gate-exec: grype/dep-check/dockle execution modes + semgrep-image verify (fake binaries)"
	GR="$ROOT/scripts/audits/grype.sh"; DC="$ROOT/scripts/audits/dependency-check.sh"
	DK="$ROOT/scripts/audits/dockle.sh"; VS="$ROOT/scripts/verify-semgrep-image.sh"
	_d=$(mktemp -d)

	# --- Grype: sbom mode, missing SBOM -> unavailable, no file ---
	_rc=0; ( cd "$_d" && SENTINEL_SHIELD_GRYPE_MODE=sbom SENTINEL_SHIELD_GRYPE_SBOM_PATH="$_d/nope.spdx.json" sh "$GR" "$_d/grype.json" >/dev/null 2>&1 ) || _rc=$?
	mx_check "grype sbom missing-SBOM exit 0" "$_rc" "0"
	mx_check "grype sbom missing-SBOM no file" "$([ -f "$_d/grype.json" ] && echo file || echo none)" "none"

	# --- Grype: sbom mode + fixture SBOM + fake grype -> pass (file produced) ---
	fb=$(_mx_fakebin)
	cat > "$fb/grype" <<'FAKE'
#!/bin/sh
# fake grype: find --file arg, write minimal valid JSON
out=""; while [ $# -gt 0 ]; do [ "$1" = "--file" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"matches":[]}' > "$out"
FAKE
	chmod +x "$fb/grype"
	echo '{"SPDXID":"x"}' > "$_d/sbom.spdx.json"
	( cd "$_d" && PATH="$fb:/usr/bin:/bin" SENTINEL_SHIELD_GRYPE_MODE=sbom SENTINEL_SHIELD_GRYPE_SBOM_PATH="$_d/sbom.spdx.json" sh "$GR" "$_d/grype2.json" >/dev/null 2>&1 )
	mx_check "grype sbom + fake binary -> report" "$([ -s "$_d/grype2.json" ] && jq -e . "$_d/grype2.json" >/dev/null 2>&1 && echo valid || echo no)" "valid"

	# --- Dependency-Check: disabled (default) -> unavailable, no file ---
	( sh "$DC" "$_d/dc.json" >/dev/null 2>&1 )
	mx_check "dep-check disabled -> no file" "$([ -f "$_d/dc.json" ] && echo file || echo none)" "none"
	# enabled but no binary + no image (restricted PATH, no docker) -> unavailable
	fb2=$(_mx_fakebin)
	( SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled PATH="$fb2:/usr/bin:/bin" sh "$DC" "$_d/dc2.json" >/dev/null 2>&1 )
	mx_check "dep-check enabled no-binary -> no file" "$([ -f "$_d/dc2.json" ] && echo file || echo none)" "none"
	# enabled + fake dependency-check producing VALID JSON (exit 0) -> report kept + collector parses
	fb4=$(_mx_fakebin)
	cat > "$fb4/dependency-check" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"dependencies":[{"vulnerabilities":[{"severity":"HIGH"}]}]}' > "$out"
FAKE
	chmod +x "$fb4/dependency-check"
	( cd "$_d" && PATH="$fb4:/usr/bin:/bin" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled sh "$DC" "$_d/dc3.json" >/dev/null 2>&1 )
	mx_check "dep-check fake valid JSON -> report" "$([ -s "$_d/dc3.json" ] && jq -e . "$_d/dc3.json" >/dev/null 2>&1 && echo valid || echo no)" "valid"
	mx_check "dep-check collector parses fake report" "$(sh "$ROOT/scripts/collectors/dependency-check.sh" --input "$_d/dc3.json" | jq -r '"\(.status):\(.summary.high_vulnerabilities)"')" "fail:1"
	# enabled + fake dependency-check VALID JSON but NON-ZERO exit (findings) -> report preserved
	fb5=$(_mx_fakebin)
	cat > "$fb5/dependency-check" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--out" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"dependencies":[{"vulnerabilities":[{"severity":"CRITICAL"}]}]}' > "$out"
exit 1
FAKE
	chmod +x "$fb5/dependency-check"
	( cd "$_d" && PATH="$fb5:/usr/bin:/bin" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled sh "$DC" "$_d/dc4.json" >/dev/null 2>&1 )
	mx_check "dep-check non-zero exit + valid JSON preserved" "$([ -s "$_d/dc4.json" ] && jq -e '.dependencies[0].vulnerabilities[0].severity' "$_d/dc4.json" >/dev/null 2>&1 && echo kept || echo gone)" "kept"
	# enabled + fake dependency-check that exits WITHOUT producing JSON -> no fake-clean (no file)
	fb6=$(_mx_fakebin)
	cat > "$fb6/dependency-check" <<'FAKE'
#!/bin/sh
exit 1
FAKE
	chmod +x "$fb6/dependency-check"
	( cd "$_d" && PATH="$fb6:/usr/bin:/bin" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled sh "$DC" "$_d/dc5.json" >/dev/null 2>&1 )
	mx_check "dep-check no-JSON exit -> no fake report" "$([ -f "$_d/dc5.json" ] && echo file || echo none)" "none"

	# --- Dockle: missing SENTINEL_SHIELD_IMAGE -> unavailable ---
	( unset SENTINEL_SHIELD_IMAGE; sh "$DK" "$_d/dk.json" >/dev/null 2>&1 )
	mx_check "dockle no-image -> no file" "$([ -f "$_d/dk.json" ] && echo file || echo none)" "none"
	# image set + fake dockle -> report pass
	fb3=$(_mx_fakebin)
	cat > "$fb3/dockle" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"summary":{"fatal":0},"details":[]}' > "$out"
FAKE
	chmod +x "$fb3/dockle"
	( PATH="$fb3:/usr/bin:/bin" SENTINEL_SHIELD_IMAGE=example/app:latest sh "$DK" "$_d/dk2.json" >/dev/null 2>&1 )
	mx_check "dockle + image + fake binary -> report" "$([ -s "$_d/dk2.json" ] && jq -e . "$_d/dk2.json" >/dev/null 2>&1 && echo valid || echo no)" "valid"

	# --- Semgrep verify: missing tool (no semgrep, no docker) -> unavailable exit 0 ---
	fbv=$(_mx_fakebin)
	_rc=0; ( PATH="$fbv:/usr/bin:/bin" sh "$VS" "$ROOT/tests/fixtures/semgrep/php-modern" "$_d/sv.json" >/dev/null 2>&1 ) || _rc=$?
	mx_check "semgrep-verify no-tool exit 0 (unavailable)" "$_rc" "0"

	# --- Semgrep verify: fake semgrep emitting a PARSER ERROR -> fail (exit 1) ---
	fbe=$(_mx_fakebin)
	cat > "$fbe/semgrep" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"errors":[{"type":"PartialParsing"}],"results":[]}' > "$out"
FAKE
	chmod +x "$fbe/semgrep"
	_rc=0; ( PATH="$fbe:/usr/bin:/bin" sh "$VS" "$ROOT/tests/fixtures/semgrep/php-modern" "$_d/sve.json" >/dev/null 2>&1 ) || _rc=$?
	mx_check "semgrep-verify parser-error -> exit 1" "$_rc" "1"

	# --- Semgrep verify: fake semgrep clean -> pass (exit 0) ---
	fbs=$(_mx_fakebin)
	cat > "$fbs/semgrep" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"errors":[],"results":[]}' > "$out"
FAKE
	chmod +x "$fbs/semgrep"
	_rc=0; ( PATH="$fbs:/usr/bin:/bin" sh "$VS" "$ROOT/tests/fixtures/semgrep/php-modern" "$_d/svs.json" >/dev/null 2>&1 ) || _rc=$?
	mx_check "semgrep-verify clean -> exit 0" "$_rc" "0"

	# --- Harness tools JSON v1.1 fields ---
	rm -rf "$_d/raw"; sh "$ROOT/scripts/run-main-gate-validation.sh" --target "$ROOT/tests/fixtures/projects/laravel-react-docker" --output-dir "$_d/raw" --tool grype >/dev/null 2>&1 || true
	J="$_d/raw/main-gate-validation-tools.json"
	mx_check "harness tools JSON version 1.1" "$(jq -r .version "$J" 2>/dev/null)" "1.1"
	mx_check "harness grype has duration_seconds field" "$(jq 'has("tools") and (.tools.grype|has("duration_seconds") and has("executor") and has("valid_json"))' "$J" 2>/dev/null)" "true"

	# --- v0.1.21: scheduled workflow cache + always-upload; digest-pinning docs + template overrides ---
	SCHED="$ROOT/templates/workflows/sentinel-shield-scheduled.yml"
	mx_check "scheduled has actions/cache" "$([ "$(grep -c 'uses: actions/cache' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "scheduled cache key has month stamp" "$([ "$(grep -c 'steps.month.outputs.ym' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "scheduled cache restore-keys (partial reuse)" "$([ "$(grep -c 'restore-keys' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "scheduled uploads with if: always()" "$([ "$(grep -c 'if: always()' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "scheduled runs dependency-check audit" "$([ "$(grep -c 'audits/dependency-check.sh' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"
	PIN="$ROOT/docs/scanner-image-digest-pinning.md"
	for _img in semgrep/semgrep anchore/grype goodwithtech/dockle; do
		mx_check "digest-pinning doc names $_img" "$([ "$(grep -c "$_img" "$PIN")" -ge 1 ] && echo yes || echo no)" "yes"
	done
	mx_check "digest-pinning doc has sha256 digests" "$([ "$(grep -c 'sha256:' "$PIN")" -ge 3 ] && echo yes || echo no)" "yes"
	mx_check "pr-fast template allows semgrep digest override" "$([ "$(grep -c 'SENTINEL_SHIELD_SEMGREP_IMAGE' "$ROOT/templates/workflows/sentinel-shield-pr-fast.yml")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "main template allows grype digest override" "$([ "$(grep -c 'SENTINEL_SHIELD_GRYPE_IMAGE' "$ROOT/templates/workflows/sentinel-shield-main.yml")" -ge 1 ] && echo yes || echo no)" "yes"
	mx_check "scheduled template shows digest override comments" "$([ "$(grep -c '@sha256:' "$SCHED")" -ge 1 ] && echo yes || echo no)" "yes"

	rm -rf "$_d" "$fb" "$fb2" "$fb3" "$fb4" "$fb5" "$fb6" "$fbv" "$fbe" "$fbs"
	if [ "$MX_FAILS" -ne 0 ]; then log_error "main-gate-exec: $MX_FAILS case(s) failed"; return 1; fi
	log_info "main-gate-exec: OK (grype sbom/fs, dep-check disabled/enabled/preserve/no-fake, dockle, semgrep-verify, cache+digest pinning, tools v1.1)"
}

# --- install-matrix (v0.1.22): round-trip docker-only / php-library / node-react -----------
IM_FAILS=0
im_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; IM_FAILS=$((IM_FAILS + 1)); fi; }
# run_install_matrix — self-test group 'install-matrix' (wired into the dispatch + 'all').
run_install_matrix() {
	log_info "install-matrix: install/sync round-trip for docker, php-library, node-react (temp dirs, no network)"
	for _prof in docker php-library node-react symfony; do
		_t=$(mktemp -d)
		# dry-run writes nothing
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" >/dev/null 2>&1
		im_check "$_prof: dry-run writes no files" "$(find "$_t" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
		# apply creates the managed workflow + profile.yaml, never accepted-risks.json
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" --apply --mode report-only >/dev/null 2>&1
		im_check "$_prof: apply creates profile.yaml" "$([ -f "$_t/.sentinel-shield/profile.yaml" ] && echo yes || echo no)" "yes"
		im_check "$_prof: apply creates workflow" "$([ -f "$_t/.github/workflows/sentinel-shield.yml" ] && echo yes || echo no)" "yes"
		im_check "$_prof: NEVER created accepted-risks.json" "$([ -f "$_t/.sentinel-shield/accepted-risks.json" ] && echo yes || echo no)" "no"
		# a real accepted-risks.json is preserved even with --force
		printf '{"version":"1.1","risks":[{"id":"KEEP_%s"}]}' "$_prof" > "$_t/.sentinel-shield/accepted-risks.json"
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" --apply --force >/dev/null 2>&1
		im_check "$_prof: --force preserves accepted-risks.json" "$(grep -c "KEEP_$_prof" "$_t/.sentinel-shield/accepted-risks.json")" "1"
		# sync after a clean install reports no managed drift
		_drift=$(sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" --profile "$_prof" 2>/dev/null | grep -c 'manual-review-needed (managed drift' || true)
		im_check "$_prof: sync reports no managed drift after install" "$_drift" "0"
		rm -rf "$_t"
	done
	if [ "$IM_FAILS" -ne 0 ]; then log_error "install-matrix: $IM_FAILS case(s) failed"; return 1; fi
	log_info "install-matrix: OK (docker/php-library/node-react round-trip; accepted-risks never touched)"
}

# --- mode-readiness (v0.1.22): strict gates fire; report-only/baseline don't inherit them ---
MR_FAILS=0
mr_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; MR_FAILS=$((MR_FAILS + 1)); fi; }
# run_mode_readiness — self-test group 'mode-readiness' (wired into the dispatch + 'all').
run_mode_readiness() {
	log_info "mode-readiness: strict fails on strict-only violations; report-only/baseline do not inherit them"
	_d=$(mktemp -d)
	# resolve fail_on flags per mode
	for _m in report-only baseline strict regulated; do
		printf 'project:\n  name: t\ngates:\n  mode: %s\n' "$_m" > "$_d/p.yaml"
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$_m" --format json --output-dir "$_d" >/dev/null 2>&1
		cp "$_d/sentinel-shield-gates.json" "$_d/gates-$_m.json"
	done
	flag() { jq -r ".fail_on.$2" "$_d/gates-$1.json"; }
	# 38: report-only and baseline must NOT inherit strict-only gates (style_violations, iac_violations)
	mr_check "report-only style_violations not gated" "$(flag report-only style_violations)" "false"
	mr_check "report-only iac_violations not gated"   "$(flag report-only iac_violations)"   "false"
	mr_check "baseline style_violations not gated"    "$(flag baseline style_violations)"    "false"
	mr_check "baseline iac_violations not gated"      "$(flag baseline iac_violations)"      "false"
	# strict DOES gate them
	mr_check "strict gates style_violations"          "$(flag strict style_violations)"      "true"
	mr_check "strict gates iac_violations"            "$(flag strict iac_violations)"        "true"
	# 37: a summary with strict-only violations FAILS strict enforcement but PASSES baseline
	mkdir -p "$_d/raw"
	printf '{"files":[{"name":"a.php","violations":["x"]}]}' > "$_d/raw/php-style.json"
	printf '{"summary":{"failed":3}}' > "$_d/raw/checkov.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/raw" --output "$_d/sum.json" --project-name t >/dev/null 2>&1
	mr_check "summary has style_violations>0" "$([ "$(jq '.summary.style_violations // 0' "$_d/sum.json")" -gt 0 ] && echo yes || echo no)" "yes"
	mr_check "summary has iac_violations>0"   "$([ "$(jq '.summary.iac_violations // 0' "$_d/sum.json")" -gt 0 ] && echo yes || echo no)" "yes"
	for _m in baseline strict; do
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$_m" --format env --output-dir "$_d" >/dev/null 2>&1
		if sh "$ROOT/scripts/enforce-gates.sh" --summary "$_d/sum.json" --gates-env "$_d/sentinel-shield-gates.env" --output-dir "$_d" --format json >/dev/null 2>&1; then _r=pass; else _r=fail; fi
		eval "_res_$_m=$_r"
	done
	mr_check "baseline PASSES strict-only violations" "$_res_baseline" "pass"
	mr_check "strict FAILS strict-only violations" "$_res_strict" "fail"
	rm -rf "$_d"
	if [ "$MR_FAILS" -ne 0 ]; then log_error "mode-readiness: $MR_FAILS case(s) failed"; return 1; fi
	log_info "mode-readiness: OK (strict gates fire; report-only/baseline do not inherit; strict fails, baseline passes)"
}

# --- v022-fixtures (v0.1.22): IaC-no-binary, deptrac-absent, dep-policy lockfiles, dep-check
#     findings, grype SBOM fake, dockle image-required, summary builder key coverage ----------
KV_FAILS=0
kv_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; KV_FAILS=$((KV_FAILS + 1)); fi; }
# run_v022_fixtures — self-test group 'v022-fixtures' (wired into the dispatch + 'all').
run_v022_fixtures() {
	log_info "v022-fixtures: IaC-no-binary, deptrac-absent, dep-policy lockfiles, dep-check findings, summary keys"
	_d=$(mktemp -d); _b=$(mktemp -d)
	ln -s "$(command -v jq)" "$_b/jq" 2>/dev/null || cp "$(command -v jq)" "$_b/jq"

	# 47: IaC files present but NO checkov binary -> audit no-ops (no file) -> collector unavailable.
	mkdir -p "$_d/iac"; printf 'resource "x" {}\n' > "$_d/iac/main.tf"
	( cd "$_d/iac" && PATH="$_b:/usr/bin:/bin" sh "$ROOT/scripts/audits/checkov.sh" "$_d/iac/checkov.json" >/dev/null 2>&1 )
	kv_check "IaC-no-binary: checkov writes no fake file" "$([ -f "$_d/iac/checkov.json" ] && echo file || echo none)" "none"
	kv_check "IaC-no-binary: collector reports unavailable" "$(sh "$ROOT/scripts/collectors/checkov.sh" --input "$_d/iac/checkov.json" 2>/dev/null | jq -r .status)" "unavailable"

	# 48: deptrac/architecture config absent -> no deptrac.json -> collector unavailable (not fake-clean).
	kv_check "deptrac-absent: collector unavailable" "$(sh "$ROOT/scripts/collectors/deptrac.sh" --input "$_d/nope-deptrac.json" 2>/dev/null | jq -r .status)" "unavailable"

	# 49: dependency-policy — manifest present WITHOUT a lockfile = violation; WITH lockfile = clean.
	mkdir -p "$_d/nolock"; printf '{}' > "$_d/nolock/composer.json"
	sh "$ROOT/scripts/audits/dependency-policy.sh" "$_d/nolock/dp.json" "$_d/nolock" >/dev/null 2>&1
	kv_check "dep-policy missing lockfile -> >=1 violation" "$([ "$(jq '.count' "$_d/nolock/dp.json")" -ge 1 ] && echo yes || echo no)" "yes"
	kv_check "dep-policy collector maps violations" "$([ "$(sh "$ROOT/scripts/collectors/dependency-policy.sh" --input "$_d/nolock/dp.json" 2>/dev/null | jq '.summary.dependency_policy_violations')" -ge 1 ] && echo yes || echo no)" "yes"
	mkdir -p "$_d/lock"; printf '{}' > "$_d/lock/composer.json"; printf '{}' > "$_d/lock/composer.lock"
	sh "$ROOT/scripts/audits/dependency-policy.sh" "$_d/lock/dp.json" "$_d/lock" >/dev/null 2>&1
	kv_check "dep-policy with lockfile -> 0 violations" "$(jq '.count' "$_d/lock/dp.json")" "0"

	# 6 (Lane 1): the committed Dependency-Check findings fixture parses to critical/high counts.
	DCFIX="$ROOT/tests/fixtures/dependency-check/with-findings.json"
	kv_check "dep-check findings fixture parses" "$(sh "$ROOT/scripts/collectors/dependency-check.sh" --input "$DCFIX" 2>/dev/null | jq -r '"\(.status):\(.summary.critical_vulnerabilities):\(.summary.high_vulnerabilities)"')" "fail:1:1"

	# 50: SBOM-first Grype with a fake binary writes a valid report from the SBOM.
	_gb=$(mktemp -d); cp "$_b/jq" "$_gb/jq" 2>/dev/null || true
	cat > "$_gb/grype" <<'FAKE'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do [ "$1" = "--file" ] && out="$2"; shift; done
[ -n "$out" ] && printf '{"matches":[]}' > "$out"
FAKE
	chmod +x "$_gb/grype"; printf '{"SPDXID":"x"}' > "$_d/sbom.spdx.json"
	( cd "$_d" && PATH="$_gb:/usr/bin:/bin" SENTINEL_SHIELD_GRYPE_MODE=sbom SENTINEL_SHIELD_GRYPE_SBOM_PATH="$_d/sbom.spdx.json" sh "$ROOT/scripts/audits/grype.sh" "$_d/grype.json" >/dev/null 2>&1 )
	kv_check "grype SBOM-first fake binary -> valid report" "$([ -s "$_d/grype.json" ] && jq -e . "$_d/grype.json" >/dev/null 2>&1 && echo valid || echo no)" "valid"

	# 51: Dockle requires a built image — no SENTINEL_SHIELD_IMAGE -> unavailable, no file.
	( unset SENTINEL_SHIELD_IMAGE; PATH="$_b:/usr/bin:/bin" sh "$ROOT/scripts/audits/dockle.sh" "$_d/dockle.json" >/dev/null 2>&1 )
	kv_check "dockle image-required -> no file" "$([ -f "$_d/dockle.json" ] && echo file || echo none)" "none"

	# 54: summary builder emits every canonical summary key.
	mkdir -p "$_d/raw"; printf '[]' > "$_d/raw/gitleaks.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/raw" --output "$_d/sum.json" --project-name t >/dev/null 2>&1
	_missingkeys=0
	for _k in secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities \
		architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions \
		expired_exceptions style_violations php_syntax_errors dependency_policy_violations \
		iac_violations dast_findings container_image_violations repository_health_warnings ai_review_findings; do
		[ "$(jq "has(\"summary\") and (.summary|has(\"$_k\"))" "$_d/sum.json" 2>/dev/null)" = "true" ] || { log_error "  summary missing key: $_k"; _missingkeys=$((_missingkeys + 1)); }
	done
	kv_check "summary builder emits all canonical keys" "$_missingkeys" "0"

	# 52: every templates/raw/*.json fixture is valid JSON.
	_badjson=0
	for _f in "$ROOT"/templates/raw/*.json; do
		[ -f "$_f" ] || continue
		jq -e . "$_f" >/dev/null 2>&1 || { log_error "  invalid templates/raw JSON: $_f"; _badjson=$((_badjson + 1)); }
	done
	kv_check "templates/raw/*.json all valid" "$_badjson" "0"

	rm -rf "$_d" "$_b" "$_gb"
	if [ "$KV_FAILS" -ne 0 ]; then log_error "v022-fixtures: $KV_FAILS case(s) failed"; return 1; fi
	log_info "v022-fixtures: OK (IaC-no-binary, deptrac-absent, dep-policy lockfiles, dep-check findings, grype/dockle, summary keys, raw JSON)"
}

# --- v023-coverage: dep-check clean, mode fixtures, IaC fixtures, DAST guard, supply-chain --
CV_FAILS=0
cv_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; CV_FAILS=$((CV_FAILS + 1)); fi; }
# run_v023_coverage — self-test group 'v023-coverage' (wired into the dispatch + 'all').
run_v023_coverage() {
	log_info "v023-coverage: dep-check clean fixture, strict/regulated mode fixtures, IaC/deptrac/arch, DAST guard, no-latest"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; _d=$(mktemp -d)
	_b=$(mktemp -d); ln -s "$(command -v jq)" "$_b/jq" 2>/dev/null || cp "$(command -v jq)" "$_b/jq"

	# --- Dependency-Check clean fixture: valid report, 0 findings -> status pass (NOT unavailable) ---
	cv_check "dep-check clean fixture -> pass 0/0/0" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/clean.json" 2>/dev/null | jq -r '"\(.status):\(.summary.critical_vulnerabilities):\(.summary.high_vulnerabilities):\(.summary.medium_vulnerabilities)"')" "pass:0:0:0"
	cv_check "dep-check warm-cache marker fixture exists" "$([ -f "$F/dependency-check/warm-cache/.nvd-cache-marker" ] && echo yes || echo no)" "yes"

	# --- Mode fixtures (Agent D): collector mappings ---
	cv_check "mode style fixture -> style_violations=2" "$(sh "$C/php-style.sh" --input "$F/modes/style-violation/php-style.json" 2>/dev/null | jq '.summary.style_violations')" "2"
	cv_check "mode medium-vuln fixture -> medium_vulnerabilities=1" "$(sh "$C/grype.sh" --input "$F/modes/medium-vuln/grype.json" 2>/dev/null | jq '.summary.medium_vulnerabilities')" "1"
	cv_check "mode iac fixture -> iac_violations=2" "$(sh "$C/checkov.sh" --input "$F/modes/iac-violation/checkov.json" 2>/dev/null | jq '.summary.iac_violations')" "2"
	cv_check "mode dast fixture -> dast_findings=1" "$(sh "$C/zap.sh" --input "$F/modes/dast-finding/zap.json" 2>/dev/null | jq '.summary.dast_findings')" "1"

	# --- Strict gates fire where baseline does not (style+iac+medium) ---
	mkdir -p "$_d/raw"
	cp "$F/modes/style-violation/php-style.json" "$_d/raw/php-style.json"
	cp "$F/modes/medium-vuln/grype.json" "$_d/raw/grype.json"
	cp "$F/modes/iac-violation/checkov.json" "$_d/raw/checkov.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/raw" --output "$_d/sum.json" --project-name t >/dev/null 2>&1
	printf 'project:\n  name: t\ngates:\n  mode: baseline\n' > "$_d/p.yaml"
	enforce_mode() { # <mode> -> echo pass|fail
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$1" --format env --output-dir "$_d" >/dev/null 2>&1
		if sh "$ROOT/scripts/enforce-gates.sh" --summary "$2" --gates-env "$_d/sentinel-shield-gates.env" --output-dir "$_d" --format json >/dev/null 2>&1; then echo pass; else echo fail; fi
	}
	cv_check "baseline PASSES style+iac+medium" "$(enforce_mode baseline "$_d/sum.json")" "pass"
	cv_check "strict FAILS style+iac+medium" "$(enforce_mode strict "$_d/sum.json")" "fail"
	# --- Regulated gates fire where strict does not (dast) ---
	rm -rf "$_d/r2"; mkdir -p "$_d/r2/raw"; cp "$F/modes/dast-finding/zap.json" "$_d/r2/raw/zap.json"
	# Isolate dast_findings: provide a real SBOM + release evidence next to the output so the
	# strict-gated missing_sbom/missing_release_evidence are clean — the ONLY non-clean gate is dast.
	printf '{"SPDXID":"SPDXRef-DOCUMENT"}' > "$_d/r2/sbom.spdx.json"
	printf 'release evidence\n' > "$_d/r2/release-evidence.md"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/r2/raw" --output "$_d/r2/sum2.json" --project-name t >/dev/null 2>&1
	cv_check "strict PASSES dast-only finding" "$(enforce_mode strict "$_d/r2/sum2.json")" "pass"
	cv_check "regulated FAILS dast finding" "$(enforce_mode regulated "$_d/r2/sum2.json")" "fail"

	# --- IaC fixtures (Agent F): collector mappings ---
	cv_check "iac checkov-findings -> iac_violations=2" "$(sh "$C/checkov.sh" --input "$F/iac/checkov-findings.json" 2>/dev/null | jq '.summary.iac_violations')" "2"
	cv_check "iac conftest-findings -> iac_violations>=1" "$([ "$(sh "$C/conftest.sh" --input "$F/iac/conftest-findings.json" 2>/dev/null | jq '.summary.iac_violations')" -ge 1 ] && echo yes || echo no)" "yes"
	cv_check "iac terrascan-findings -> iac_violations>=1" "$([ "$(sh "$C/terrascan.sh" --input "$F/iac/terrascan-findings.json" 2>/dev/null | jq '.summary.iac_violations')" -ge 1 ] && echo yes || echo no)" "yes"
	# IaC with tf files present but NO checkov binary -> no fake report -> unavailable.
	mkdir -p "$_d/tf"; cp "$F/iac/terraform/main.tf" "$_d/tf/main.tf"
	( cd "$_d/tf" && PATH="$_b:/usr/bin:/bin" sh "$ROOT/scripts/audits/checkov.sh" "$_d/tf/checkov.json" >/dev/null 2>&1 )
	cv_check "IaC tf + no checkov binary -> no fake file" "$([ -f "$_d/tf/checkov.json" ] && echo file || echo none)" "none"
	cv_check "IaC no-binary -> collector unavailable" "$(sh "$C/checkov.sh" --input "$_d/tf/checkov.json" 2>/dev/null | jq -r .status)" "unavailable"
	# No IaC files at all + no binary -> still unavailable (never fake-clean).
	( cd "$_d" && PATH="$_b:/usr/bin:/bin" sh "$ROOT/scripts/audits/checkov.sh" "$_d/noiac.json" >/dev/null 2>&1 )
	cv_check "IaC no-files -> collector unavailable" "$(sh "$C/checkov.sh" --input "$_d/noiac.json" 2>/dev/null | jq -r .status)" "unavailable"

	# --- Deptrac + architecture fixtures ---
	cv_check "deptrac config fixture is valid YAML" "$(ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]));print "ok"' "$F/deptrac/deptrac.yaml" 2>/dev/null)" "ok"
	cv_check "deptrac absent report -> unavailable" "$(sh "$C/deptrac.sh" --input "$_d/no-deptrac.json" 2>/dev/null | jq -r .status)" "unavailable"
	cv_check "architecture-tests fixture -> architecture_violations=0 pass" "$(sh "$C/architecture-tests.sh" --input "$F/architecture/architecture-tests.json" 2>/dev/null | jq -r '"\(.status):\(.summary.architecture_violations)"')" "pass:0"

	# --- DAST guard (runners; no scan ever runs) ---
	DG="$ROOT/scripts/runners"
	_rc=0; ( unset SENTINEL_SHIELD_DAST_TARGET_URL; sh "$DG/zap-baseline.sh" "$_d/z.json" >/dev/null 2>&1 ) || _rc=$?
	cv_check "DAST missing target -> skip exit 0" "$_rc" "0"
	_rc=0; ( SENTINEL_SHIELD_DAST_TARGET_URL=ftp://x SENTINEL_SHIELD_DAST_ALLOWED_HOST=x sh "$DG/zap-baseline.sh" "$_d/z.json" >/dev/null 2>&1 ) || _rc=$?
	cv_check "DAST non-http(s) -> fail closed exit 3" "$_rc" "3"
	_rc=0; ( SENTINEL_SHIELD_DAST_TARGET_URL=https://evil.test/x SENTINEL_SHIELD_DAST_ALLOWED_HOST=staging.app sh "$DG/zap-baseline.sh" "$_d/z.json" >/dev/null 2>&1 ) || _rc=$?
	cv_check "DAST host mismatch -> fail closed exit 3" "$_rc" "3"
	_rc=0; ( SENTINEL_SHIELD_DAST_TARGET_URL=https://evil.test/x SENTINEL_SHIELD_DAST_ALLOWED_HOST=staging.app sh "$DG/nuclei.sh" "$_d/n.json" >/dev/null 2>&1 ) || _rc=$?
	cv_check "Nuclei host mismatch -> fail closed exit 3" "$_rc" "3"

	# --- Supply-chain: no template pins a validated scanner to :latest ---
	_latest=$(grep -rlE '(semgrep/semgrep|anchore/grype|goodwithtech/dockle):latest' "$ROOT/templates/workflows" 2>/dev/null | wc -l | tr -d ' ')
	cv_check "no validated scanner pinned to :latest" "$_latest" "0"

	rm -rf "$_d" "$_b"
	if [ "$CV_FAILS" -ne 0 ]; then log_error "v023-coverage: $CV_FAILS case(s) failed"; return 1; fi
	log_info "v023-coverage: OK (dep-check clean, strict/regulated fixtures, IaC/deptrac/arch, DAST fail-closed, no :latest)"
}

# --- v023-regression: cross-cutting invariants ------------------------------------------------
RG_FAILS=0
rg_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; RG_FAILS=$((RG_FAILS + 1)); fi; }
# run_v023_regression — self-test group 'v023-regression' (wired into the dispatch + 'all').
run_v023_regression() {
	log_info "v023-regression: fail_on flags, secrets non-suppressible, invalid/missing collectors, manifests, docs, changelog, .claude"
	C="$ROOT/scripts/collectors"; _d=$(mktemp -d)

	# 117: every expected fail_on flag is present in resolved gates (regulated).
	sh "$ROOT/scripts/resolve-gates.sh" --profile /dev/null --mode regulated --format json --output-dir "$_d" >/dev/null 2>&1
	_missing=0
	for _k in secrets critical_vulnerabilities high_vulnerabilities medium_vulnerabilities \
		architecture_violations type_errors test_failures unsafe_docker unsafe_github_actions \
		expired_exceptions style_violations php_syntax_errors dependency_policy_violations \
		iac_violations dast_findings container_image_violations repository_health_warnings \
		ai_review_findings missing_release_evidence missing_sbom; do
		[ "$(jq "has(\"fail_on\") and (.fail_on|has(\"$_k\"))" "$_d/sentinel-shield-gates.json" 2>/dev/null)" = "true" ] || { log_error "  fail_on missing: $_k"; _missing=$((_missing + 1)); }
	done
	rg_check "all expected fail_on flags present" "$_missing" "0"

	# 118: secrets are NEVER suppressible by accepted-risk.
	mkdir -p "$_d/raw"; printf '[{"Description":"leak","Secret":"x"}]' > "$_d/raw/gitleaks.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/raw" --output "$_d/sum.json" --project-name t >/dev/null 2>&1
	rg_check "gitleaks fixture -> secrets=1" "$(jq '.summary.secrets' "$_d/sum.json")" "1"
	sh "$ROOT/scripts/resolve-gates.sh" --profile /dev/null --mode baseline --format env --output-dir "$_d" >/dev/null 2>&1
	printf '{"version":"1.1","risks":[{"id":"s","gate":"secrets","scope":"gate","owner":"p","severity":"high","reason":"x","expires_at":"2999-12-31","status":"approved"}]}' > "$_d/ar.json"
	if sh "$ROOT/scripts/enforce-gates.sh" --summary "$_d/sum.json" --gates-env "$_d/sentinel-shield-gates.env" --accepted-risks "$_d/ar.json" --output-dir "$_d" --format json >/dev/null 2>&1; then _sr=pass; else _sr=fail; fi
	rg_check "secrets NOT suppressible (still fails)" "$_sr" "fail"

	# 121/122: invalid JSON -> exit 2; missing report -> unavailable (sample collectors).
	printf 'NOT JSON' > "$_d/bad.json"
	_rc=0; sh "$C/grype.sh" --input "$_d/bad.json" >/dev/null 2>&1 || _rc=$?; rg_check "invalid JSON -> exit 2 (grype)" "$_rc" "2"
	_rc=0; sh "$C/checkov.sh" --input "$_d/bad.json" >/dev/null 2>&1 || _rc=$?; rg_check "invalid JSON -> exit 2 (checkov)" "$_rc" "2"
	rg_check "missing report -> unavailable (grype)" "$(sh "$C/grype.sh" --input "$_d/nope.json" 2>/dev/null | jq -r .status)" "unavailable"
	rg_check "missing report -> unavailable (zap)" "$(sh "$C/zap.sh" --input "$_d/nope.json" 2>/dev/null | jq -r .status)" "unavailable"

	# 126: every profile manifest is valid JSON with required fields + valid modes.
	_badman=0
	for _m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
		[ -f "$_m" ] || continue
		jq -e 'has("profile") and has("files")' "$_m" >/dev/null 2>&1 || { log_error "  manifest missing keys: $_m"; _badman=$((_badman + 1)); continue; }
		[ "$(jq '[(.files+ (.workflows//[]) + (.docs//[]))[]|select(.mode|test("^(create-if-missing|overwrite-if-force|sync-managed-block|manual)$")|not)]|length' "$_m")" = "0" ] || { log_error "  manifest bad mode: $_m"; _badman=$((_badman + 1)); }
	done
	rg_check "all profile manifests valid" "$_badman" "0"

	# 127: README links the core docs.
	_nolink=0
	for _doc in product-status.md roadmap.md product-readiness-checklist.md product-contract.md; do
		grep -q "$_doc" "$ROOT/README.md" || { log_error "  README missing link: $_doc"; _nolink=$((_nolink + 1)); }
	done
	rg_check "README links core docs" "$_nolink" "0"

	# 128: CHANGELOG has the v0.1.23 entry.
	rg_check "CHANGELOG has 0.1.23 entry" "$([ "$(grep -c '0.1.23' "$ROOT/CHANGELOG.md")" -ge 1 ] && echo yes || echo no)" "yes"

	# 129: .claude/ is not tracked by git.
	rg_check "no .claude tracked" "$(git -C "$ROOT" ls-files .claude | wc -l | tr -d ' ')" "0"

	rm -rf "$_d"
	if [ "$RG_FAILS" -ne 0 ]; then log_error "v023-regression: $RG_FAILS case(s) failed"; return 1; fi
	log_info "v023-regression: OK (fail_on flags, secrets never suppressed, invalid/missing collectors, manifests, README, changelog, .claude)"
}

# --- v024-collectors: iterate the complete collector fixture library -------------------------
CL_FAILS=0
cl_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; CL_FAILS=$((CL_FAILS + 1)); fi; }
# run_v024_collectors — self-test group 'v024-collectors' (wired into the dispatch + 'all').
run_v024_collectors() {
	log_info "v024-collectors: every collector parses its fixture-library sample + emits a normalized object"
	LIB="$ROOT/tests/fixtures/collectors-v024"; C="$ROOT/scripts/collectors"
	cl_check "fixture library present (>=30 fixtures)" "$([ "$(ls "$LIB"/*.json 2>/dev/null | wc -l | tr -d ' ')" -ge 30 ] && echo yes || echo no)" "yes"
	_bad=0; _n=0
	for _f in "$LIB"/*.json; do
		[ -f "$_f" ] || continue
		_name=$(basename "$_f" .json); _col="$C/$_name.sh"
		[ -f "$_col" ] || { log_warn "  no collector for $_name (skip)"; continue; }
		_n=$((_n + 1))
		# Each collector must: exit 0, emit valid JSON, with .tool and a .status, and a .summary object.
		_out=$(sh "$_col" --input "$_f" 2>/dev/null) || { log_error "  $_name collector exited non-zero"; _bad=$((_bad + 1)); continue; }
		[ "$(printf '%s' "$_out" | jq -e 'has("tool") and has("status") and (.summary|type=="object")' 2>/dev/null)" = "true" ] || { log_error "  $_name bad shape"; _bad=$((_bad + 1)); }
	done
	cl_check "all library collectors emit normalized objects" "$_bad" "0"
	cl_check "exercised a meaningful number of collectors (>=30)" "$([ "$_n" -ge 30 ] && echo yes || echo no)" "yes"
	# Spot-check a few representative mapped counts from the library.
	cl_check "grype fixture -> some vuln count" "$([ "$(sh "$C/grype.sh" --input "$LIB/grype.json" 2>/dev/null | jq '[.summary.critical_vulnerabilities,.summary.high_vulnerabilities,.summary.medium_vulnerabilities]|add')" -ge 1 ] && echo yes || echo no)" "yes"
	cl_check "trufflehog fixture -> secrets (verified and unverified)" "$([ "$(sh "$C/trufflehog.sh" --input "$LIB/trufflehog.json" 2>/dev/null | jq '.summary.secrets')" -ge 1 ] && echo yes || echo no)" "yes"
	if [ "$CL_FAILS" -ne 0 ]; then log_error "v024-collectors: $CL_FAILS case(s) failed"; return 1; fi
	log_info "v024-collectors: OK (complete collector fixture library iterated; normalized output verified)"
}

# --- v024-coverage: dep-check hardening, modes-v024, IaC/deptrac/arch v024, DAST, workflow ----
VC_FAILS=0
vc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; VC_FAILS=$((VC_FAILS + 1)); fi; }
# run_v024_coverage — self-test group 'v024-coverage' (wired into the dispatch + 'all').
run_v024_coverage() {
	log_info "v024-coverage: dep-check fixtures, strict/regulated modes-v024, IaC/deptrac/arch, DAST incl zap-full input gap, workflow uploads"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; _d=$(mktemp -d)
	_b=$(mktemp -d); ln -s "$(command -v jq)" "$_b/jq" 2>/dev/null || cp "$(command -v jq)" "$_b/jq"

	# --- Dependency-Check hardening fixtures (Lane B) ---
	vc_check "dep-check high.json -> high=1 fail" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/high.json" 2>/dev/null | jq -r '"\(.status):\(.summary.high_vulnerabilities)"')" "fail:1"
	vc_check "dep-check critical.json -> critical=1 fail" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/critical.json" 2>/dev/null | jq -r '"\(.status):\(.summary.critical_vulnerabilities)"')" "fail:1"
	vc_check "dep-check empty-deps.json -> pass 0" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/empty-deps.json" 2>/dev/null | jq -r '"\(.status):\(.summary.critical_vulnerabilities)"')" "pass:0"
	vc_check "dep-check clean.json -> pass 0/0/0" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/clean.json" 2>/dev/null | jq -r '"\(.status):\(.summary.high_vulnerabilities)"')" "pass:0"
	_rc=0; sh "$C/dependency-check.sh" --input "$F/dependency-check/malformed.json" >/dev/null 2>&1 || _rc=$?
	vc_check "dep-check malformed.json -> exit 2" "$_rc" "2"

	# --- Mode enforcement (Lane E fixtures) ---
	enforce_mode() { # <mode> <summary> -> pass|fail
		sh "$ROOT/scripts/resolve-gates.sh" --profile "$_d/p.yaml" --mode "$1" --format env --output-dir "$_d" >/dev/null 2>&1
		if sh "$ROOT/scripts/enforce-gates.sh" --summary "$2" --gates-env "$_d/sentinel-shield-gates.env" --output-dir "$_d" --format json >/dev/null 2>&1; then echo pass; else echo fail; fi
	}
	printf 'project:\n  name: t\ngates:\n  mode: baseline\n' > "$_d/p.yaml"
	# multi-violation: build summary, isolate SBOM/release so only style+iac+medium are non-clean.
	rm -rf "$_d/mv"; mkdir -p "$_d/mv/raw"; cp "$F/modes-v024/multi-violation/"*.json "$_d/mv/raw/"
	printf '{"SPDXID":"x"}' > "$_d/mv/sbom.spdx.json"; printf 'rel\n' > "$_d/mv/release-evidence.md"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/mv/raw" --output "$_d/mv/sum.json" --project-name t >/dev/null 2>&1
	vc_check "modes-v024 multi: baseline PASS" "$(enforce_mode baseline "$_d/mv/sum.json")" "pass"
	vc_check "modes-v024 multi: strict FAIL" "$(enforce_mode strict "$_d/mv/sum.json")" "fail"
	# clean: all evidence present -> every mode passes.
	rm -rf "$_d/cl"; mkdir -p "$_d/cl/raw"; cp "$F/modes-v024/clean/gitleaks.json" "$_d/cl/raw/gitleaks.json"
	cp "$F/modes-v024/clean/sbom.spdx.json" "$_d/cl/sbom.spdx.json"; cp "$F/modes-v024/clean/release-evidence.md" "$_d/cl/release-evidence.md"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/cl/raw" --output "$_d/cl/sum.json" --project-name t >/dev/null 2>&1
	vc_check "modes-v024 clean: report-only PASS" "$(enforce_mode report-only "$_d/cl/sum.json")" "pass"
	vc_check "modes-v024 clean: strict PASS" "$(enforce_mode strict "$_d/cl/sum.json")" "pass"
	vc_check "modes-v024 clean: regulated PASS" "$(enforce_mode regulated "$_d/cl/sum.json")" "pass"
	# dast-only: isolate evidence -> strict passes, regulated fails.
	rm -rf "$_d/da"; mkdir -p "$_d/da/raw"; cp "$F/modes-v024/dast-finding/zap.json" "$_d/da/raw/zap.json"
	printf '{"SPDXID":"x"}' > "$_d/da/sbom.spdx.json"; printf 'rel\n' > "$_d/da/release-evidence.md"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/da/raw" --output "$_d/da/sum.json" --project-name t >/dev/null 2>&1
	vc_check "modes-v024 dast: strict PASS" "$(enforce_mode strict "$_d/da/sum.json")" "pass"
	vc_check "modes-v024 dast: regulated FAIL" "$(enforce_mode regulated "$_d/da/sum.json")" "fail"
	# repo-health scorecard fixture maps to repository_health_warnings.
	vc_check "modes-v024 scorecard -> repo_health>=1" "$([ "$(sh "$C/scorecard.sh" --input "$F/modes-v024/repo-health/scorecard.json" 2>/dev/null | jq '.summary.repository_health_warnings')" -ge 1 ] && echo yes || echo no)" "yes"

	# --- IaC-v024 (Lane H) ---
	vc_check "iac-v024 checkov -> iac_violations>=2" "$([ "$(sh "$C/checkov.sh" --input "$F/iac-v024/checkov-findings.json" 2>/dev/null | jq '.summary.iac_violations')" -ge 2 ] && echo yes || echo no)" "yes"
	vc_check "iac-v024 conftest -> iac_violations>=2" "$([ "$(sh "$C/conftest.sh" --input "$F/iac-v024/conftest-findings.json" 2>/dev/null | jq '.summary.iac_violations')" -ge 2 ] && echo yes || echo no)" "yes"
	vc_check "iac-v024 terrascan -> iac_violations>=2" "$([ "$(sh "$C/terrascan.sh" --input "$F/iac-v024/terrascan-findings.json" 2>/dev/null | jq '.summary.iac_violations')" -ge 2 ] && echo yes || echo no)" "yes"

	# --- Deptrac / architecture v024 (Lane I) ---
	vc_check "deptrac-v024 clean -> 0 pass" "$(sh "$C/deptrac.sh" --input "$F/deptrac-v024/deptrac-clean.json" 2>/dev/null | jq -r '"\(.status):\(.summary.architecture_violations)"')" "pass:0"
	vc_check "deptrac-v024 violations -> >=2 fail" "$([ "$(sh "$C/deptrac.sh" --input "$F/deptrac-v024/deptrac-violations.json" 2>/dev/null | jq '.summary.architecture_violations')" -ge 2 ] && echo yes || echo no)" "yes"
	vc_check "architecture-v024 clean -> 0 pass" "$(sh "$C/architecture-tests.sh" --input "$F/architecture-v024/architecture-clean.json" 2>/dev/null | jq -r '"\(.status):\(.summary.architecture_violations)"')" "pass:0"
	vc_check "architecture-v024 violations -> >=2 fail" "$([ "$(sh "$C/architecture-tests.sh" --input "$F/architecture-v024/architecture-violations.json" 2>/dev/null | jq '.summary.architecture_violations')" -ge 2 ] && echo yes || echo no)" "yes"

	# --- DAST fixtures + the zap-full explicit-input gap (Lane F task 108) ---
	vc_check "zap-baseline fixture -> dast_findings=1" "$(sh "$C/zap.sh" --input "$F/dast/zap-baseline.json" 2>/dev/null | jq '.summary.dast_findings')" "1"
	vc_check "zap-FULL via explicit --input -> dast_findings=2" "$(sh "$C/zap.sh" --input "$F/dast/zap-full.json" 2>/dev/null | jq '.summary.dast_findings')" "2"
	vc_check "nuclei fixture -> dast_findings=1 (info excluded)" "$(sh "$C/nuclei.sh" --input "$F/dast/nuclei.json" 2>/dev/null | jq '.summary.dast_findings')" "1"

	# --- Workflow hardening (Lane K): EVERY upload step is if: always() (tighter than v0.1.22 check) ---
	_unguarded=0
	for _wf in "$ROOT"/templates/workflows/*.yml; do
		# `grep -c` PRINTS 0 and EXITS 1 when nothing matches, so `|| echo 0` appends a
		# SECOND zero: the variable becomes "0\n0" and `[ "0 0" -le "0" ]` raises
		# "integer expression expected", firing the || branch as a FALSE FAILURE. Latent
		# today only because every shipped template has an upload; a trap for the next one.
		_ups=$(grep -c 'uses: actions/upload-artifact' "$_wf" 2>/dev/null || true)
		_alw=$(grep -c 'if: always()' "$_wf" 2>/dev/null || true)
		case "$_ups" in '' | *[!0-9]*) _ups=0 ;; esac
		case "$_alw" in '' | *[!0-9]*) _alw=0 ;; esac
		[ "$_ups" -le "$_alw" ] || { log_error "  $(basename "$_wf"): $_ups uploads but only $_alw if:always()"; _unguarded=$((_unguarded + 1)); }
	done
	vc_check "every workflow upload guarded by if: always()" "$_unguarded" "0"

	rm -rf "$_d" "$_b"
	if [ "$VC_FAILS" -ne 0 ]; then log_error "v024-coverage: $VC_FAILS case(s) failed"; return 1; fi
	log_info "v024-coverage: OK (dep-check hardening, modes-v024 strict/regulated, IaC/deptrac/arch, DAST+zap-full, all uploads guarded)"
}

# --- v024-docs: doc-consistency regression (audit-driven) -------------------------------------
VD_FAILS=0
vd_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; VD_FAILS=$((VD_FAILS + 1)); fi; }
# run_v024_docs — self-test group 'v024-docs' (wired into the dispatch + 'all').
run_v024_docs() {
	log_info "v024-docs: changelog/version, Dependency-Check honesty, v1 not-reached, no stray tags, .claude untracked"
	D="$ROOT/docs"
	vd_check "CHANGELOG has 0.1.24 entry" "$([ "$(grep -c '0.1.24' "$ROOT/CHANGELOG.md")" -ge 1 ] && echo yes || echo no)" "yes"
	# Dependency-Check honesty gate (v0.1.30): DC is now PROMOTED — live-validated locally (v0.1.27,
	# dependency-rich) AND in CI (v0.1.30). The original v0.1.24 guard ("must NOT be promoted") is
	# retired; the anti-fake intent is preserved by requiring the promotion to be EVIDENCE-BACKED — the
	# live-evidence registry and product-status must cite the real DC CI run id, never a bare claim.
	vd_check "live-evidence registry promotes Dependency-Check WITH a cited CI run id" "$(grep -qs '27530386965' "$D/main-gate-live-evidence.md" && echo yes || echo no)" "yes"
	vd_check "product-status records DC CI completion (cites run id)" "$(grep -qs '27530386965' "$D/product-status.md" && echo yes || echo no)" "yes"
	# v1.0 not reached must be stated in v1-readiness.
	vd_check "v1-readiness states NOT reached" "$([ "$(grep -ciE 'v1.0 (is )?not (yet )?reach|NOT REACHED' "$D/v1-readiness.md")" -ge 1 ] && echo yes || echo no)" "yes"
	vd_check "v1-closure-v024 present + linked from v1-readiness" "$([ -f "$D/v1-closure-v024.md" ] && [ "$(grep -c 'v1-closure-v024' "$D/v1-readiness.md")" -ge 1 ] && echo yes || echo no)" "yes"
	# No stray XML-ish cruft tags in the source-of-truth docs (audit finding C1).
	_cruft=$(grep -rlE '</(content|invoke)>' "$D"/product-status.md "$D"/roadmap.md "$D"/v1-readiness.md 2>/dev/null | wc -l | tr -d ' ')
	vd_check "no stray </content>|</invoke> tags in core docs" "$_cruft" "0"
	# README links the new v0.1.24 product index docs.
	vd_check "README links product-contract" "$([ "$(grep -c 'product-contract' "$ROOT/README.md")" -ge 1 ] && echo yes || echo no)" "yes"
	vd_check "no .claude tracked" "$(git -C "$ROOT" ls-files .claude | wc -l | tr -d ' ')" "0"
	if [ "$VD_FAILS" -ne 0 ]; then log_error "v024-docs: $VD_FAILS case(s) failed"; return 1; fi
	log_info "v024-docs: OK (changelog, dep-check honesty, v1 not-reached, no cruft tags, .claude untracked)"
}

# --- v025-live: REAL scanner artifacts, zap-full fix, nuclei guard, deptrac/arch/regulated, wf rules
VL_FAILS=0
vl_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; VL_FAILS=$((VL_FAILS + 1)); fi; }
# run_v025_live — self-test group 'v025-live' (wired into the dispatch + 'all').
run_v025_live() {
	log_info "v025-live: real Checkov/Grype/Deptrac artifacts, zap-full fix, nuclei guard, regulated, workflow rules"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; LE="$F/live-evidence"; _d=$(mktemp -d)

	# --- REAL scanner artifacts produced this sprint (parsed by the collectors) ---
	vl_check "REAL checkov 3.3.0 artifact -> iac_violations=16" "$(sh "$C/checkov.sh" --input "$LE/checkov-real.json" 2>/dev/null | jq -r '"\(.status):\(.summary.iac_violations)"')" "fail:16"
	vl_check "REAL grype 0.114.0 artifact -> medium=1" "$(sh "$C/grype.sh" --input "$LE/grype-real.json" 2>/dev/null | jq -r '"\(.status):\(.summary.medium_vulnerabilities)"')" "fail:1"
	vl_check "Dependency-Check NVD-429 evidence excerpt present" "$([ -s "$LE/dependency-check-429-excerpt.log" ] && grep -q '429' "$LE/dependency-check-429-excerpt.log" && echo yes || echo no)" "yes"

	# --- REAL Deptrac 4.6.1 artifacts (Lane E) ---
	vl_check "REAL deptrac clean -> 0 pass" "$(sh "$C/deptrac.sh" --input "$F/deptrac-v025/deptrac-clean.json" 2>/dev/null | jq -r '"\(.status):\(.summary.architecture_violations)"')" "pass:0"
	vl_check "REAL deptrac violations -> 2 fail" "$(sh "$C/deptrac.sh" --input "$F/deptrac-v025/deptrac-violations.json" 2>/dev/null | jq -r '"\(.status):\(.summary.architecture_violations)"')" "fail:2"
	_rc=0; sh "$C/deptrac.sh" --input "$F/deptrac-v025/deptrac-invalid.json" >/dev/null 2>&1 || _rc=$?; vl_check "deptrac invalid -> exit 2" "$_rc" "2"

	# --- Architecture-v025 (Lane F) ---
	vl_check "architecture-v025 clean -> 0" "$(sh "$C/architecture-tests.sh" --input "$F/architecture-v025/clean.json" 2>/dev/null | jq '.summary.architecture_violations')" "0"
	vl_check "architecture-v025 violations -> 3" "$(sh "$C/architecture-tests.sh" --input "$F/architecture-v025/violations.json" 2>/dev/null | jq '.summary.architecture_violations')" "3"
	vl_check "architecture-v025 mixed -> 2" "$(sh "$C/architecture-tests.sh" --input "$F/architecture-v025/mixed.json" 2>/dev/null | jq '.summary.architecture_violations')" "2"

	# --- ZAP-full fix (Lane H): baseline=1 (tool zap), full via --input=2 (tool zap-full), mixed=2 ---
	vl_check "zap-v025 baseline -> zap:1" "$(sh "$C/zap.sh" --input "$F/dast-v025/zap-baseline.json" 2>/dev/null | jq -r '"\(.tool):\(.summary.dast_findings)"')" "zap:1"
	vl_check "zap-v025 FULL via --input -> zap-full:2" "$(sh "$C/zap.sh" --input "$F/dast-v025/zap-full.json" 2>/dev/null | jq -r '"\(.tool):\(.summary.dast_findings)"')" "zap-full:2"
	vl_check "zap-v025 mixed -> 2" "$(sh "$C/zap.sh" --input "$F/dast-v025/zap-mixed.json" 2>/dev/null | jq '.summary.dast_findings')" "2"

	# --- Nuclei template-path guard (Lane I): code-enforced ---
	nuc_guard() { ( . "$ROOT/scripts/runners/dast-guard.sh" >/dev/null 2>&1; eval "$1"; if ss_nuclei_template_check >/dev/null 2>&1; then echo 0; else echo $?; fi ); }
	vl_check "nuclei guard: missing template -> 3" "$(nuc_guard 'SENTINEL_SHIELD_NUCLEI_TEMPLATES=')" "3"
	vl_check "nuclei guard: path traversal -> 3" "$(nuc_guard 'SENTINEL_SHIELD_NUCLEI_TEMPLATES=../etc/passwd')" "3"
	vl_check "nuclei guard: remote denied -> 3" "$(nuc_guard 'SENTINEL_SHIELD_NUCLEI_TEMPLATES=https://evil/t.yaml')" "3"
	vl_check "nuclei guard: remote allowed -> 0" "$(nuc_guard 'SENTINEL_SHIELD_NUCLEI_TEMPLATES=https://x/t.yaml; SENTINEL_SHIELD_NUCLEI_ALLOW_REMOTE=1')" "0"
	vl_check "nuclei guard: existing dir -> 0" "$(nuc_guard "SENTINEL_SHIELD_NUCLEI_TEMPLATES=$ROOT/scripts")" "0"
	# ss_dast_check UNCHANGED (zap unaffected): no-target -> 10, host mismatch -> 3
	dast_rc() { ( . "$ROOT/scripts/runners/dast-guard.sh" >/dev/null 2>&1; eval "$1"; if ss_dast_check >/dev/null 2>&1; then echo 0; else echo $?; fi ); }
	vl_check "ss_dast_check unchanged: no-target -> 10" "$(dast_rc 'unset SENTINEL_SHIELD_DAST_TARGET_URL')" "10"
	vl_check "ss_dast_check unchanged: host mismatch -> 3" "$(dast_rc 'SENTINEL_SHIELD_DAST_TARGET_URL=https://evil/x; SENTINEL_SHIELD_DAST_ALLOWED_HOST=ok')" "3"

	# --- Dependency-Check medium/mixed fixtures (Lane B) ---
	vl_check "dep-check medium fixture -> medium=1" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/medium.json" 2>/dev/null | jq '.summary.medium_vulnerabilities')" "1"
	vl_check "dep-check mixed fixture -> crit+high+med>=3" "$([ "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/mixed.json" 2>/dev/null | jq '[.summary.critical_vulnerabilities,.summary.high_vulnerabilities,.summary.medium_vulnerabilities]|add')" -ge 3 ] && echo yes || echo no)" "yes"

	# --- Regulated-v025 (Lane D) ---
	vl_check "regulated-v025 dast -> dast_findings>=1" "$([ "$(sh "$C/zap.sh" --input "$F/regulated-v025/dast-finding/zap.json" 2>/dev/null | jq '.summary.dast_findings')" -ge 1 ] && echo yes || echo no)" "yes"
	vl_check "regulated-v025 scorecard -> repo_health>=1" "$([ "$(sh "$C/scorecard.sh" --input "$F/regulated-v025/repo-health/scorecard.json" 2>/dev/null | jq '.summary.repository_health_warnings')" -ge 1 ] && echo yes || echo no)" "yes"

	# --- Workflow-sanity additions (Lane L specs) ---
	WT="$ROOT/templates/workflows"
	vl_check "nuclei runner referenced only in DAST template" "$(grep -rl 'runners/nuclei.sh' "$WT" | grep -v 'sentinel-shield-dast.yml' | wc -l | tr -d ' ')" "0"
	vl_check "dependency-check audit NOT in pr-fast" "$(grep -c 'audits/dependency-check.sh' "$WT/sentinel-shield-pr-fast.yml" 2>/dev/null)" "0"
	_noschdispatch=0
	for _wf in "$WT"/*.yml; do grep -qE '^[[:space:]]*schedule:' "$_wf" || continue; grep -qE '^[[:space:]]*workflow_dispatch:' "$_wf" || { _noschdispatch=$((_noschdispatch+1)); }; done
	vl_check "every scheduled template is also workflow_dispatch" "$_noschdispatch" "0"

	rm -rf "$_d"
	if [ "$VL_FAILS" -ne 0 ]; then log_error "v025-live: $VL_FAILS case(s) failed"; return 1; fi
	log_info "v025-live: OK (real Checkov/Grype/Deptrac artifacts, NVD-429 evidence, zap-full fix, nuclei guard, regulated, workflow rules)"
}

# --- v0.1.26: Dependency-Check NVD-key plumbing (leak-safe) + strict consumer evidence ---
V26_FAILS=0
dc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V26_FAILS=$((V26_FAILS + 1)); fi; }

# run_v026_dependency_check — self-test group 'v026-dependency-check' (wired into the dispatch + 'all').
run_v026_dependency_check() {
	log_info "v026: Dependency-Check NVD API-key plumbing (leak-safe) + strict consumer evidence"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; A="$ROOT/scripts/audits/dependency-check.sh"
	_d=$(mktemp -d)

	# (53) REAL NVD-backed artifact (run 2026-06-10, key-authenticated, 5 deps) parses clean.
	dc_check "(53) REAL dependency-check artifact -> pass:0/0/0" \
		"$(sh "$C/dependency-check.sh" --input "$F/live-evidence/dependency-check-real.json" 2>/dev/null | jq -r '"\(.status):\(.summary.critical_vulnerabilities)/\(.summary.high_vulnerabilities)/\(.summary.medium_vulnerabilities)"')" \
		"pass:0/0/0"
	# (53) real-like vulnerabilities still map (regression guard on existing fixtures).
	dc_check "(53) dep-check critical fixture -> critical>=1" \
		"$([ "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/critical.json" 2>/dev/null | jq '.summary.critical_vulnerabilities')" -ge 1 ] && echo yes || echo no)" "yes"

	# Fake dependency-check binary: records argv (minus --out value), writes $SS_T_JSON to --out, exits $SS_T_RC.
	_bin="$_d/bin"; mkdir -p "$_bin"
	cat > "$_bin/dependency-check" <<'STUB'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
	case "$1" in
		--out) out="$2"; shift 2 ;;
		*) printf '%s\n' "$1" >> "$SS_T_ARGS"; shift ;;
	esac
done
[ -n "${SS_T_JSON:-}" ] && printf '%s' "$SS_T_JSON" > "$out"
exit "${SS_T_RC:-0}"
STUB
	chmod +x "$_bin/dependency-check"

	# (51,55) key set + tool exits NON-ZERO with valid JSON -> report PRESERVED; key never logged; key OFF argv.
	SS_T_ARGS="$_d/argv.txt"; : > "$SS_T_ARGS"
	if out=$(PATH="$_bin:$PATH" SS_T_ARGS="$SS_T_ARGS" SS_T_JSON='{"dependencies":[{"vulnerabilities":[{"severity":"HIGH"}]}]}' SS_T_RC=1 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY=FAKEKEY-DEADBEEF \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c1" \
		sh "$A" "$_d/out1.json" 2>&1); then _rc=0; else _rc=$?; fi
	dc_check "(55) non-zero exit + valid JSON -> report preserved" "$([ -s "$_d/out1.json" ] && echo yes || echo no)" "yes"
	dc_check "(55) non-zero exit + valid JSON -> wrapper exit 0" "$_rc" "0"
	dc_check "(51) NVD key NEVER appears in logs" "$(printf '%s' "$out" | grep -c 'FAKEKEY-DEADBEEF')" "0"
	dc_check "(51) 'key redacted' notice present" "$(printf '%s' "$out" | grep -c 'key redacted')" "1"
	dc_check "(51) NVD key NEVER on the command line (argv)" "$(grep -c 'FAKEKEY-DEADBEEF' "$SS_T_ARGS")" "0"
	dc_check "(51) key passed via --propertyfile instead" "$(grep -c -- '--propertyfile' "$SS_T_ARGS")" "1"

	# (55b) tool exits non-zero WITHOUT valid JSON -> discarded, unavailable (NEVER fake-clean).
	if out=$(PATH="$_bin:$PATH" SS_T_ARGS="$_d/argv2.txt" SS_T_JSON='not json' SS_T_RC=1 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c1b" \
		sh "$A" "$_d/out1b.json" 2>&1); then _rc=0; else _rc=$?; fi
	dc_check "(55b) invalid JSON -> NO report (no fake-clean)" "$([ -f "$_d/out1b.json" ] && echo present || echo absent)" "absent"

	# (54) MODE=enabled + NO key + NO binary + NO image -> unavailable, NO report (not fake-clean).
	if out=$(PATH="/usr/bin:/bin" \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE='' \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c2" \
		sh "$A" "$_d/out2.json" 2>&1); then _rc=0; else _rc=$?; fi
	dc_check "(54) no key/binary/image -> unavailable exit 0" "$_rc" "0"
	dc_check "(54) no key/binary/image -> NO fake-clean report" "$([ -f "$_d/out2.json" ] && echo present || echo absent)" "absent"
	dc_check "(54) 'no NVD API key' notice present" "$(printf '%s' "$out" | grep -c 'no NVD API key')" "1"

	# Temp secret dir is always cleaned up (no propertyfile left behind).
	dc_check "secret propertyfile dir cleaned up" "$(find "$_d" -name 'dependency-check.properties' 2>/dev/null | wc -l | tr -d ' ')" "0"

	# (56) strict consumer evidence: baseline PASS / strict FAIL on medium+style (controlled fixture).
	_sd=$(mktemp -d); mkdir -p "$_sd/b" "$_sd/s"
	jq '.summary.medium_vulnerabilities=1 | .summary.style_violations=1' templates/security-summary.example.json > "$_sd/summary.json"
	sh scripts/resolve-gates.sh --mode baseline --output-dir "$_sd/b" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_sd/b/sentinel-shield-gates.env" --summary "$_sd/summary.json" --output-dir "$_sd/b" --format json >/dev/null 2>&1; then _rb=0; else _rb=$?; fi
	dc_check "(56) baseline + medium+style -> PASS" "$_rb" "0"
	sh scripts/resolve-gates.sh --mode strict --output-dir "$_sd/s" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_sd/s/sentinel-shield-gates.env" --summary "$_sd/summary.json" --output-dir "$_sd/s" --format json >/dev/null 2>&1; then _rs=0; else _rs=$?; fi
	dc_check "(56) strict + medium+style -> FAIL" "$_rs" "1"
	dc_check "(56) strict failed_gates = medium+style" "$(jq -rc '[.failed_gates[]]|sort|join(",")' "$_sd/s/sentinel-shield-enforcement.json")" "medium_vulnerabilities,style_violations"
	rm -rf "$_sd"

	# (57) Regulated mode unchanged by v026 (still gates release-evidence).
	mkdir -p "$_d/reg"; sh scripts/resolve-gates.sh --mode regulated --output-dir "$_d/reg" --format env >/dev/null 2>&1
	dc_check "(57) regulated still gates missing_release_evidence" "$(grep -c 'FAIL_ON_MISSING_RELEASE_EVIDENCE=true' "$_d/reg/sentinel-shield-gates.env")" "1"

	# (52) env var documented in the audit script and in docs.
	dc_check "(52) audit script references NVD key env var" "$([ "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	dc_check "(52) docs document NVD key env var" "$(grep -rqs 'SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$ROOT/docs" && echo yes || echo no)" "yes"

	# (58,59) evidence + v1 docs record Dependency-Check status.
	dc_check "(58) live-evidence doc records v0.1.26 Dependency-Check live artifact" "$(grep -qs 'v0.1.26 — Dependency-Check FIRST REAL ARTIFACT' "$ROOT/docs/main-gate-live-evidence.md" && echo yes || echo no)" "yes"
	dc_check "(59) v1-readiness records Dependency-Check" "$(grep -qs 'Dependency-Check' "$ROOT/docs/v1-readiness.md" && echo yes || echo no)" "yes"

	# (60) local agent metadata is never tracked.
	dc_check "(60) no .claude/ tracked in git" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	rm -rf "$_d"
	if [ "$V26_FAILS" -ne 0 ]; then log_error "v026: $V26_FAILS case(s) failed"; return 1; fi
	log_info "v026: OK (real NVD-backed artifact, leak-safe key plumbing, preserve-on-nonzero, no-fake-clean, strict consumer evidence)"
}

# --- v0.1.27: Dependency-Check consumer CVE coverage (npm-vocab fix) + local strict evidence ---
V27_FAILS=0
ce_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V27_FAILS=$((V27_FAILS + 1)); fi; }

# run_v027_consumer_evidence — self-test group 'v027-consumer-evidence' (wired into the dispatch + 'all').
run_v027_consumer_evidence() {
	log_info "v027: Dependency-Check npm-vocab severity mapping + local consumer strict evidence"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; A="$ROOT/scripts/audits/dependency-check.sh"
	_d=$(mktemp -d)

	# (70,71) npm-vocab fixture: DC mixes NVD (HIGH/MEDIUM) + npm (high/moderate). MODERATE -> medium.
	ce_check "(71) npm-vocab fixture -> fail c=1 h=2 m=2" \
		"$(sh "$C/dependency-check.sh" --input "$F/dependency-check/npm-vocab.json" 2>/dev/null | jq -rc '"\(.status) c=\(.tool_report.critical) h=\(.tool_report.high) m=\(.tool_report.medium)"')" \
		"fail c=1 h=2 m=2"
	# (71) single npm "moderate" maps to the medium bucket (the v027 fix).
	printf '%s' '{"dependencies":[{"vulnerabilities":[{"severity":"moderate"}]}]}' > "$_d/mod.json"
	ce_check "(71) lone npm 'moderate' -> medium=1" \
		"$(sh "$C/dependency-check.sh" --input "$_d/mod.json" 2>/dev/null | jq -r '.tool_report.medium')" "1"
	# (71) regression: NVD-vocab fixtures unchanged.
	ce_check "(71) NVD 'medium' fixture still medium=1" \
		"$(sh "$C/dependency-check.sh" --input "$F/dependency-check/medium.json" 2>/dev/null | jq -r '.tool_report.medium')" "1"
	ce_check "(71) critical fixture still critical=1" \
		"$(sh "$C/dependency-check.sh" --input "$F/dependency-check/critical.json" 2>/dev/null | jq -r '.tool_report.critical')" "1"

	# (72) consumer-shaped strict-vs-baseline: high gates baseline+strict; medium adds in strict.
	_sd=$(mktemp -d); mkdir -p "$_sd/b" "$_sd/s"
	jq '.summary.high_vulnerabilities=6 | .summary.medium_vulnerabilities=3' templates/security-summary.example.json > "$_sd/summary.json"
	sh scripts/resolve-gates.sh --mode baseline --output-dir "$_sd/b" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_sd/b/sentinel-shield-gates.env" --summary "$_sd/summary.json" --output-dir "$_sd/b" --format json >/dev/null 2>&1; then _rb=0; else _rb=$?; fi
	ce_check "(72) baseline + 6 high/3 medium -> FAIL" "$_rb" "1"
	ce_check "(72) baseline failed = high only" "$(jq -rc '[.failed_gates[]]|sort|join(",")' "$_sd/b/sentinel-shield-enforcement.json")" "high_vulnerabilities"
	sh scripts/resolve-gates.sh --mode strict --output-dir "$_sd/s" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_sd/s/sentinel-shield-gates.env" --summary "$_sd/summary.json" --output-dir "$_sd/s" --format json >/dev/null 2>&1; then _rs=0; else _rs=$?; fi
	ce_check "(72) strict + 6 high/3 medium -> FAIL" "$_rs" "1"
	ce_check "(72) strict adds medium to failed gates" "$(jq -rc '[.failed_gates[]|select(.=="high_vulnerabilities" or .=="medium_vulnerabilities")]|sort|join(",")' "$_sd/s/sentinel-shield-enforcement.json")" "high_vulnerabilities,medium_vulnerabilities"
	rm -rf "$_sd"

	# (69) NVD key still plumbed safely (propertyfile, env var) — cross-check the audit script.
	ce_check "(69) audit passes key via --propertyfile" "$([ "$(grep -c -- '--propertyfile' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	ce_check "(69) audit reads NVD key env var" "$([ "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$A")" -ge 1 ] && echo yes || echo no)" "yes"

	# (73) v027 evidence docs carry the required sections.
	ce_check "(73) consumer-evidence doc present + cites consumer" "$(grep -qs 'zenchron-tools' "$ROOT/docs/dependency-check-consumer-evidence-v027.md" && grep -qs 'MODERATE' "$ROOT/docs/dependency-check-consumer-evidence-v027.md" && echo yes || echo no)" "yes"
	ce_check "(73) live-evidence doc records v0.1.27 consumer run" "$(grep -qs 'v0.1.27 — Dependency-Check on a DEPENDENCY-RICH consumer' "$ROOT/docs/main-gate-live-evidence.md" && echo yes || echo no)" "yes"

	# (76) digest-override / production pinning guidance present.
	ce_check "(76) digest re-verification doc records v0.1.27 MATCH" "$(grep -qs 'v0.1.27 — digest re-verification' "$ROOT/docs/scanner-image-digest-pinning.md" && echo yes || echo no)" "yes"

	# (74) no local agent metadata tracked.
	ce_check "(74) no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	# (75) no UUID-shaped secret committed in scripts or the v027 evidence doc (key never hardcoded).
	ce_check "(75) no UUID-shaped secret in scripts/" "$( ( cd "$ROOT" && git grep -lIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- scripts/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	ce_check "(75) consumer DC raw artifact NOT tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c 'dependency-check-consumer.json' ) )" "0"

	rm -rf "$_d"
	if [ "$V27_FAILS" -ne 0 ]; then log_error "v027: $V27_FAILS case(s) failed"; return 1; fi
	log_info "v027: OK (npm-vocab MODERATE->medium, consumer strict/baseline, key safety, evidence docs, digest re-verify)"
}

# --- v0.1.28: strict-mode CI evidence + install/sync breadth + digest pinning policy ---
V28_FAILS=0
ci_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V28_FAILS=$((V28_FAILS + 1)); fi; }

# run_v028_strict_ci_and_breadth — self-test group 'v028-strict-ci-and-breadth' (wired into the dispatch + 'all').
run_v028_strict_ci_and_breadth() {
	log_info "v028: strict CI evidence doc + install/sync breadth + digest pinning policy"
	_d=$(mktemp -d)
	_doc="$ROOT/docs/strict-ci-and-install-sync-evidence-v028.md"

	# (66) strict-CI evidence doc carries the required fields (run id, both modes).
	ci_check "(66) strict-CI doc cites the live run ID" "$(grep -qs '27512789768' "$_doc" && echo yes || echo no)" "yes"
	ci_check "(66) strict-CI doc records baseline + strict" "$(grep -qs 'baseline' "$_doc" && grep -qs 'strict' "$_doc" && echo yes || echo no)" "yes"

	# (67) baseline-vs-strict behavior (pure mode default; regression on real-CI-shaped summary).
	mkdir -p "$_d/b" "$_d/s"
	jq '.summary.high_vulnerabilities=6 | .summary.medium_vulnerabilities=4' templates/security-summary.example.json > "$_d/sum.json"
	sh scripts/resolve-gates.sh --mode baseline --profile "$_d/none.yaml" --output-dir "$_d/b" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_d/b/sentinel-shield-gates.env" --summary "$_d/sum.json" --output-dir "$_d/b" --format json >/dev/null 2>&1; then :; fi
	ci_check "(67) baseline failed = high only" "$(jq -rc '[.failed_gates[]]|sort|join(",")' "$_d/b/sentinel-shield-enforcement.json")" "high_vulnerabilities"
	sh scripts/resolve-gates.sh --mode strict --profile "$_d/none.yaml" --output-dir "$_d/s" --format env >/dev/null 2>&1
	if sh scripts/enforce-gates.sh --gates-env "$_d/s/sentinel-shield-gates.env" --summary "$_d/sum.json" --output-dir "$_d/s" --format json >/dev/null 2>&1; then :; fi
	ci_check "(67) strict failed = high + medium" "$(jq -rc '[.failed_gates[]|select(.=="high_vulnerabilities" or .=="medium_vulnerabilities")]|sort|join(",")' "$_d/s/sentinel-shield-enforcement.json")" "high_vulnerabilities,medium_vulnerabilities"

	# (68,69,70) install/sync breadth across all shipped profiles.
	for _prof in laravel-react-docker laravel react node node-react symfony php-library docker; do
		_t=$(mktemp -d)
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" >/dev/null 2>&1
		ci_check "(68) $_prof: dry-run writes nothing" "$(find "$_t" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
		printf 'keep\n' > "$_t/UNMANAGED.txt"
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" --apply --mode report-only >/dev/null 2>&1
		ci_check "(68) $_prof: apply creates managed workflow+profile" "$([ -f "$_t/.sentinel-shield/profile.yaml" ] && [ -f "$_t/.github/workflows/sentinel-shield.yml" ] && echo yes || echo no)" "yes"
		ci_check "(69) $_prof: accepted-risks.json never created" "$([ -f "$_t/.sentinel-shield/accepted-risks.json" ] && echo yes || echo no)" "no"
		printf '{"version":"1.1","risks":[{"id":"KEEP"}]}' > "$_t/.sentinel-shield/accepted-risks.json"
		sh "$ROOT/scripts/install-baseline.sh" --target "$_t" --profile "$_prof" --apply --force >/dev/null 2>&1
		ci_check "(69) $_prof: --force preserves accepted-risks" "$(grep -c KEEP "$_t/.sentinel-shield/accepted-risks.json")" "1"
		printf '\n# DRIFT\n' >> "$_t/.github/workflows/sentinel-shield.yml"
		_det=$(sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" --profile "$_prof" 2>/dev/null | grep -c 'manual-review-needed (managed drift' || true)
		sh "$ROOT/scripts/sync-baseline.sh" --target "$_t" --profile "$_prof" --apply --force >/dev/null 2>&1
		ci_check "(68) $_prof: drift detect->resolve" "$([ "$_det" = "1" ] && [ "$(grep -c DRIFT "$_t/.github/workflows/sentinel-shield.yml")" = "0" ] && echo yes || echo no)" "yes"
		ci_check "(70) $_prof: unmanaged file untouched" "$(cat "$_t/UNMANAGED.txt")" "keep"
		rm -rf "$_t"
	done

	# (71,72) hardened digest-pinned example: pins by @sha256, no production ':latest'.
	_hx="$ROOT/examples/hardened/sentinel-shield-hardened.snippet.yml"
	ci_check "(71) hardened example exists" "$([ -f "$_hx" ] && echo yes || echo no)" "yes"
	ci_check "(71) hardened example pins >=4 images by @sha256" "$([ "$(grep -c '@sha256:' "$_hx")" -ge 4 ] && echo yes || echo no)" "yes"
	ci_check "(72) hardened example has NO ':latest'" "$(grep -c ':latest' "$_hx")" "0"

	# (73) no local agent metadata tracked.
	ci_check "(73) no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	# (74) no UUID-shaped secret literal committed anywhere in scripts/docs/examples.
	ci_check "(74) no UUID-shaped secret in scripts/docs/examples" "$( ( cd "$ROOT" && git grep -lIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- scripts/ docs/ examples/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	rm -rf "$_d"
	if [ "$V28_FAILS" -ne 0 ]; then log_error "v028: $V28_FAILS case(s) failed"; return 1; fi
	log_info "v028: OK (strict CI evidence doc, 8-profile install/sync breadth, digest policy + hardened example, secret hygiene)"
}

# --- v0.1.29: clean strict CI evidence — override precedence + evidence isolation + DC propertyfile ---
V29_FAILS=0
cs_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V29_FAILS=$((V29_FAILS + 1)); fi; }

# run_v029_clean_strict_ci — self-test group 'v029-clean-strict-ci' (wired into the dispatch + 'all').
run_v029_clean_strict_ci() {
	log_info "v029: clean strict CI — override precedence, evidence isolation, DC propertyfile permissions"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; A="$ROOT/scripts/audits/dependency-check.sh"
	_d=$(mktemp -d); mkdir -p "$_d/ov" "$_d/pure"
	jq '.summary.high_vulnerabilities=6 | .summary.medium_vulnerabilities=4' templates/security-summary.example.json > "$_d/sum.json"

	# (56) consumer override precedence: mode:strict + explicit medium:false -> medium gate disabled.
	cat > "$_d/profile-override.yaml" <<'YAML'
project:
  name: evidence-fixture
  type: other
profiles:
  - github-actions
gates:
  mode: strict
  fail_on:
    medium_vulnerabilities: false
YAML
	sh scripts/resolve-gates.sh --profile "$_d/profile-override.yaml" --output-dir "$_d/ov" --format env >/dev/null 2>&1
	cs_check "(56) override mode=strict" "$(grep -c 'SENTINEL_SHIELD_MODE=strict' "$_d/ov/sentinel-shield-gates.env")" "1"
	cs_check "(56) explicit medium override wins (=false)" "$(grep -c 'FAIL_ON_MEDIUM_VULNERABILITIES=false' "$_d/ov/sentinel-shield-gates.env")" "1"
	if sh scripts/enforce-gates.sh --gates-env "$_d/ov/sentinel-shield-gates.env" --summary "$_d/sum.json" --output-dir "$_d/ov" --format json >/dev/null 2>&1; then :; fi
	cs_check "(56) override strict: medium NOT in failed_gates" "$(jq -r '[.failed_gates[]|select(.=="medium_vulnerabilities")]|length' "$_d/ov/sentinel-shield-enforcement.json")" "0"

	# (57) evidence isolation: pure mode-default strict (no consumer profile) -> medium gate fires.
	sh scripts/resolve-gates.sh --mode strict --profile "$_d/none.yaml" --output-dir "$_d/pure" --format env >/dev/null 2>&1
	cs_check "(57) pure strict enables medium gate" "$(grep -c 'FAIL_ON_MEDIUM_VULNERABILITIES=true' "$_d/pure/sentinel-shield-gates.env")" "1"
	if sh scripts/enforce-gates.sh --gates-env "$_d/pure/sentinel-shield-gates.env" --summary "$_d/sum.json" --output-dir "$_d/pure" --format json >/dev/null 2>&1; then :; fi
	# (55) baseline vs strict delta (pure default).
	cs_check "(55) pure strict: high + medium gated" "$(jq -rc '[.failed_gates[]|select(.=="high_vulnerabilities" or .=="medium_vulnerabilities")]|sort|join(",")' "$_d/pure/sentinel-shield-enforcement.json")" "high_vulnerabilities,medium_vulnerabilities"

	# (58) DC valid JSON parsing (real artifact + npm-vocab).
	cs_check "(58) real DC artifact parses pass:0/0/0" "$(sh "$C/dependency-check.sh" --input "$F/live-evidence/dependency-check-real.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.critical_vulnerabilities)/\(.summary.high_vulnerabilities)/\(.summary.medium_vulnerabilities)"')" "pass:0/0/0"
	cs_check "(58) npm-vocab parses c=1 h=2 m=2" "$(sh "$C/dependency-check.sh" --input "$F/dependency-check/npm-vocab.json" 2>/dev/null | jq -rc '"\(.tool_report.critical)/\(.tool_report.high)/\(.tool_report.medium)"')" "1/2/2"

	# (60) DC propertyfile permissions AND key never echoed (no set -x).
	#
	# ASSERTION INVERTED (security audit). This previously required `chmod 644` on the file
	# holding the NVD API key, i.e. it pinned a live credential being made readable by EVERY
	# local user for the duration of a documented "slow, hundreds of MB" NVD download. The
	# v0.2.9 fix it encoded solved a real problem — a container running as a different UID
	# could not read the mount — but by publishing the secret rather than by narrowing the
	# UID gap. The container is now run with `--user "$(id -u):$(id -g)"`, so it reads the
	# mount AS the host user and the file can stay 0600 in a 0700 dir.
	cs_check "(60) NVD key file is NOT world-readable (no chmod 644)" "$([ "$(grep -c 'chmod 644' "$A")" -eq 0 ] && echo yes || echo no)" "yes"
	cs_check "(60) NVD key file is 0600" "$([ "$(grep -c 'chmod 600 "\$PROPDIR' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	cs_check "(60) NVD key dir is 0700" "$([ "$(grep -c 'chmod 700 "\$PROPDIR"' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	cs_check "(60) DC container runs as the host user" "$([ "$(grep -c 'user "\$(id -u):\$(id -g)"' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	cs_check "(60) audit never enables set -x" "$(grep -c 'set -x' "$A")" "0"
	# (59,60) stub run: missing key/binary/image -> NO fake-clean report; with key -> key never in logs.
	_bin="$_d/bin"; mkdir -p "$_bin"
	printf '#!/bin/sh\nout="";while [ $# -gt 0 ];do case "$1" in --out) out="$2";shift 2;; *) shift;; esac;done\nprintf "%%s" "{\\"dependencies\\":[]}" > "$out"\nexit 0\n' > "$_bin/dependency-check"
	chmod +x "$_bin/dependency-check"
	if outk=$(PATH="$_bin:$PATH" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY=FAKEKEY-CAFE SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c" sh "$A" "$_d/o.json" 2>&1); then :; fi
	cs_check "(60) NVD key never appears in logs" "$(printf '%s' "$outk" | grep -c 'FAKEKEY-CAFE')" "0"
	if outn=$(PATH="/usr/bin:/bin" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE='' SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c2" sh "$A" "$_d/o2.json" 2>&1); then :; fi
	cs_check "(59) missing key/binary/image -> NO fake-clean report" "$([ -f "$_d/o2.json" ] && echo present || echo absent)" "absent"

	# (62) v029 evidence doc carries the 3 views + the live run id.
	_doc="$ROOT/docs/clean-strict-ci-evidence-v029.md"
	cs_check "(62) v029 doc cites the live run id" "$(grep -qs '27513388096' "$_doc" && echo yes || echo no)" "yes"
	cs_check "(62) v029 doc records all 3 views" "$(grep -qsi 'strict (evidence)' "$_doc" && grep -qsi 'strict (consumer)' "$_doc" && grep -qsi 'baseline' "$_doc" && echo yes || echo no)" "yes"

	# (61) no local agent metadata tracked.
	cs_check "(61) no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	rm -rf "$_d"
	if [ "$V29_FAILS" -ne 0 ]; then log_error "v029: $V29_FAILS case(s) failed"; return 1; fi
	log_info "v029: OK (override precedence, evidence isolation, DC container-readable propertyfile, no-fake-clean, evidence doc)"
}

# --- v0.1.30: Dependency-Check CI cache reliability (stale-lock cleanup, reset docs, no-fake-clean) ---
V30_FAILS=0
cc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V30_FAILS=$((V30_FAILS + 1)); fi; }

# run_v030_dc_ci_cache — self-test group 'v030-dc-ci-cache' (wired into the dispatch + 'all').
run_v030_dc_ci_cache() {
	log_info "v030: Dependency-Check CI cache reliability — stale-lock cleanup, reset docs, no-fake-clean"
	A="$ROOT/scripts/audits/dependency-check.sh"
	_d=$(mktemp -d); _cache="$_d/cache"; mkdir -p "$_cache"
	# stub DC binary: writes valid JSON to --out, configurable exit.
	_bin="$_d/bin"; mkdir -p "$_bin"
	cat > "$_bin/dependency-check" <<'STUB'
#!/bin/sh
out=""; while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2;; *) printf '%s\n' "$1" >> "${SS_T_ARGS:-/dev/null}"; shift;; esac; done
[ -n "${SS_T_JSON:-}" ] && printf '%s' "$SS_T_JSON" > "$out"
exit "${SS_T_RC:-0}"
STUB
	chmod +x "$_bin/dependency-check"

	# (52) stale H2/update lock cleanup before run; NVD data preserved.
	: > "$_cache/odc.update.lock"; : > "$_cache/odc.mv.db.lock"; : > "$_cache/store.lock"
	printf 'NVDDATA' > "$_cache/odc.mv.db"   # the actual data file must survive
	SS_T_ARGS="$_d/argv.txt"; : > "$SS_T_ARGS"
	PATH="$_bin:$PATH" SS_T_JSON='{"dependencies":[]}' SS_T_RC=0 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_cache" \
		sh "$A" "$_d/o.json" >/dev/null 2>&1 || true
	cc_check "(52) stale *.lock files removed before run" "$(find "$_cache" -name '*.lock' 2>/dev/null | wc -l | tr -d ' ')" "0"
	cc_check "(52) NVD data (odc.mv.db) preserved" "$([ -f "$_cache/odc.mv.db" ] && echo yes || echo no)" "yes"
	cc_check "(52) report produced (stub)" "$([ -s "$_d/o.json" ] && echo yes || echo no)" "yes"

	# (56) key passed via --propertyfile, NOT as a CLI arg.
	: > "$_d/argv2.txt"
	PATH="$_bin:$PATH" SS_T_ARGS="$_d/argv2.txt" SS_T_JSON='{"dependencies":[]}' SS_T_RC=0 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY=FAKEKEY-30 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c2" sh "$A" "$_d/o2.json" >/dev/null 2>&1 || true
	cc_check "(56) NVD key NOT a CLI arg" "$(grep -c 'FAKEKEY-30' "$_d/argv2.txt")" "0"
	cc_check "(56) key passed via --propertyfile" "$(grep -c -- '--propertyfile' "$_d/argv2.txt")" "1"
	# (55) propertyfile dir removed after run.
	cc_check "(55) propertyfile cleaned up after run" "$(find "$_d" -name 'dependency-check.properties' 2>/dev/null | wc -l | tr -d ' ')" "0"
	# (54) propertyfile perms in the script.
	#
	# ASSERTION INVERTED (security audit) — the second copy of the same rule. It required
	# `chmod 644` on the NVD API key file, pinning a live credential as readable by every
	# local user. The container now runs as the host user, so the key stays 0600.
	cc_check "(54) propertyfile is NOT world-readable (no chmod 644)" "$([ "$(grep -c 'chmod 644' "$A")" -eq 0 ] && echo yes || echo no)" "yes"
	cc_check "(54) propertyfile is 0600" "$([ "$(grep -c 'chmod 600 "\$PROPDIR' "$A")" -ge 1 ] && echo yes || echo no)" "yes"

	# (57) valid JSON preserved on NON-ZERO exit.
	PATH="$_bin:$PATH" SS_T_JSON='{"dependencies":[{"vulnerabilities":[{"severity":"HIGH"}]}]}' SS_T_RC=1 \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c3" \
		sh "$A" "$_d/o3.json" >/dev/null 2>&1 || true
	cc_check "(57) non-zero exit + valid JSON -> report preserved" "$([ -s "$_d/o3.json" ] && echo yes || echo no)" "yes"
	# (58) missing key/binary/image -> NO fake-clean report.
	PATH="/usr/bin:/bin" SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE='' \
		SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE="$_d/c4" sh "$A" "$_d/o4.json" >/dev/null 2>&1 || true
	cc_check "(58) no key/binary/image -> NO fake-clean report" "$([ -f "$_d/o4.json" ] && echo present || echo absent)" "absent"

	# (53) cache-reset behavior is documented.
	_cdoc="$ROOT/docs/dependency-check-ci-cache.md"
	cc_check "(53) CI cache doc documents reset input" "$(grep -qs 'reset_dependency_check_cache' "$_cdoc" && echo yes || echo no)" "yes"
	cc_check "(53) script clears stale locks (find -name '*.lock' -delete)" "$([ "$(grep -c "name '\*.lock'" "$A")" -ge 1 ] && echo yes || echo no)" "yes"
	# (rc.1) the shipped Dependency-Check template plumbs the NVD secret (contract coherence).
	cc_check "(rc) shipped DC template plumbs NVD secret" "$(grep -qs 'secrets.SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$ROOT/templates/workflows/sentinel-shield-dependency-check.yml" && echo yes || echo no)" "yes"

	# (59) v030 evidence doc cites the live run id.
	_edoc="$ROOT/docs/dependency-check-ci-evidence-v030.md"
	cc_check "(59) v030 evidence doc cites the live run id" "$(grep -qs '27530386965' "$_edoc" && echo yes || echo no)" "yes"
	# (60) v1 blocker table present + records Dependency-Check.
	cc_check "(60) v1-readiness has the blocker table with Dependency-Check" "$(grep -qs 'OWASP Dependency-Check' "$ROOT/docs/v1-readiness.md" && echo yes || echo no)" "yes"
	# (61) no .claude tracked.
	cc_check "(61) no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	# (62) no UUID-shaped secret literal committed.
	cc_check "(62) no UUID-shaped secret in scripts/docs/examples" "$( ( cd "$ROOT" && git grep -lIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- scripts/ docs/ examples/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	rm -rf "$_d"
	if [ "$V30_FAILS" -ne 0 ]; then log_error "v030: $V30_FAILS case(s) failed"; return 1; fi
	log_info "v030: OK (stale-lock cleanup, NVD data preserved, key off-argv, no-fake-clean, cache-reset docs)"
}

# --- v1.0.0-rc.1 soak: contract-coherence regression guards (exit codes, RC framing, no-final-v1.0) ---
RC_FAILS=0
rc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; RC_FAILS=$((RC_FAILS + 1)); fi; }

# run_v100rc_soak — self-test group 'v100rc-soak' (wired into the dispatch + 'all').
run_v100rc_soak() {
	log_info "rc.1-soak: engine exit-code contract, RC framing, contract links, example-workflow uploads"
	_d=$(mktemp -d)

	# (E) resolve-gates exit-code contract: config/input errors -> exit 2 (STABLE convention), success -> 0.
	if sh scripts/resolve-gates.sh --mode bogus --output-dir "$_d" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi; rc_check "resolve-gates: invalid --mode -> exit 2" "$_rc" "2"
	if sh scripts/resolve-gates.sh --format bogus --output-dir "$_d" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi; rc_check "resolve-gates: invalid --format -> exit 2" "$_rc" "2"
	if sh scripts/resolve-gates.sh --require-profile --profile "$_d/nope.yaml" --output-dir "$_d" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi; rc_check "resolve-gates: missing required profile -> exit 2" "$_rc" "2"
	if sh scripts/resolve-gates.sh --mode strict --profile "$_d/none.yaml" --output-dir "$_d" --format env >/dev/null 2>&1; then _rc=0; else _rc=$?; fi; rc_check "resolve-gates: valid run -> exit 0" "$_rc" "0"
	# all four engine scripts share the exit-2-on-config convention.
	rc_check "enforce-gates uses die_cfg (exit 2)" "$([ "$(grep -c 'die_cfg' scripts/enforce-gates.sh)" -ge 1 ] && echo yes || echo no)" "yes"
	rc_check "resolve-gates uses die_cfg (exit 2)" "$([ "$(grep -c 'die_cfg' scripts/resolve-gates.sh)" -ge 1 ] && echo yes || echo no)" "yes"

	# Release coherence (v1.0.0 final): the release docs consistently mark v1.0.0 as released, the
	# contract documents the v1.0.0 semver promise + migration, and README links the contract docs.
	rc_check "CHANGELOG has a final [1.0.0] entry" "$(grep -qsE '^## \[1\.0\.0\]( |$)' "$ROOT/CHANGELOG.md" && echo yes || echo no)" "yes"
	rc_check "v1-readiness marks v1.0.0 RELEASED" "$(grep -qsiE 'v1\.0\.0[^a-z0-9]{0,4}(released|\(ga\)|general availability)' "$ROOT/docs/v1-readiness.md" && echo yes || echo no)" "yes"
	rc_check "product-contract documents v1.0.0 semver + migration" "$(grep -qs 'migration to .v1.0.0.' "$ROOT/docs/product-contract.md" && grep -qsi 'semver' "$ROOT/docs/product-contract.md" && echo yes || echo no)" "yes"
	rc_check "README references v1.0.0 + the contract docs" "$(grep -qs 'product-contract.md' "$ROOT/README.md" && grep -qs 'v1-readiness.md' "$ROOT/README.md" && echo yes || echo no)" "yes"

	# (G) Dependency-Check is NOT labelled experimental/not-live-validated in CANONICAL strict-mode-readiness.
	rc_check "strict-mode-readiness: DC NOT labelled 'attempted, NOT live-validated'" "$(grep -c 'OWASP Dependency-Check.*attempted, NOT live-validated' "$ROOT/docs/strict-mode-readiness.md")" "0"

	# (F) the laravel-react-docker EXAMPLE workflow: every upload-artifact has if: always() (raw reports survive).
	_xwf="$ROOT/examples/laravel-react-docker/.github/workflows/sentinel-shield.yml"
	_ups=$(grep -c 'uses: actions/upload-artifact' "$_xwf")
	_alwaysabove=$(awk '/uses: actions\/upload-artifact/{ if (prev ~ /if: always\(\)/) c++ } { prev=$0 } END{ print c+0 }' "$_xwf")
	rc_check "example workflow: every upload-artifact has if: always()" "$_alwaysabove" "$_ups"

	rm -rf "$_d"
	if [ "$RC_FAILS" -ne 0 ]; then log_error "rc.1-soak: $RC_FAILS case(s) failed"; return 1; fi
	log_info "rc.1-soak: OK (resolve-gates exit-2 contract, RC framing, contract migration+links, example uploads guarded)"
}

# --- v1.1.0 post-GA: transitive DC knobs (additive, default-off), hardened profile, planning docs ---
PG_FAILS=0
pg_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; PG_FAILS=$((PG_FAILS + 1)); fi; }

# run_v110_postga — self-test group 'v110-postga' (wired into the dispatch + 'all').
run_v110_postga() {
	log_info "v110-postga: transitive DC knobs (default-off), hardened profile, Deptrac/IaC plan, hygiene/migration docs"
	_dct="$ROOT/templates/workflows/sentinel-shield-dependency-check.yml"

	# (Lane A / F) transitive knobs are ADDITIVE and default OFF — v1.0.0 committed-surface behavior preserved.
	pg_check "DC template defines INSTALL_PHP knob" "$([ "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP' "$_dct")" -ge 1 ] && echo yes || echo no)" "yes"
	pg_check "DC template: INSTALL_PHP defaults false" "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP: \"false\"' "$_dct")" "1"
	pg_check "DC template: INSTALL_NODE defaults false" "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_NODE: \"false\"' "$_dct")" "1"
	pg_check "DC template: install steps are gated (if:)" "$([ "$(grep -cE "if:.*INSTALL_PHP == 'true'" "$_dct")" -ge 1 ] && echo yes || echo no)" "yes"
	pg_check "DC template: composer install is continue-on-error (honest fallback)" "$([ "$(grep -c 'continue-on-error: true' "$_dct")" -ge 2 ] && echo yes || echo no)" "yes"
	pg_check "DC template: NVD key still secret-only" "$(grep -c 'secrets.SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$_dct")" "1"
	pg_check "DC template: upload still if: always()" "$(grep -c 'if: always()' "$_dct")" "1"

	# (Lane B) hardened profile: digest-pinned, no floating tag, transitive knobs present.
	_hx="$ROOT/examples/hardened/sentinel-shield-hardened.snippet.yml"
	pg_check "hardened example: >=4 @sha256 image pins" "$([ "$(grep -c '@sha256:' "$_hx")" -ge 4 ] && echo yes || echo no)" "yes"
	pg_check "hardened example: NO floating ':latest'" "$(grep -c ':latest' "$_hx")" "0"
	pg_check "hardened example: transitive knobs documented" "$(grep -c 'SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP' "$_hx")" "1"

	# (Lane C) Deptrac/IaC plan is PLANNING ONLY — no maturity promotion, gate keys documented.
	_plan="$ROOT/docs/deptrac-iac-promotion-plan.md"
	pg_check "deptrac/iac plan exists + is PLANNING ONLY (no promotion)" "$(grep -qs 'PLANNING ONLY' "$_plan" && echo yes || echo no)" "yes"
	pg_check "deptrac/iac plan documents gate keys" "$(grep -qs 'architecture_violations' "$_plan" && grep -qs 'iac_violations' "$_plan" && echo yes || echo no)" "yes"

	# (Lane D/E) onboarding/migration + security-hygiene docs exist with the required content.
	pg_check "v1.1 migration doc: drop-in + 'does NOT mean' section" "$(grep -qs 'drop-in' "$ROOT/docs/v1.1-onboarding-and-migration.md" && grep -qs 'does NOT mean' "$ROOT/docs/v1.1-onboarding-and-migration.md" && echo yes || echo no)" "yes"
	pg_check "security-hygiene doc: NVD rotation + gh secret set" "$(grep -qs 'gh secret set SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' "$ROOT/docs/security-hygiene.md" && echo yes || echo no)" "yes"

	# (Lane F) NO STABLE drift: resolve-gates still honors exit-2 contract (cross-check vs v1.0.0 GA).
	_d=$(mktemp -d)
	if sh scripts/resolve-gates.sh --mode bogus --output-dir "$_d" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	pg_check "STABLE: resolve-gates invalid config still -> exit 2 (no drift)" "$_rc" "2"
	rm -rf "$_d"
	# (Lane E) hygiene: .gitignore covers reports + .sentinel-shield; no .claude tracked.
	pg_check ".gitignore covers reports/ + .sentinel-shield/" "$(grep -qsE '^/?reports/' "$ROOT/.gitignore" && grep -qsE '^\.sentinel-shield/' "$ROOT/.gitignore" && echo yes || echo no)" "yes"
	pg_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	pg_check "no private consumer raw artifact tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c 'dependency-check-consumer.json' ) )" "0"

	if [ "$PG_FAILS" -ne 0 ]; then log_error "v110-postga: $PG_FAILS case(s) failed"; return 1; fi
	log_info "v110-postga: OK (transitive knobs default-off & additive, hardened pins, planning-only promo, hygiene/migration docs)"
}

# --- v1.2.0 docs: required adoption docs exist, hub links resolve, no maturity promotion ---
DV_FAILS=0
dv_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; DV_FAILS=$((DV_FAILS + 1)); fi; }

# run_v120_docs — self-test group 'v120-docs' (wired into the dispatch + 'all').
run_v120_docs() {
	log_info "v120-docs: adoption docs exist, hub links resolve, Deptrac/IaC NOT promoted, README navigable"
	D="$ROOT/docs"

	# (111) the v1.2.0 adoption/support docs all exist.
	for _doc in index quickstart production-rollout enterprise-hardening dependency-check-runbook \
		deptrac-evidence-guide iac-evidence-guide troubleshooting faq; do
		dv_check "doc exists: $_doc.md" "$([ -f "$D/$_doc.md" ] && echo yes || echo no)" "yes"
	done

	# (112) README is navigable: links the hub + the fast-path docs.
	dv_check "README links docs/index.md hub" "$(grep -qs 'docs/index.md' "$ROOT/README.md" && echo yes || echo no)" "yes"
	dv_check "README links quickstart" "$(grep -qs 'docs/quickstart.md' "$ROOT/README.md" && echo yes || echo no)" "yes"

	# (113) every relative .md link in the hub resolves to an existing file (no broken hub links).
	_broken=0
	for _t in $(grep -oE '\]\(([a-z0-9._-]+\.md)\)' "$D/index.md" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' | sort -u); do
		[ -f "$D/$_t" ] || { log_error "FAIL: hub broken link -> $_t"; _broken=$((_broken + 1)); }
	done
	dv_check "docs/index.md: all relative .md links resolve" "$_broken" "0"
	# the hub routes to each new adoption doc.
	dv_check "hub links the new adoption docs" "$(grep -qs 'quickstart.md' "$D/index.md" && grep -qs 'production-rollout.md' "$D/index.md" && grep -qs 'enterprise-hardening.md' "$D/index.md" && grep -qs 'troubleshooting.md' "$D/index.md" && echo yes || echo no)" "yes"

	# (114/115) MATURITY HONESTY: Deptrac/IaC are NOT promoted — evidence guides are PLANNING; the
	# canonical product-status.md still lists Deptrac/IaC as unproven/experimental (not live-validated).
	dv_check "deptrac evidence guide is PLANNING (not a promotion)" "$(grep -qsiE 'PLANNING ONLY|no maturity change' "$D/deptrac-evidence-guide.md" && echo yes || echo no)" "yes"
	dv_check "iac evidence guide is PLANNING (not a promotion)" "$(grep -qsiE 'PLANNING ONLY|no maturity change' "$D/iac-evidence-guide.md" && echo yes || echo no)" "yes"
	dv_check "product-status: IaC (Checkov/Conftest/Terrascan) still unproven" "$(grep -qsiE 'IaC \(Checkov/Conftest/Terrascan\) still unproven|Checkov/Conftest/Terrascan.*(still )?(unproven|experimental)' "$D/product-status.md" && echo yes || echo no)" "yes"
	# the evidence guides must NOT assert Deptrac/IaC are live-validated as a CURRENT state.
	dv_check "deptrac guide does NOT claim Deptrac IS live-validated" "$(grep -cE 'Deptrac is (now )?(live-validated|proven)' "$D/deptrac-evidence-guide.md")" "0"
	dv_check "iac guide does NOT claim IaC IS live-validated" "$(grep -ciE '(checkov|terrascan|conftest|iac) (is|are) (now )?(live-validated|proven)' "$D/iac-evidence-guide.md")" "0"

	# (119/120) hygiene cross-checks (no secret/agent metadata sneaked in via docs).
	dv_check "no NVD key value in any new doc" "$(grep -lIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$D/quickstart.md" "$D/enterprise-hardening.md" "$D/dependency-check-runbook.md" "$D/troubleshooting.md" "$D/faq.md" 2>/dev/null | wc -l | tr -d ' ')" "0"
	dv_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	if [ "$DV_FAILS" -ne 0 ]; then log_error "v120-docs: $DV_FAILS case(s) failed"; return 1; fi
	log_info "v120-docs: OK (adoption docs present, hub links resolve, Deptrac/IaC planning-only, README navigable)"
}

# --- v1.3.0 evidence: Deptrac promoted WITH cited evidence; IaC NOT promoted (mechanical guards) ---
EV_FAILS=0
ev_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; EV_FAILS=$((EV_FAILS + 1)); fi; }

# run_v130_evidence — self-test group 'v130-evidence' (wired into the dispatch + 'all').
run_v130_evidence() {
	log_info "v130-evidence: Deptrac promotion is evidence-backed; IaC NOT promoted; fixtures parse"
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures"; REG="$ROOT/docs/main-gate-live-evidence.md"

	# (B/19) the derived-from-real Deptrac fixtures parse: clean -> 0/pass, violations -> 4/fail.
	ev_check "deptrac fixture clean -> pass arch=0" "$(sh "$C/deptrac.sh" --input "$F/deptrac-v130/clean.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.architecture_violations)"')" "pass:0"
	ev_check "deptrac fixture violations -> fail arch=4" "$(sh "$C/deptrac.sh" --input "$F/deptrac-v130/violations.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.architecture_violations)"')" "fail:4"
	# fixtures carry NO private class/path data (Report block only).
	ev_check "deptrac fixtures: no private file/class details" "$(jq -c '.files' "$F/deptrac-v130/clean.json" "$F/deptrac-v130/violations.json" 2>/dev/null | grep -vc '^{}$')" "0"

	# (79/81) Deptrac promotion is EVIDENCE-BACKED: the registry records the v1.3.0 Deptrac run with the
	# required fields (tool+version, real consumer, collector result, reproducible command, caveat).
	ev_check "registry: Deptrac v1.3.0 promotion section" "$(grep -qs 'Deptrac PROMOTED' "$REG" && echo yes || echo no)" "yes"
	ev_check "registry: Deptrac evidence cites tool version (deptrac 1.0.2)" "$(grep -qs 'Deptrac 1.0.2' "$REG" && echo yes || echo no)" "yes"
	ev_check "registry: Deptrac evidence cites a reproducible command" "$(grep -qs 'vendor/bin/deptrac analyse' "$REG" && echo yes || echo no)" "yes"
	ev_check "registry: Deptrac evidence cites collector result (architecture_violations)" "$(grep -qs 'architecture_violations' "$REG" && echo yes || echo no)" "yes"
	ev_check "product-status: Deptrac is live-validated" "$(grep -qsiE 'Deptrac.*live-validated|Deptrac .experimental. → .live-validated.' "$ROOT/docs/product-status.md" && echo yes || echo no)" "yes"

	# (80) IaC must NOT be claimed live-validated without evidence — the registry documents the BLOCKERS
	# and keeps Checkov/Conftest/Terrascan experimental.
	ev_check "registry: IaC NOT promoted (blockers documented)" "$(grep -qsE 'IaC .*NOT promoted|Checkov / Conftest / Terrascan.*NOT promoted' "$REG" && echo yes || echo no)" "yes"
	ev_check "no doc claims Checkov/Terrascan/Conftest IS live-validated" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/product-status.md docs/enterprise-scanner-matrix.md docs/main-gate-live-evidence.md 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	# (82/83/84) hygiene cross-checks.
	ev_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	ev_check "no private deptrac/checkov/terrascan raw artifact tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE 'reports/raw/(deptrac|checkov|terrascan|conftest)\.json' ) )" "0"

	if [ "$EV_FAILS" -ne 0 ]; then log_error "v130-evidence: $EV_FAILS case(s) failed"; return 1; fi
	log_info "v130-evidence: OK (Deptrac promoted with cited evidence; IaC blockers documented, not promoted)"
}

# --- v1.4.0 IaC: real LOCAL tool-execution evidence; collectors map it; STILL NOT promoted ---
run_v140_iac() {
	log_info "v140-iac: IaC fixtures (real local runs) parse; collectors map; IaC NOT promoted"
	V140_FAILS=0
	v140_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V140_FAILS=$((V140_FAILS + 1)); fi; }
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures/iac-v140"
	EVD="$ROOT/docs/iac-local-evidence-v140.md"; MAT="$ROOT/docs/iac-evidence-candidate-matrix.md"

	# (A02/A05/A04/A06) the derived-from-real IaC artifacts parse through the UNMODIFIED collectors.
	v140_check "checkov fixture -> fail iac=16" "$(sh "$C/checkov.sh" --input "$F/checkov-real-derived.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:16"
	v140_check "terrascan fixture -> fail iac=4" "$(sh "$C/terrascan.sh" --input "$F/terrascan-real.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:4"
	v140_check "conftest plan-JSON fixture -> fail iac=2" "$(sh "$C/conftest.sh" --input "$F/conftest-plan-real.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:2"
	# no-fake-clean: a genuine 0-finding run maps to pass:0 (the v1.3.0 namespace-miss repro).
	v140_check "conftest namespace-miss fixture -> pass iac=0" "$(sh "$C/conftest.sh" --input "$F/conftest-hcl-namespace-miss.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "pass:0"

	# (A07) evidence doc exists and is HONEST: states experimental/unchanged and NOT promoted/consumer-CI.
	v140_check "iac local-evidence doc exists" "$( [ -f "$EVD" ] && echo yes || echo no )" "yes"
	v140_check "candidate matrix doc exists" "$( [ -f "$MAT" ] && echo yes || echo no )" "yes"
	v140_check "evidence doc says maturity UNCHANGED / experimental" "$(grep -qsiE 'remain .experimental.|Maturity status: UNCHANGED' "$EVD" && echo yes || echo no)" "yes"
	v140_check "evidence doc says NOT a consumer-CI promotion" "$(grep -qsiE 'NOT.*(consumer-CI|promotion|promoted)' "$EVD" && echo yes || echo no)" "yes"
	# (80) the global no-overclaim guard still holds WITH the new doc in scope.
	v140_check "no doc claims Checkov/Terrascan/Conftest IS live-validated (incl. v140 doc)" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/product-status.md docs/enterprise-scanner-matrix.md docs/main-gate-live-evidence.md docs/iac-local-evidence-v140.md docs/iac-evidence-candidate-matrix.md 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	# (A17) hygiene: fixtures carry no absolute paths / consumer names / secrets; scratch not tracked.
	v140_check "iac-v140 fixtures: no absolute paths or consumer names" "$( ( cd "$ROOT" && grep -rliE '/Users/|/Volumes/|zenchron|commerce-bridge|octo-cms' tests/fixtures/iac-v140 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	v140_check "no .sprint-v140 scratch tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.sprint-v140/' ) )" "0"
	v140_check "no IaC raw artifact tracked under reports/raw" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE 'reports/raw/(checkov|terrascan|conftest)\.json' ) )" "0"

	if [ "$V140_FAILS" -ne 0 ]; then log_error "v140-iac: $V140_FAILS case(s) failed"; return 1; fi
	log_info "v140-iac: OK (real local IaC evidence; collectors map; experimental unchanged, NOT promoted)"
}

# --- v1.5.0 evidence: Deptrac CONSUMER-CI run ID cited; IaC consumer-CI still NOT promoted ---
run_v150_evidence() {
	log_info "v150-evidence: Deptrac CI run ID cited; v150 fixture maps; IaC consumer-CI NOT promoted"
	V150_FAILS=0
	v150_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V150_FAILS=$((V150_FAILS + 1)); fi; }
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures/deptrac-v150"; REG="$ROOT/docs/main-gate-live-evidence.md"

	# (F) the Report-only CI-derived fixture parses: 4 violations -> fail.
	v150_check "deptrac v150 CI fixture -> fail arch=4" "$(sh "$C/deptrac.sh" --input "$F/silver-potato-ci.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.architecture_violations)"')" "fail:4"
	# fixture carries NO private class/path data (Report block only; files == {}).
	v150_check "deptrac v150 fixture: no .files class/path data" "$(jq -c '.files' "$F/silver-potato-ci.json" 2>/dev/null)" "{}"
	v150_check "deptrac v150 fixture: no absolute/runner paths" "$( ( cd "$ROOT" && grep -rliE '/home/|/Users/|/Volumes/|App\\\\' tests/fixtures/deptrac-v150 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	# (F/G) the registry cites the Deptrac CONSUMER-CI run ID with the required fields.
	v150_check "registry cites Deptrac CI run ID 27633798174" "$(grep -qs '27633798174' "$REG" && echo yes || echo no)" "yes"
	v150_check "registry: Deptrac CI cites deptrac 1.0.2" "$(grep -qs 'deptrac 1.0.2' "$REG" && echo yes || echo no)" "yes"
	v150_check "product-status: Deptrac still live-validated" "$(grep -qsiE 'Deptrac.*live-validated' "$ROOT/docs/product-status.md" && echo yes || echo no)" "yes"

	# (G/I) IaC consumer-CI promotion is BLOCKED — still NO doc claims IaC IS live-validated.
	v150_check "registry: IaC consumer-CI BLOCKED / NOT promoted" "$(grep -qsiE 'IaC consumer-CI promotion BLOCKED|consumer-CI promotion is honestly .?.?blocked|NOT promoted' "$REG" && echo yes || echo no)" "yes"
	v150_check "no doc claims Checkov/Terrascan/Conftest IS live-validated (incl. v150 reg section)" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/product-status.md docs/enterprise-scanner-matrix.md docs/main-gate-live-evidence.md docs/iac-local-evidence-v140.md 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	# (I) hygiene: no consumer raw deptrac artifact (with .files) tracked.
	v150_check "no raw deptrac CI artifact tracked under reports/raw" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE 'reports/raw/deptrac\.json' ) )" "0"

	if [ "$V150_FAILS" -ne 0 ]; then log_error "v150-evidence: $V150_FAILS case(s) failed"; return 1; fi
	log_info "v150-evidence: OK (Deptrac CI run ID cited; IaC consumer-CI blocked, NOT promoted)"
}

# --- v1.6.0: IaC scanners CI-validated on a dedicated evidence consumer; NOT live-validated ---
run_v160_iac() {
	log_info "v160-iac: IaC CI fixtures map; run ID cited; ci-validated tier honest; NOT live-validated"
	V160_FAILS=0
	v160_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V160_FAILS=$((V160_FAILS + 1)); fi; }
	C="$ROOT/scripts/collectors"; F="$ROOT/tests/fixtures/iac-v160"; REG="$ROOT/docs/main-gate-live-evidence.md"
	PS="$ROOT/docs/product-status.md"; DSN="$ROOT/docs/iac-evidence-consumer-design.md"; ADO="$ROOT/docs/enterprise-iac-adoption.md"

	# (C/D/E/F) the real CI artifacts (sanitized) map through the unmodified collectors.
	v160_check "checkov CI fixture -> fail iac=27" "$(sh "$C/checkov.sh" --input "$F/checkov-ci.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:27"
	v160_check "terrascan CI fixture -> fail iac=8" "$(sh "$C/terrascan.sh" --input "$F/terrascan-ci.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:8"
	v160_check "conftest CI fixture -> fail iac=5" "$(sh "$C/conftest.sh" --input "$F/conftest-ci.json" 2>/dev/null | jq -rc '"\(.status):\(.summary.iac_violations)"')" "fail:5"

	# (I) fixtures carry no runner/absolute paths, no account IDs.
	v160_check "iac-v160 JSON fixtures: no runner/abs paths or account IDs" "$( ( cd "$ROOT" && grep -rliE '/home/runner|/Users/|/Volumes/|[0-9]{12}' tests/fixtures/iac-v160/*.json 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	# (G) the registry + product-status cite the CI run ID and define the new tier honestly.
	v160_check "registry cites IaC CI run 27636439883" "$(grep -qs '27636439883' "$REG" && echo yes || echo no)" "yes"
	v160_check "product-status defines ci-validated (evidence-fixture) tier" "$(grep -qs 'ci-validated (evidence-fixture)' "$PS" && echo yes || echo no)" "yes"
	v160_check "design doc + adoption doc exist" "$( [ -f "$DSN" ] && [ -f "$ADO" ] && echo yes || echo no )" "yes"

	# (G/I) honesty: IaC must NOT be claimed live-validated anywhere (the whole point of the new tier).
	v160_check "no doc claims Checkov/Terrascan/Conftest IS live-validated" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/product-status.md docs/enterprise-scanner-matrix.md docs/main-gate-live-evidence.md docs/iac-evidence-consumer-design.md docs/enterprise-iac-adoption.md docs/iac-local-evidence-v140.md 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	# the registry explicitly states the NOT-live-validated boundary.
	v160_check "registry states IaC NOT live-validated boundary" "$(grep -qsiE 'NOT.{0,3}(\`?live-validated|live-validated)' "$REG" && echo yes || echo no)" "yes"

	# (I) evidence-consumer design forbids credentials/deploy (documented safety).
	v160_check "design doc states no credentials / no deploy" "$(grep -qsiE 'No cloud credentials|No deploy' "$DSN" && echo yes || echo no)" "yes"

	if [ "$V160_FAILS" -ne 0 ]; then log_error "v160-iac: $V160_FAILS case(s) failed"; return 1; fi
	log_info "v160-iac: OK (IaC ci-validated on evidence fixture; run ID cited; NOT live-validated)"
}

# --- v1.7.0: evidence platform + adoption docs exist, linked, honest; ci-validated != live-validated ---
run_v170_platform() {
	log_info "v170-platform: platform/adoption/policy docs exist + linked; maturity honest"
	V170_FAILS=0
	v170_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V170_FAILS=$((V170_FAILS + 1)); fi; }
	D="$ROOT/docs"; IDX="$D/index.md"; PS="$D/product-status.md"

	# (A-G) the six new docs exist.
	for f in evidence-platform.md evidence-contribution-guide.md scanner-maturity-policy.md \
	         live-validation-playbook.md public-adoption-kit.md enterprise-buyer-pack.md; do
		v170_check "doc exists: $f" "$( [ -f "$D/$f" ] && echo yes || echo no )" "yes"
		v170_check "doc linked from index: $f" "$(grep -qs "($f)" "$IDX" && echo yes || echo no)" "yes"
	done

	# (D/H) maturity vocabulary: both tiers defined, kept distinct.
	v170_check "product-status defines ci-validated tier" "$(grep -qs 'ci-validated (evidence-fixture)' "$PS" && echo yes || echo no)" "yes"
	v170_check "maturity policy defines live-validated" "$(grep -qs 'live-validated' "$D/scanner-maturity-policy.md" && echo yes || echo no)" "yes"
	v170_check "maturity policy states ci-validated is weaker/distinct" "$(grep -qsiE 'strictly weaker|MUST NOT be conflated|distinct' "$D/scanner-maturity-policy.md" && echo yes || echo no)" "yes"

	# (H) honesty: IaC scanners must NOT be called live-validated anywhere (incl. all new docs).
	v170_check "no doc claims Checkov/Terrascan/Conftest IS live-validated" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	# (H) no-fake-output policy is stated in the contribution guide.
	v170_check "contribution guide states no-fake-output policy" "$(grep -qsiE 'Fabricated|faked-clean|no-fake' "$D/evidence-contribution-guide.md" && echo yes || echo no)" "yes"
	# (I) buyer pack does not overclaim ("all scanners proven").
	v170_check "buyer pack disclaims 'all scanners proven'" "$(grep -qsiE 'NOT .30 scanners all proven|Not .30 scanners' "$D/enterprise-buyer-pack.md" && echo yes || echo no)" "yes"

	# (H/I) hygiene.
	v170_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	v170_check "no private raw artifact tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE '(^reports/|raw-consumer|consumer-artifacts)' ) )" "0"

	if [ "$V170_FAILS" -ne 0 ]; then log_error "v170-platform: $V170_FAILS case(s) failed"; return 1; fi
	log_info "v170-platform: OK (evidence platform + adoption docs present, linked, honest)"
}

# --- v1.8.0: non-IaC completion — tooling exists + works; docs present + linked; nothing overclaimed ---
run_v180_completion() {
	log_info "v180-completion: hardened profile + doctor/support/maturity tooling + docs; no overclaim"
	V180_FAILS=0
	v180_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V180_FAILS=$((V180_FAILS + 1)); fi; }
	D="$ROOT/docs"; S="$ROOT/scripts"; IDX="$D/index.md"; _t=$(mktemp -d "${TMPDIR:-/tmp}/ss-v180.XXXXXX")

	# (A01) hardened profile: manifest valid + opt-in (NOT the install-baseline default) + round-trips.
	v180_check "hardened manifest valid (profile+files)" "$(jq -e 'has("profile") and has("files")' "$ROOT/profiles/hardened-enterprise/profile.manifest.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
	v180_check "hardened profile is opt-in (not the install default)" "$(grep -c 'PROFILE="hardened-enterprise"' "$S/install-baseline.sh")" "0"
	sh "$S/install-baseline.sh" --target "$_t" --profile hardened-enterprise --apply --mode report-only >/dev/null 2>&1
	v180_check "hardened profile installs the pinned snippet" "$([ -f "$_t/.sentinel-shield/hardened/sentinel-shield-hardened.snippet.yml" ] && echo yes || echo no)" "yes"

	# (A02) doctor: exists, exit 0 on a dir, exit 2 on bad arg, never prints a key VALUE.
	v180_check "doctor.sh present" "$([ -f "$S/doctor.sh" ] && echo yes || echo no)" "yes"
	_rc=0; sh "$S/doctor.sh" --target "$ROOT" >/dev/null 2>&1 || _rc=$?; v180_check "doctor exit 0 (info)" "$_rc" "0"
	_rc=0; sh "$S/doctor.sh" --bogus >/dev/null 2>&1 || _rc=$?; v180_check "doctor exit 2 (bad arg)" "$_rc" "2"

	# (A03) support-bundle: excludes raw by default.
	sh "$S/support-bundle.sh" --target "$ROOT" --out "$_t/b.tgz" >/dev/null 2>&1 || true
	v180_check "support-bundle excludes raw by default" "$(tar -tzf "$_t/b.tgz" 2>/dev/null | grep -c 'raw-EXCLUDED.txt')" "1"

	# (A10) maturity report: valid JSON; IaC ci-validated, Deptrac live-validated, AI non-gating.
	v180_check "maturity-report JSON valid" "$(sh "$S/maturity-report.sh" --format json 2>/dev/null | jq -e '.tools|length>0' >/dev/null 2>&1 && echo yes || echo no)" "yes"
	v180_check "maturity-report: Checkov ci-validated (NOT live)" "$(sh "$S/maturity-report.sh" --format json 2>/dev/null | jq -r '.tools[]|select(.tool=="Checkov").maturity')" "ci-validated (evidence-fixture)"
	v180_check "maturity-report: Deptrac live-validated" "$(sh "$S/maturity-report.sh" --format json 2>/dev/null | jq -r '.tools[]|select(.tool=="Deptrac").maturity')" "live-validated"
	v180_check "maturity-report: AI non-gating" "$(sh "$S/maturity-report.sh" --format json 2>/dev/null | jq -r '.tools[]|select(.tool|test("Kuzushi")).gating')" "non-gating"

	# (A04-A09) docs exist + linked from index.
	for f in severity-normalization.md external-adoption-test.md dast-staging-runbook.md \
	         ai-security-review.md consumer-cleanup.md install-sync-ux.md; do
		v180_check "doc exists: $f" "$([ -f "$D/$f" ] && echo yes || echo no)" "yes"
		v180_check "doc linked from index: $f" "$(grep -qs "($f)" "$IDX" && echo yes || echo no)" "yes"
	done

	# (A05) severity: npm MODERATE -> medium documented.
	v180_check "severity doc: npm MODERATE -> medium" "$(grep -qsiE 'MODERATE.*medium' "$D/severity-normalization.md" && echo yes || echo no)" "yes"
	# (A06) DAST stays manual/non-default; (A07) AI non-gating.
	v180_check "dast runbook: manual / non-default" "$(grep -qsiE 'manual|non-default|never.*PR-fast' "$D/dast-staging-runbook.md" && echo yes || echo no)" "yes"
	v180_check "ai doc: non-gating" "$(grep -qsiE 'non-gating' "$D/ai-security-review.md" && echo yes || echo no)" "yes"

	# (A16) roadmap closure sections + deferral of AWS/k8s/IaC live validation.
	v180_check "roadmap: closed-as-complete section" "$(grep -qs 'Closed as complete' "$D/roadmap.md" && echo yes || echo no)" "yes"
	v180_check "roadmap: intentionally-deferred section" "$(grep -qs 'Intentionally deferred' "$D/roadmap.md" && echo yes || echo no)" "yes"
	v180_check "roadmap: AWS/k8s/IaC live validation deferred" "$(grep -qsiE 'AWS live validation|Kubernetes live validation|IaC live validation' "$D/roadmap.md" && echo yes || echo no)" "yes"

	# (A17/A18) honesty + hygiene: no IaC live-validated claim anywhere.
	v180_check "no doc claims Checkov/Terrascan/Conftest IS live-validated" "$( ( cd "$ROOT" && grep -rilE '(checkov|terrascan|conftest) (is|are) (now )?live-validated' docs/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	v180_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	rm -rf "$_t"
	if [ "$V180_FAILS" -ne 0 ]; then log_error "v180-completion: $V180_FAILS case(s) failed"; return 1; fi
	log_info "v180-completion: OK (non-IaC scope closed/deferred; tooling works; IaC stays ci-validated)"
}

# --- v1.9.0: AI-assisted install guide + prompt exist, linked, safe; helper works ---
run_v190_ai_install() {
	log_info "v190-ai-install: AI install guide + prompt present, linked, contain safety clauses"
	V190_FAILS=0
	v190_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V190_FAILS=$((V190_FAILS + 1)); fi; }
	G="$ROOT/docs/ai-assisted-install.md"; P="$ROOT/prompts/install-sentinel-shield.md"; H="$ROOT/scripts/print-ai-install-prompt.sh"

	v190_check "guide exists" "$([ -f "$G" ] && echo yes || echo no)" "yes"
	v190_check "prompt exists" "$([ -f "$P" ] && echo yes || echo no)" "yes"
	v190_check "README links AI-assisted install" "$(grep -qs 'ai-assisted-install.md' "$ROOT/README.md" && echo yes || echo no)" "yes"
	v190_check "docs/index links AI-assisted install" "$(grep -qs 'ai-assisted-install.md' "$ROOT/docs/index.md" && echo yes || echo no)" "yes"

	# guide explicitly says it is NOT blind auto-install.
	v190_check "guide: not blind auto-install" "$(grep -qsiE 'not.{0,6}blind auto-install|does NOT mean blind' "$G" && echo yes || echo no)" "yes"

	# prompt safety clauses.
	v190_check "prompt: do not commit secrets" "$(grep -qsiE 'commit secrets' "$P" && echo yes || echo no)" "yes"
	v190_check "prompt: do not suppress findings" "$(grep -qsiE 'suppress.*findings|not suppress' "$P" && echo yes || echo no)" "yes"
	v190_check "prompt: dry-run" "$(grep -qsi 'dry-run' "$P" && echo yes || echo no)" "yes"
	v190_check "prompt: Final report" "$(grep -qs 'Final report' "$P" && echo yes || echo no)" "yes"
	v190_check "prompt: do not commit .claude" "$(grep -qsi '\.claude' "$P" && echo yes || echo no)" "yes"
	v190_check "prompt: no IaC/AWS/k8s live validation unless requested" "$(grep -qsiE 'AWS / Kubernetes / IaC|AWS/Kubernetes/IaC' "$P" && echo yes || echo no)" "yes"

	# helper works (exit 0, prints), and errors (exit 2) when the prompt is absent.
	_rc=0; sh "$H" >/dev/null 2>&1 || _rc=$?; v190_check "helper prints prompt (exit 0)" "$_rc" "0"
	_hd=$(mktemp -d "${TMPDIR:-/tmp}/ss-h190.XXXXXX"); mkdir -p "$_hd/scripts" "$_hd/prompts"; cp "$H" "$_hd/scripts/"
	_rc=0; sh "$_hd/scripts/print-ai-install-prompt.sh" >/dev/null 2>&1 || _rc=$?; v190_check "helper exit 2 when prompt missing" "$_rc" "2"; rm -rf "$_hd"

	v190_check "no .claude/ tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"

	if [ "$V190_FAILS" -ne 0 ]; then log_error "v190-ai-install: $V190_FAILS case(s) failed"; return 1; fi
	log_info "v190-ai-install: OK (AI install guide + prompt present, linked, safe; helper works)"
}

# --- v2 tool-policy: required/recommended/optional + composition + override + upgrade ---
# Exercises the v2 tool-policy contract (profiles/*/profile.manifest.json `tools`{},
# resolve-tool-plan.sh, resolve-workflow-plan.sh, profile-compose.sh, tool-policy-override,
# bootstrap-profile-tools.sh, plan-upgrade.sh, migrate-v1.sh, installation-metadata) from
# shell + fixtures only — NO live composer/npm/CI. Cases that need a live package manager
# or a real CI run are asserted STRUCTURALLY (static/plan checks) and labelled "[structural]"
# / "[simulated]" in the description. The 30 cases are numbered (N) inline.
V2_FAILS=0
tpv2_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; V2_FAILS=$((V2_FAILS + 1)); fi; }
# tpv2_atleast <desc> <count> — pass when the count is >= 1 (yes/no shape).
tpv2_atleast() { tpv2_check "$1" "$([ "${2:-0}" -ge 1 ] && echo yes || echo no)" "yes"; }

# run_v2_toolpolicy — self-test group 'v2-toolpolicy' (wired into the dispatch + 'all').
run_v2_toolpolicy() {
	log_info "v2-toolpolicy: tool-policy contract (resolve/compose/override/bootstrap/upgrade/migrate)"
	# Direct library calls (CLIs do not cover cr_classify_tool / im_*); include guards make this safe.
	# shellcheck source=scripts/lib/compat-resolver.sh
	. "$ROOT/scripts/lib/compat-resolver.sh"
	# shellcheck source=scripts/lib/installation-metadata.sh
	. "$ROOT/scripts/lib/installation-metadata.sh"
	FX="$ROOT/tests/fixtures/v2"
	LMAN="$ROOT/profiles/laravel/profile.manifest.json"
	SMAN="$ROOT/profiles/symfony/profile.manifest.json"
	WF="$ROOT/templates/workflows/sentinel-shield.yml"

	# An empty target: no executables, no composer.json -> required tools are "missing".
	_empty=$(mktemp -d)
	PLAN=$(sh scripts/resolve-tool-plan.sh --profile laravel --target "$_empty" --format json 2>/dev/null)

	# (1) required missing tool fails: policy=required + missing_behavior=fail, and absent in target.
	tpv2_check "(1) laravel phpstan policy=required"            "$(jq -r '.tools.phpstan.policy' "$LMAN")" "required"
	tpv2_check "(1) laravel phpstan missing_behavior=fail"      "$(jq -r '.tools.phpstan.missing_behavior' "$LMAN")" "fail"
	tpv2_check "(1) phpstan NOT already-installed in empty target" "$(printf '%s' "$PLAN" | jq -r '.tools.phpstan.decision' | grep -c 'already-installed')" "0"

	# (2) recommended missing warns.
	tpv2_check "(2) laravel deptrac policy=recommended"         "$(jq -r '.tools.deptrac.policy' "$LMAN")" "recommended"
	tpv2_check "(2) laravel deptrac missing_behavior=warn"      "$(jq -r '.tools.deptrac.missing_behavior' "$LMAN")" "warn"

	# (3) optional missing passes (info).
	tpv2_check "(3) laravel trufflehog policy=optional"         "$(jq -r '.tools.trufflehog.policy' "$LMAN")" "optional"
	tpv2_check "(3) laravel trufflehog missing_behavior=info"   "$(jq -r '.tools.trufflehog.missing_behavior' "$LMAN")" "info"

	# (4) one-of pest|phpunit OK when EITHER exists: install vendor/bin/pest -> pest already-installed.
	_oneof=$(mktemp -d); mkdir -p "$_oneof/vendor/bin"; printf '#!/bin/sh\n' > "$_oneof/vendor/bin/pest"; chmod +x "$_oneof/vendor/bin/pest"
	_p4=$(sh scripts/resolve-tool-plan.sh --profile laravel --target "$_oneof" --format json 2>/dev/null)
	tpv2_check "(4) one-of satisfied: pest present -> already-installed" "$(printf '%s' "$_p4" | jq -r '.tools.pest.decision')" "already-installed"
	rm -rf "$_oneof"

	# (5) one-of fails when NEITHER exists (empty target: neither pest nor phpunit installed).
	tpv2_check "(5) one-of unmet: pest NOT installed"    "$(printf '%s' "$PLAN" | jq -r '.tools.pest.decision' | grep -c 'already-installed')" "0"
	tpv2_check "(5) one-of unmet: phpunit NOT installed" "$(printf '%s' "$PLAN" | jq -r '.tools.phpunit.decision' | grep -c 'already-installed')" "0"

	# (6) installed tool WITH findings => findings, NOT a runner failure. [structural: runner contract]
	tpv2_atleast "(6) [structural] laravel-phpstan runner keeps exit 0 on findings (JSON is the signal)" \
		"$(grep -cE 'NOT a runner failure|exit stays 0|the JSON is the signal' "$ROOT/scripts/runners/laravel-phpstan.sh")"

	# (7) malformed scanner output => execution-error (collector exits 2, never a fake pass).
	if sh scripts/collectors/eslint.sh --input "$FX/malformed-eslint.json" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(7) malformed scanner output -> collector exit 2 (execution-error)" "$_rc" "2"

	# (8) missing output NEVER => 0/clean: collector reports 'unavailable', exit 0.
	_o8=$(sh scripts/collectors/eslint.sh --input "$_empty/nope.json" 2>/dev/null); _rc8=$?
	tpv2_check "(8) missing scanner output -> exit 0"                      "$_rc8" "0"
	tpv2_check "(8) missing scanner output -> status unavailable (not fake-clean)" "$(printf '%s' "$_o8" | jq -r .status)" "unavailable"

	# (9) config-only resolution does NOT mutate dependencies (resolve-tool-plan is read-only).
	_ro=$(mktemp -d); printf '{"require":{}}' > "$_ro/composer.json"; _cj_before=$(cat "$_ro/composer.json")
	sh scripts/resolve-tool-plan.sh --profile laravel --target "$_ro" --format json >/dev/null 2>&1
	tpv2_check "(9) resolve-tool-plan does not mutate composer.json"  "$(cat "$_ro/composer.json")" "$_cj_before"
	tpv2_check "(9) resolve-tool-plan writes no new files to target"  "$(find "$_ro" -type f ! -name composer.json | wc -l | tr -d ' ')" "0"
	rm -rf "$_ro"

	# (10) require-existing detects missing: empty target has >=1 required tool NOT already-installed.
	tpv2_atleast "(10) require-existing: empty target has required tool(s) NOT already-installed" \
		"$(printf '%s' "$PLAN" | jq -r '[.tools|to_entries[]|select(.value.policy=="required" and .value.decision!="already-installed")]|length')"

	# (11) bootstrap dry-run mutates nothing — seed REPRESENTATIVE existing dependency
	# files and assert they are byte-for-byte unchanged (an empty-target check alone
	# would miss an in-place rewrite of composer.json/lock or package-lock.json).
	_bd=$(mktemp -d)
	printf '{"require":{"acme/app":"^1.0"}}\n'  > "$_bd/composer.json"
	printf '{"packages":[],"content-hash":"seed"}\n' > "$_bd/composer.lock"
	printf '{"name":"app","lockfileVersion":3}\n'    > "$_bd/package-lock.json"
	_bd_before=$(cat "$_bd/composer.json" "$_bd/composer.lock" "$_bd/package-lock.json")
	if sh scripts/bootstrap-profile-tools.sh --profile laravel --target "$_bd" --dry-run >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(11) bootstrap --dry-run exits 0" "$_rc" "0"
	tpv2_check "(11) bootstrap --dry-run leaves existing dep files byte-for-byte unchanged" \
		"$(cat "$_bd/composer.json" "$_bd/composer.lock" "$_bd/package-lock.json")" "$_bd_before"
	tpv2_check "(11) bootstrap --dry-run writes no NEW files" \
		"$(find "$_bd" -type f ! -name composer.json ! -name composer.lock ! -name package-lock.json | wc -l | tr -d ' ')" "0"
	rm -rf "$_bd"

	# (12) bootstrap --apply modifies expected deps. [simulated: no live composer/npm here]
	tpv2_atleast "(12) [simulated] bootstrap --apply runs require/install via run_or_rollback" \
		"$(grep -cE 'run_or_rollback composer|run_or_rollback npm' "$ROOT/scripts/bootstrap-profile-tools.sh")"

	# (13) composer conflict rolls back. Resolver logic: a tool pinning a version that clashes with the
	# app's prod require is classified 'conflict' (NEVER silently applied); rollback path is structural.
	_cf=$(mktemp -d); printf '{"require":{"phpstan/phpstan":"1.0.0"}}' > "$_cf/composer.json"
	tpv2_check "(13) pinned tool vs clashing app prod require -> conflict" \
		"$(cr_classify_tool "$_cf" "$FX/conflict-manifest.json" phpstan | cut -f1)" "conflict"
	tpv2_atleast "(13) [structural] bootstrap restores composer.json/lock on failure" \
		"$(grep -cE 'git checkout .*composer\.(json|lock)|restore.*composer|composer\.lock' "$ROOT/scripts/bootstrap-profile-tools.sh")"

	# (14) framework downgrade rejected (resolver logic): the conflict reason recommends an ISOLATED
	# install instead of altering/downgrading the app's runtime dependency.
	tpv2_atleast "(14) downgrade-risk -> conflict advises isolated install (no downgrade)" \
		"$(cr_classify_tool "$_cf" "$FX/conflict-manifest.json" phpstan | cut -f2- | grep -c 'isolated install')"
	rm -rf "$_cf"

	# (17) composition precedence (canonical resolver, strongest-policy): a child that `extends` a
	# base inherits the base's tools, and a child can NEVER WEAKEN a required parent tool by
	# redeclaring it (Blocker 1: "must not downgrade a required parent tool merely by redeclaring it
	# as optional"). compose-child extends `node` (typescript=required) and redeclares typescript as
	# `optional`; the effective policy MUST stay `required`. resolve-workflow-plan --manifest now
	# delegates to the ONE canonical resolver (Significant fix 11), so this is the unified behavior.
	_comp=$(sh scripts/resolve-workflow-plan.sh --manifest "$FX/compose-child.manifest.json" --stage pr 2>/dev/null)
	tpv2_check "(17) composition: child CANNOT downgrade a required parent tool (typescript stays required)" \
		"$(printf '%s' "$_comp" | jq -r '.tools[]|select(.tool=="typescript").policy')" "required"
	tpv2_check "(17) composition: base tool inherited unchanged (eslint stays required)" \
		"$(printf '%s' "$_comp" | jq -r '.tools[]|select(.tool=="eslint").policy')" "required"

	# (18) JS-only does NOT require TypeScript: the typescript runner is fail-open (no tsc -> exit 0,
	# no fabricated report). [structural: depends on absence of npx, asserted via the runner contract]
	tpv2_atleast "(18) [structural] typescript runner fail-open when tsc absent (exit 0, no fake report)" \
		"$(grep -cE 'tsc not available|does NOT fake' "$ROOT/scripts/runners/typescript.sh")"

	# (19) TS project requires typecheck: node + react profiles wire the typescript runner + report.
	tpv2_check "(19) node profile wires typescript runner"  "$(jq -r '.tools.typescript.runner' "$ROOT/profiles/node/profile.manifest.json")"  "scripts/runners/typescript.sh"
	tpv2_check "(19) react profile wires typescript runner" "$(jq -r '.tools.typescript.runner' "$ROOT/profiles/react/profile.manifest.json")" "scripts/runners/typescript.sh"

	# (20) laravel requires larastan (manifest assertion).
	tpv2_check "(20) laravel requires larastan" "$(jq -r '.tools.larastan.policy' "$LMAN")" "required"

	# (21) symfony requires phpstan-symfony (manifest assertion).
	tpv2_check "(21) symfony requires phpstan-symfony"           "$(jq -r '.tools["phpstan-symfony"].policy' "$SMAN")" "required"
	tpv2_check "(21) symfony declares phpstan/phpstan-symfony package" "$(jq -r '[.tools["phpstan-symfony"].packages[].name]|index("phpstan/phpstan-symfony")!=null' "$SMAN")" "true"

	# (22) deptrac isolated mode: a deptrac version clash is classified 'conflict' -> isolated install.
	_di=$(mktemp -d); printf '{"require":{"qossmic/deptrac-shim":"0.9.0"}}' > "$_di/composer.json"
	tpv2_check "(22) deptrac version clash -> conflict (isolated mode, not in-app)" \
		"$(cr_classify_tool "$_di" "$FX/conflict-manifest.json" deptrac | cut -f1)" "conflict"
	rm -rf "$_di"

	# (23) the workflow runs every REQUIRED tool. Two checks: (a) the resolve-workflow-plan PLAN — the
	# machine contract for "what CI must run" — lists every required tool per stage; (b) every required
	# runner-bearing tool's runner path is referenced in the canonical workflow template.
	_prplan=$(sh scripts/resolve-workflow-plan.sh --profile laravel --stage pr 2>/dev/null)
	_mainplan=$(sh scripts/resolve-workflow-plan.sh --profile laravel --stage main 2>/dev/null)
	_miss=0
	for _k in $(jq -r '.tools|to_entries[]|select(.value.policy=="required" and .value.execution.pr==true)|.key' "$LMAN"); do
		printf '%s' "$_prplan" | jq -e --arg k "$_k" '.tools[]|select(.tool==$k)' >/dev/null 2>&1 || _miss=$((_miss + 1))
	done
	tpv2_check "(23) every required PR tool appears in the PR workflow plan" "$_miss" "0"
	_miss=0
	for _k in $(jq -r '.tools|to_entries[]|select(.value.policy=="required" and .value.execution.main==true)|.key' "$LMAN"); do
		printf '%s' "$_mainplan" | jq -e --arg k "$_k" '.tools[]|select(.tool==$k)' >/dev/null 2>&1 || _miss=$((_miss + 1))
	done
	tpv2_check "(23) every required main-gate tool appears in the main workflow plan" "$_miss" "0"
	_miss=0
	for _r in $(jq -r '.tools|to_entries[]|select(.value.policy=="required" and (.value.runner//"")!="")|.value.runner' "$LMAN" | sort -u); do
		grep -q "$_r" "$WF" || { log_warn "required runner not wired in canonical template: $_r"; _miss=$((_miss + 1)); }
	done
	tpv2_check "(23) every required runner-bearing tool is wired in the canonical workflow template" "$_miss" "0"

	# (24) workflow actions SHA-pinned: every `uses:` in the canonical template is pinned to a 40-hex SHA
	# (local `./` composite actions exempt). NOTE: the split per-stage templates intentionally show
	# `@v4` tags with a "pin to a SHA before production" caveat, so only the canonical template is the
	# pin contract here (see limitations).
	tpv2_check "(24) canonical workflow template: all 'uses:' SHA-pinned (40-hex)" \
		"$(grep -hE '^[[:space:]]*uses:[[:space:]]' "$WF" | grep -vE 'uses:[[:space:]]*\./' | grep -cvE '@[0-9a-fA-F]{40}')" "0"

	# (25) update planner makes NO changes: seed representative dependency files and
	# assert plan-upgrade leaves them byte-for-byte unchanged AND writes no new files
	# (only its optional --output report, which we do not pass here).
	_pu=$(mktemp -d)
	printf '{"require":{"acme/app":"^1.0"}}\n'  > "$_pu/composer.json"
	printf '{"packages":[],"content-hash":"seed"}\n' > "$_pu/composer.lock"
	printf '{"name":"app","lockfileVersion":3}\n'    > "$_pu/package-lock.json"
	_pu_before=$(cat "$_pu/composer.json" "$_pu/composer.lock" "$_pu/package-lock.json")
	if sh scripts/plan-upgrade.sh --from 1.9.0 --to 2.0.0 --profile laravel --target "$_pu" --format json >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(25) plan-upgrade exit 0"                    "$_rc" "0"
	tpv2_check "(25) plan-upgrade leaves existing dep files byte-for-byte unchanged" \
		"$(cat "$_pu/composer.json" "$_pu/composer.lock" "$_pu/package-lock.json")" "$_pu_before"
	tpv2_check "(25) plan-upgrade writes no NEW files to target" \
		"$(find "$_pu" -type f ! -name composer.json ! -name composer.lock ! -name package-lock.json | wc -l | tr -d ' ')" "0"
	tpv2_atleast "(25) [structural] plan-upgrade documents READ-ONLY (writes only --output)" \
		"$(grep -cE 'READ-ONLY|MUTATES NOTHING|Writes nothing except' "$ROOT/scripts/plan-upgrade.sh")"
	rm -rf "$_pu"

	# (26) AI update prompt exists + contains the required safety clauses (the 17 numbered upgrade steps
	# plus the hard-stop non-negotiables).
	_PRM="$ROOT/prompts/update-sentinel-shield.md"
	tpv2_check "(26) update prompt exists" "$([ -f "$_PRM" ] && echo yes || echo no)" "yes"
	_mn=0
	for _n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
		grep -qE "\*\*$_n\." "$_PRM" || { log_warn "update prompt missing numbered step $_n"; _mn=$((_mn + 1)); }
	done
	tpv2_check "(26) update prompt contains all 17 numbered upgrade clauses" "$_mn" "0"
	tpv2_atleast "(26) clause: never fake a clean gate"            "$(grep -ciE 'never fake a clean gate|fake a clean' "$_PRM")"
	tpv2_atleast "(26) clause: never downgrade framework/packages" "$(grep -ciE 'never downgrade|do.*not.*downgrade' "$_PRM")"
	tpv2_atleast "(26) clause: dry-run before apply"               "$(grep -ciE 'dry-run' "$_PRM")"
	tpv2_atleast "(26) clause: roll back on breakage"              "$(grep -ciE 'roll back|rollback' "$_PRM")"
	tpv2_atleast "(26) clause: do not commit secrets/.claude"      "$(grep -ciE 'commit secrets|\.claude' "$_PRM")"
	tpv2_atleast "(26) clause: never convert execution-error to clean" "$(grep -ciE 'execution-error|unavailable' "$_PRM")"

	# (27) installation metadata round-trips through im_write -> im_validate -> im_get*.
	_im=$(mktemp -d)
	im_write "$_im" "2.0.0" "laravel" "2" "require-existing" "2026-06-27T12:00:00Z" \
		"$(printf '.github/workflows/sentinel-shield.yml')" "$(printf '.sentinel-shield/accepted-risks.json')" \
		"$(printf 'phpstan\npest')" "trufflehog" >/dev/null 2>&1
	tpv2_check "(27) installation.json conforms to schema (im_validate)" "$(im_validate "$(im_path "$_im")" >/dev/null 2>&1 && echo yes || echo no)" "yes"
	tpv2_check "(27) round-trips version"        "$(im_get_version "$_im")"        "2.0.0"
	tpv2_check "(27) round-trips profile"        "$(im_get_profile "$_im")"        "laravel"
	tpv2_check "(27) round-trips profile_schema" "$(im_get_profile_schema "$_im")" "2"
	tpv2_check "(27) round-trips enabled_tools"  "$(im_list_enabled_tools "$_im" | sort | tr '\n' ',' )" "pest,phpstan,"
	rm -rf "$_im"

	# (28) v1 migration preserves local files (and (15) project configs, (16) accepted-risks unchanged).
	_v1=$(mktemp -d); mkdir -p "$_v1/.sentinel-shield"
	printf 'profiles:\n  - laravel\n' > "$_v1/.sentinel-shield/profile.yaml"
	printf '{"version":"1.1","risks":[{"id":"keep-me"}]}' > "$_v1/.sentinel-shield/accepted-risks.json"
	printf 'deptrac:\n  paths: [src]\n' > "$_v1/deptrac.yaml"
	_ar_before=$(cat "$_v1/.sentinel-shield/accepted-risks.json")
	_dt_before=$(cat "$_v1/deptrac.yaml")
	sh scripts/migrate-v1.sh --target "$_v1" --profile laravel --apply >/dev/null 2>&1 || true
	tpv2_check "(16) migrate-v1 leaves accepted-risks.json unchanged"     "$(cat "$_v1/.sentinel-shield/accepted-risks.json")" "$_ar_before"
	tpv2_check "(15) migrate-v1 leaves project config (deptrac.yaml) unchanged" "$(cat "$_v1/deptrac.yaml")" "$_dt_before"
	tpv2_check "(28) migrate-v1 creates installation.json"                "$([ -f "$_v1/.sentinel-shield/installation.json" ] && echo yes || echo no)" "yes"
	tpv2_check "(28) migrated installation.json conforms to schema"       "$(im_validate "$_v1/.sentinel-shield/installation.json" >/dev/null 2>&1 && echo yes || echo no)" "yes"
	rm -rf "$_v1"

	# (29) tool-policy override schema validation.
	_TPO="$ROOT/scripts/lib/tool-policy-override.sh"
	if sh "$_TPO" validate "$FX/override-valid.yaml" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(29) valid override accepted (exit 0)" "$_rc" "0"
	if sh "$_TPO" validate "$FX/override-bare-scalar.yaml" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(29) bare-scalar override rejected (exit 3)" "$_rc" "3"
	if sh "$_TPO" validate "$FX/override-bad-policy.yaml" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(29) out-of-enum policy rejected (exit 3)" "$_rc" "3"
	# override cannot disable a non-suppressible secrets control without a documented record (exit 2).
	_sd=$(mktemp -d); printf '{"gitleaks":{"policy":"required","category":"secrets"}}' > "$_sd/composed.json"
	printf 'tools:\n  gitleaks:\n    policy: disabled\n' > "$_sd/dis.yaml"
	if SENTINEL_SHIELD_DOCUMENTED_DISABLE_RECORD="" sh "$_TPO" apply "$_sd/composed.json" "$_sd/dis.yaml" >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpv2_check "(29) cannot disable non-suppressible secrets control w/o record (exit 2)" "$_rc" "2"
	rm -rf "$_sd"

	# (30) no secret / private artifact leakage among git-tracked files.
	tpv2_check "(30) no .claude/ tracked"          "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -c '^\.claude/' ) )" "0"
	tpv2_check "(30) no reports/raw artifact tracked" "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE '^reports/raw/' ) )" "0"
	tpv2_check "(30) no .env tracked"              "$( ( cd "$ROOT" && git ls-files 2>/dev/null | grep -cE '(^|/)\.env$' ) )" "0"
	tpv2_check "(30) no UUID-shaped secret in tracked scripts/profiles/schemas/prompts" \
		"$( ( cd "$ROOT" && git grep -lIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- scripts/ profiles/ schemas/ prompts/ 2>/dev/null | wc -l | tr -d ' ' ) )" "0"
	tpv2_check "(30) v2 fixtures carry no absolute paths / consumer names" \
		"$( ( cd "$ROOT" && grep -rliE '/Users/|/home/|/Volumes/|zenchron' tests/fixtures/v2 2>/dev/null | wc -l | tr -d ' ' ) )" "0"

	rm -rf "$_empty"
	if [ "$V2_FAILS" -ne 0 ]; then log_error "v2-toolpolicy: $V2_FAILS case(s) failed"; return 1; fi
	log_info "v2-toolpolicy: OK (required/recommended/optional + one-of + composition + override + upgrade/migrate)"
}

# --- v2-enforcement: full v2 policy->gate matrix ----------------------------
# A faithful matrix over the REAL v2 scripts (canonical resolver, run-tool-plan,
# build-security-summary --profile, enforce-gates, bootstrap, compat-resolver). Each
# case drives an actual CLI/lib and asserts the contracted outcome. Items that cannot
# be exercised live this session (real composer/npm installs) are marked [structural]
# or [simulated] in their description. The end-to-end policy->gate path is proven by
# the companion LOCAL harness (scripts/e2e-harness.sh, `self-test.sh e2e`).
TPE_FAILS=0
tpe_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; TPE_FAILS=$((TPE_FAILS + 1)); fi; }
tpe_atleast() { tpe_check "$1" "$([ "${2:-0}" -ge 1 ] && echo yes || echo no)" "yes"; }
tpe_contains() { case "$2" in *"$3"*) tpe_check "$1" "yes" "yes" ;; *) tpe_check "$1" "no($2)" "yes" ;; esac; }

# Normalized (tool-key:policy) projection (required+recommended) per subsystem shape.
TPE_PROJ_KEYS='[.tools|to_entries[]|select(.value.policy=="required" or .value.policy=="recommended")|{(.key):.value.policy}]|add'
TPE_PROJ_WF='[.stages|to_entries[].value[]|select(.policy=="required" or .policy=="recommended")|{(.tool):.policy}]|add'
TPE_PROJ_SS='[.tools|to_entries[]|select(.value|type=="object" and has("policy"))|select(.value.policy=="required" or .value.policy=="recommended")|{(.value.tool):.value.policy}]|add'

# --- composition (canonical resolver + planner) ------------------------------
v2e_composition() {
	FX="$ROOT/tests/fixtures/v2"
	RES="$ROOT/scripts/resolve-effective-profile.sh"

	# base+child required precedence: a combination profile that `extends` multiple
	# bases inherits each base's REQUIRED tools (strongest-policy composition). Real.
	_lrd=$(sh "$RES" --profile laravel-react-docker --format json 2>/dev/null || true)
	tpe_check "composition: combination inherits larastan=required (from laravel base)" \
		"$(printf '%s' "$_lrd" | jq -r '.tools.larastan.policy')" "required"
	tpe_check "composition: combination inherits typescript=required (from node base)" \
		"$(printf '%s' "$_lrd" | jq -r '.tools.typescript.policy')" "required"
	tpe_check "composition: combination inherits eslint=required (from node base)" \
		"$(printf '%s' "$_lrd" | jq -r '.tools.eslint.policy')" "required"

	# unknown parent => exit 2 AND no effective profile on stdout. Real (fixture).
	_rc=0; _out=$(EP_REPO_ROOT="$FX" sh "$RES" --profile orphan-child --format json 2>/dev/null) || _rc=$?
	tpe_check "composition: unknown parent -> exit 2" "$_rc" "2"
	tpe_check "composition: unknown parent -> no stdout" "$([ -z "$_out" ] && echo empty || echo nonempty)" "empty"

	# inheritance cycle => exit 2 AND the cycle path is reported. Real (fixtures).
	_rc=0; _err=$(EP_REPO_ROOT="$FX" sh "$RES" --profile cycle-a --format json 2>&1 >/dev/null) || _rc=$?
	tpe_check "composition: inheritance cycle -> exit 2" "$_rc" "2"
	tpe_contains "composition: inheritance cycle reports the path (cycle-a -> cycle-b -> cycle-a)" "$_err" "cycle-a -> cycle-b -> cycle-a"

	# override application: a project override RAISES deptrac recommended -> required. Real.
	tpe_check "composition: base deptrac policy is recommended" \
		"$(sh "$RES" --profile laravel --format json 2>/dev/null | jq -r '.tools.deptrac.policy')" "recommended"
	tpe_check "composition: override raises deptrac -> required" \
		"$(sh "$RES" --profile laravel --override "$FX/override-raise-deptrac.json" --format json 2>/dev/null | jq -r '.tools.deptrac.policy')" "required"

	# required-disable rejection: an override that disables a NON-SUPPRESSIBLE control
	# (gitleaks) is fail-closed (exit 2) with a clear message. Real.
	_rc=0; _err=$(sh "$RES" --profile laravel --override "$FX/override-disable-gitleaks.json" --format json 2>&1 >/dev/null) || _rc=$?
	tpe_check "composition: override disabling gitleaks -> exit 2" "$_rc" "2"
	tpe_contains "composition: gitleaks disable rejected as non-suppressible" "$_err" "non-suppressible"

	# Child that BOTH `extends` a base AND declares its own tools, resolved through the ONE canonical
	# resolver (resolve-workflow-plan --manifest now delegates to it — Significant fix 11). A child
	# CANNOT weaken a required parent tool: compose-child redeclares node's required typescript as
	# optional, and the effective policy stays required (strongest-policy precedence, no downgrade).
	_comp=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --manifest "$FX/compose-child.manifest.json" --stage pr 2>/dev/null || true)
	tpe_check "composition: child cannot downgrade a required parent tool (typescript stays required)" \
		"$(printf '%s' "$_comp" | jq -r '.tools[]|select(.tool=="typescript").policy')" "required"
	tpe_check "composition: inherited base tool unchanged (eslint stays required) [resolver]" \
		"$(printf '%s' "$_comp" | jq -r '.tools[]|select(.tool=="eslint").policy')" "required"
}

# --- combination-profile consistency (Blocker 4 / Fix 11) --------------------
# The SAME normalized (tool-key:policy) set must be seen by every v2 subsystem, since
# they ALL consume the one canonical resolver. We compute the required+recommended
# projection from each subsystem's own output and assert byte-identical canonical JSON
# (an equivalent, more-portable form of "hash the normalized set and assert equal").
v2e_consistency() {
	_t=$(mktemp -d); mkdir -p "$_t/vendor/bin" "$_t/reports/raw"
	printf '{}' > "$_t/composer.json"
	printf '#!/bin/sh\n' > "$_t/vendor/bin/pest"; chmod +x "$_t/vendor/bin/pest"
	for _r in actionlint codeql composer-audit dependency-check gitleaks grype larastan \
		osv-scanner php-syntax phpstan pint semgrep syft trivy-fs zizmor tests deptrac psalm rector; do
		printf '{}' > "$_t/reports/raw/$_r.json"
	done

	_eff=$(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile laravel --target "$_t" --format json 2>/dev/null || true)
	_tp=$(sh "$ROOT/scripts/resolve-tool-plan.sh" --profile laravel --target "$_t" --format json 2>/dev/null || true)
	_wp=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile laravel --stage all 2>/dev/null || true)
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_t/reports/raw" --output "$_t/ss.json" \
		--profile laravel --target "$_t" >/dev/null 2>&1 || true

	_h_eff=$(printf '%s' "$_eff" | jq -S -c "$TPE_PROJ_KEYS" 2>/dev/null || echo NA1)
	_h_tp=$(printf '%s' "$_tp" | jq -S -c "$TPE_PROJ_KEYS" 2>/dev/null || echo NA2)
	_h_wp=$(printf '%s' "$_wp" | jq -S -c "$TPE_PROJ_WF" 2>/dev/null || echo NA3)
	_h_ss=$(jq -S -c "$TPE_PROJ_SS" "$_t/ss.json" 2>/dev/null || echo NA4)
	tpe_check "consistency[laravel]: resolve-tool-plan set == resolver set" "$_h_tp" "$_h_eff"
	tpe_check "consistency[laravel]: resolve-workflow-plan set == resolver set" "$_h_wp" "$_h_eff"
	tpe_check "consistency[laravel]: build-security-summary set == resolver set" "$_h_ss" "$_h_eff"

	# combination profile, across the three pure resolvers (no target/reports needed).
	_ce=$(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile laravel-react-docker --format json 2>/dev/null || true)
	_ct=$(sh "$ROOT/scripts/resolve-tool-plan.sh" --profile laravel-react-docker --format json 2>/dev/null || true)
	_cw=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile laravel-react-docker --stage all 2>/dev/null || true)
	_hce=$(printf '%s' "$_ce" | jq -S -c "$TPE_PROJ_KEYS" 2>/dev/null || echo NA5)
	_hct=$(printf '%s' "$_ct" | jq -S -c "$TPE_PROJ_KEYS" 2>/dev/null || echo NA6)
	_hcw=$(printf '%s' "$_cw" | jq -S -c "$TPE_PROJ_WF" 2>/dev/null || echo NA7)
	tpe_check "consistency[combination]: resolve-tool-plan set == resolver set" "$_hct" "$_hce"
	tpe_check "consistency[combination]: resolve-workflow-plan set == resolver set" "$_hcw" "$_hce"

	# doctor + maturity emit tables/partial JSON, not a full policy set; assert they
	# CONSUME the one canonical resolver (no private composition). [structural]
	tpe_atleast "consistency: doctor delegates to resolve-effective-profile" \
		"$(grep -c 'resolve-effective-profile' "$ROOT/scripts/doctor.sh")"
	tpe_atleast "consistency: maturity-report delegates to resolve-effective-profile" \
		"$(grep -c 'resolve-effective-profile' "$ROOT/scripts/maturity-report.sh")"

	rm -rf "$_t"
}

# --- tool states / gate (crafted summaries -> enforce-gates) -----------------
v2e_make_summary() { # <out> <tools-json> <oneof-json>
	jq -n --argjson tools "$2" --argjson oneof "$3" '
		{ version:"1.0", generated_at:"2026-01-01T00:00:00Z",
		  project:{name:"t",type:"laravel",criticality:"high"},
		  source:{commit:"c",branch:"b",workflow:"w"},
		  summary:{ secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
			medium_vulnerabilities:0, architecture_violations:0, type_errors:0,
			test_failures:0, unsafe_docker:0, unsafe_github_actions:0, expired_exceptions:0,
			missing_sbom:false, missing_release_evidence:false,
			required_tool_failures:0, tool_configuration_failures:0, tool_execution_failures:0 },
		  tools:$tools, one_of_groups:$oneof,
		  exceptions:{active:0,expired:0},
		  evidence:{ sbom:{present:true,path:"x"}, release_evidence:{present:true,path:"y"} } }' > "$1"
}
v2e_tool() { # <emit> <tool> <policy> <status> <gate_enforced-bool>
	jq -n --arg e "$1" --arg t "$2" --arg p "$3" --arg s "$4" --argjson ge "$5" \
		'{($e):{tool:$t,policy:$p,status:$s,gate_enforced:$ge}}'
}
# v2e_states — v2-enforcement sub-suite: states.
v2e_states() {
	_d=$(mktemp -d)
	# A clean baseline gates env (no finding gate trips; all crafted counts are 0).
	sh "$ROOT/scripts/resolve-gates.sh" --profile "$ROOT/templates/profile.yaml" --mode baseline \
		--output-dir "$_d" --format env >/dev/null 2>&1 || true
	_genv="$_d/sentinel-shield-gates.env"

	_gate() { # <desc> <tools-json> <oneof-json> <expected-exit>
		v2e_make_summary "$_d/ss.json" "$2" "$3"
		_rc=0
		sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/ss.json" \
			--output-dir "$_d" --format json >/dev/null 2>&1 || _rc=$?
		tpe_check "$1" "$_rc" "$4"
		printf '%s' "$_rc"
	}

	_gate "gate: required+pass -> exit 0"          "$(v2e_tool phpstan phpstan required pass true)"            '{}' 0 >/dev/null
	_gate "gate: required+findings -> exit 0 (count gates decide)" "$(v2e_tool phpstan phpstan required findings true)" '{}' 0 >/dev/null
	_gate "gate: required+unavailable -> exit 1"   "$(v2e_tool larastan larastan required unavailable true)"   '{}' 1 >/dev/null
	_gate "gate: required+not-configured -> exit 1" "$(v2e_tool pint pint required not-configured true)"        '{}' 1 >/dev/null
	_gate "gate: required+execution-error -> exit 1" "$(v2e_tool phpstan phpstan required execution-error true)" '{}' 1 >/dev/null
	_gate "gate: required+disabled -> exit 1"      "$(v2e_tool gitleaks gitleaks required disabled true)"      '{}' 1 >/dev/null
	_gate "gate: recommended+unavailable -> warn, exit 0" "$(v2e_tool deptrac deptrac recommended unavailable true)" '{}' 0 >/dev/null
	_gate "gate: optional+unavailable -> info, exit 0"    "$(v2e_tool trufflehog trufflehog optional unavailable true)" '{}' 0 >/dev/null
	_gate "gate: required+not-applicable -> no fail, exit 0" "$(v2e_tool typescript typescript required not-applicable false)" '{}' 0 >/dev/null
	_gate "gate: one-of group satisfied -> exit 0" '{}' '{"tests":{"status":"satisfied","selected":"pest"}}' 0 >/dev/null
	_gate "gate: one-of group unsatisfied -> exit 1" '{}' '{"tests":{"status":"unsatisfied","selected":null}}' 1 >/dev/null

	# execution-error is DISTINGUISHABLE from a plain unavailable in the report.
	v2e_make_summary "$_d/ss.json" "$(v2e_tool phpstan phpstan required execution-error true)" '{}'
	sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/ss.json" --output-dir "$_d" --format json >/dev/null 2>&1 || true
	tpe_atleast "gate: execution-error is recorded distinctly in the enforcement report" \
		"$(jq -r '[.. | strings | select(test("execution-error"))] | length' "$_d/sentinel-shield-enforcement.json" 2>/dev/null || echo 0)"

	# unavailable NEVER becomes a clean 0: a collector with a missing input reports
	# 'unavailable' (exit 0) and a malformed input is an execution-error (exit 2).
	_o=$(sh "$ROOT/scripts/collectors/eslint.sh" --input "$_d/nope.json" 2>/dev/null); _orc=$?
	tpe_check "gate: missing scanner input -> collector exit 0" "$_orc" "0"
	tpe_check "gate: missing scanner input -> status unavailable (not fake-clean)" \
		"$(printf '%s' "$_o" | jq -r .status)" "unavailable"
	_mrc=0; sh "$ROOT/scripts/collectors/eslint.sh" --input "$ROOT/tests/fixtures/v2/malformed-eslint.json" >/dev/null 2>&1 || _mrc=$?
	tpe_check "gate: malformed scanner input -> collector exit 2 (execution-error)" "$_mrc" "2"

	rm -rf "$_d"
}

# --- package managers --------------------------------------------------------
v2e_pkgmgr() {
	RES="$ROOT/scripts/resolve-effective-profile.sh"
	BPT="$ROOT/scripts/bootstrap-profile-tools.sh"

	# npm / pnpm / yarn detection from the lockfile (bootstrap dry-run reports it). Real.
	for _pm in npm pnpm yarn; do
		_pd=$(mktemp -d); printf '{"name":"x"}' > "$_pd/package.json"
		case "$_pm" in
			npm)  printf '{}' > "$_pd/package-lock.json" ;;
			pnpm) printf '' > "$_pd/pnpm-lock.yaml" ;;
			yarn) printf '' > "$_pd/yarn.lock" ;;
		esac
		_det=$(sh "$BPT" --profile node --target "$_pd" --dry-run 2>&1 | awk -F'Node PM:' 'NF>1{gsub(/ /,"",$2);print $2;exit}')
		tpe_check "pkgmgr: $_pm lockfile -> detected manager $_pm" "$_det" "$_pm"
		rm -rf "$_pd"
	done

	# multiple distinct lockfiles -> ambiguous -> exit 2. Real.
	_md=$(mktemp -d); printf '{"name":"x"}' > "$_md/package.json"
	printf '{}' > "$_md/package-lock.json"; printf '' > "$_md/yarn.lock"
	_rc=0; sh "$BPT" --profile node --target "$_md" --dry-run >/dev/null 2>&1 || _rc=$?
	tpe_check "pkgmgr: multiple lockfiles -> exit 2 (ambiguous)" "$_rc" "2"
	rm -rf "$_md"

	# JS-without-TS: typescript is NOT-APPLICABLE (no tsconfig) -> never fails. Real.
	_js=$(mktemp -d); printf '{"name":"x"}' > "$_js/package.json"; printf '{}' > "$_js/package-lock.json"
	tpe_check "pkgmgr: JS-only (no tsconfig) -> typescript not-applicable" \
		"$(sh "$RES" --profile node --target "$_js" --format json 2>/dev/null | jq -r '.tools.typescript.applicability')" "not-applicable"
	rm -rf "$_js"

	# TS project: typescript is REQUIRED+APPLICABLE; a missing report fails the gate. Real.
	_ts=$(mktemp -d); mkdir -p "$_ts/reports/raw"; printf '{"name":"x"}' > "$_ts/package.json"
	printf '{}' > "$_ts/package-lock.json"; printf '{}' > "$_ts/tsconfig.json"
	mkdir -p "$_ts/node_modules/.bin"; printf '#!/bin/sh\n' > "$_ts/node_modules/.bin/vitest"; chmod +x "$_ts/node_modules/.bin/vitest"
	tpe_check "pkgmgr: TS project -> typescript required+applicable" \
		"$(sh "$RES" --profile node --target "$_ts" --format json 2>/dev/null | jq -r '.tools.typescript.policy + "/" + .tools.typescript.applicability')" "required/applicable"
	# seed every required report EXCEPT typescript. deps-install is a reportless
	# precondition satisfied by a package manager being present (npm is on PATH in any
	# node-test env), so it needs no override (a deps-install->external override would be
	# correctly REJECTED as a required-control downgrade, A1).
	for _r in $(sh "$RES" --profile node --target "$_ts" --format json 2>/dev/null \
		| jq -r '[.tools|to_entries[]|select(.value.policy=="required" and (.value.applicability//"")!="not-applicable")|(.value.report//empty|sub(".*/";""))]|unique[]'); do
		[ "$_r" = "typescript.json" ] && continue
		printf '{}' > "$_ts/reports/raw/$_r"
	done
	printf '{}' > "$_ts/reports/raw/tests.json"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_ts/reports/raw" --output "$_ts/ss.json" \
		--profile node --target "$_ts" >/dev/null 2>&1 || true
	tpe_atleast "pkgmgr: TS required report missing -> required_tool_failures>=1 (gate fails)" \
		"$(jq -r '.summary.required_tool_failures // 0' "$_ts/ss.json" 2>/dev/null || echo 0)"
	# typescript is the one required tool whose report we omitted, so its gate MUST fail.
	# The exact failing status is host-dependent (unavailable when no `tsc` on PATH;
	# execution-error when one IS present, e.g. globally on CI runners) — both are honest
	# required failures, never a pass. Assert typescript itself failed (hermetic to host tsc).
	tpe_check "pkgmgr: the missing required tool is typescript (gate failed, report absent)" \
		"$(jq -r '.tools.typescript | select(type=="object" and .policy=="required" and (.status=="unavailable" or .status=="execution-error")) | .tool' "$_ts/ss.json" 2>/dev/null)" "typescript"
	rm -rf "$_ts"
}

# --- provisioning (bootstrap + compat-resolver) ------------------------------
v2e_provisioning() {
	# shellcheck source=scripts/lib/compat-resolver.sh
	. "$ROOT/scripts/lib/compat-resolver.sh"
	FX="$ROOT/tests/fixtures/v2"; BPT="$ROOT/scripts/bootstrap-profile-tools.sh"

	# dry-run mutates nothing. Real.
	_dd=$(mktemp -d); printf '{"require":{}}' > "$_dd/composer.json"
	if sh "$BPT" --profile laravel --target "$_dd" --dry-run >/dev/null 2>&1; then _rc=0; else _rc=$?; fi
	tpe_check "provisioning: --dry-run exits 0" "$_rc" "0"
	tpe_check "provisioning: --dry-run writes no new files" \
		"$(find "$_dd" -type f ! -name composer.json | wc -l | tr -d ' ')" "0"
	rm -rf "$_dd"

	# version conflict -> classified 'conflict' (never silently applied). Real.
	_cf=$(mktemp -d); printf '{"require":{"phpstan/phpstan":"1.0.0"}}' > "$_cf/composer.json"
	tpe_check "provisioning: pinned tool clashing with app prod require -> conflict" \
		"$(cr_classify_tool "$_cf" "$FX/conflict-manifest.json" phpstan | cut -f1)" "conflict"
	# framework-downgrade rejected: the conflict advises an ISOLATED install (no downgrade). Real.
	tpe_atleast "provisioning: conflict advises isolated install (no framework downgrade)" \
		"$(cr_classify_tool "$_cf" "$FX/conflict-manifest.json" phpstan | cut -f2- | grep -c 'isolated install')"
	rm -rf "$_cf"

	# rollback on failure: stub composer to FAIL the require; bootstrap --apply must
	# roll back the dependency files and exit non-zero. [failure-injection — no real composer]
	_rb=$(mktemp -d); printf '{"name":"app/app","require":{}}' > "$_rb/composer.json"
	_before=$(cat "$_rb/composer.json")
	_fbin=$(mktemp -d)
	cat > "$_fbin/composer" <<'FAKE'
#!/bin/sh
case "$*" in *validate*) exit 0 ;; *) echo "fake composer: forced failure ($*)" >&2; exit 1 ;; esac
FAKE
	chmod +x "$_fbin/composer"
	_rc=0; _log=$(PATH="$_fbin:$PATH" sh "$BPT" --profile laravel --target "$_rb" --apply 2>&1) || _rc=$?
	tpe_atleast "provisioning: failed install exits non-zero" "$([ "$_rc" -ne 0 ] && echo 1 || echo 0)"
	tpe_contains "provisioning: failure reports a rollback" "$_log" "roll"
	tpe_check "provisioning: composer.json restored after rollback" "$(cat "$_rb/composer.json")" "$_before"
	rm -rf "$_rb" "$_fbin"
}

# --- workflow plan / templates ----------------------------------------------
v2e_workflow() {
	WF="$ROOT/templates/workflows/sentinel-shield.yml"

	# laravel/symfony plans EXECUTE every required tool: run the real planner on a
	# seeded fixture and parse the pr-execution manifest. EVERY required PR tool the
	# resolver expects must appear in the manifest (the plan selected + attempted it).
	# Real. NOTE: status=ran additionally requires the tool's runner SCRIPT to exist;
	# the symfony profile references runner scripts (phpstan.sh / phpstan-symfony.sh)
	# that are not present in scripts/runners/, so those land as 'unavailable' (a real
	# provisioning gap, see limitations) — hence the membership assertion for symfony
	# and the stricter all-ran assertion only for laravel (whose runners exist).
	for _p in laravel symfony; do
		_w=$(mktemp -d); cp -R "$ROOT/tests/e2e/$_p/." "$_w/" 2>/dev/null || { rm -rf "$_w"; continue; }
		sh "$ROOT/scripts/run-tool-plan.sh" --profile "$_p" --target "$_w" --stage pr >/dev/null 2>&1 || true
		_m="$_w/reports/pr-execution.json"
		_eff=$(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_p" --target "$_w" --format json 2>/dev/null || true)
		_missing=0
		for _k in $(printf '%s' "$_eff" | jq -r '.tools|to_entries[]|select(.value.policy=="required" and .value.execution.pr==true and (.value.applicability//"unknown")!="not-applicable")|.key'); do
			jq -e --arg k "$_k" '(.tools[$k] // .one_of_groups[$k]) != null' "$_m" >/dev/null 2>&1 || _missing=$((_missing + 1))
		done
		tpe_check "workflow: $_p PR plan includes every required PR tool (manifest)" "$_missing" "0"
		rm -rf "$_w"
	done

	# laravel: run-tool-plan ATTEMPTS every required PR tool — each appears in the
	# execution manifest (none silently dropped). Without the e2e fakes the real tools
	# are absent so they record 'unavailable' (B17 deletes any seeded report before
	# running), which is the honest outcome; that they reach 'ran' with real/faked tools
	# is proven end-to-end by scripts/e2e-harness.sh. Here we assert COVERAGE: every
	# required PR tool from the resolver plan is present in the manifest.
	_wl=$(mktemp -d); cp -R "$ROOT/tests/e2e/laravel/." "$_wl/" 2>/dev/null || true
	sh "$ROOT/scripts/run-tool-plan.sh" --profile laravel --target "$_wl" --stage pr >/dev/null 2>&1 || true
	_plan_req=$(sh "$RES" --profile laravel --target "$_wl" --format json 2>/dev/null \
		| jq -r '[.tools|to_entries[]|select(.value.policy=="required" and (.value.applicability//"")!="not-applicable" and (.value.execution.pr==true))|.key]|sort|join(" ")')
	_missing_in_manifest=0
	for _t in $_plan_req; do
		jq -e --arg t "$_t" '((.tools // {})|has($t)) or ((.one_of_groups // {})|has($t))' "$_wl/reports/pr-execution.json" >/dev/null 2>&1 || _missing_in_manifest=$((_missing_in_manifest+1))
	done
	tpe_check "workflow: laravel run-tool-plan attempts every required PR tool (manifest coverage)" \
		"$_missing_in_manifest" "0"
	rm -rf "$_wl"

	# php-library AVOIDS Laravel bootstrap: no larastan, and phpstan uses the GENERIC
	# runner (not laravel-phpstan.sh which boots artisan). Real (manifest assertion).
	_pl="$ROOT/profiles/php-library/profile.manifest.json"
	tpe_check "workflow: php-library declares NO larastan tool" \
		"$(jq -r '.tools | has("larastan")' "$_pl")" "false"
	tpe_check "workflow: php-library phpstan uses the generic runner (no artisan boot)" \
		"$(jq -r '.tools.phpstan.runner' "$_pl")" "scripts/runners/phpstan.sh"
	_lara=0; for _r in $(jq -r '[.tools[].runner // empty]|.[]' "$_pl" 2>/dev/null); do
		case "$_r" in *laravel*) _lara=$((_lara+1)) ;; esac; done
	tpe_check "workflow: php-library wires no laravel-* runner" "$_lara" "0"

	# JS-only avoids required TS; TS runs typecheck (typescript runner wired). Real.
	tpe_check "workflow: node profile wires the typescript runner (typecheck)" \
		"$(jq -r '.tools.typescript.runner' "$ROOT/profiles/node/profile.manifest.json")" "scripts/runners/typescript.sh"

	# every `uses:` in the CANONICAL workflow template is 40-hex SHA-pinned (local
	# `./` composite actions exempt). The split per-stage templates intentionally show
	# `@vN` tags with a documented "pin before production" caveat (see limitations), so
	# the canonical template is the pin contract. Real.
	tpe_check "workflow: canonical template — all 'uses:' SHA-pinned (40-hex)" \
		"$(grep -hE '^[[:space:]]*uses:[[:space:]]' "$WF" | grep -vE 'uses:[[:space:]]*\./' | grep -cvE '@[0-9a-fA-F]{40}')" "0"

	# no template uses the dangerous pull_request_target trigger (only in comments). Real.
	tpe_check "workflow: no template uses an active pull_request_target trigger" \
		"$(grep -rlE '^[[:space:]]*pull_request_target:' "$ROOT/templates/workflows/" 2>/dev/null | wc -l | tr -d ' ')" "0"

	# default-branch handling is present in the canonical template (main-gate stage). Real.
	tpe_atleast "workflow: canonical template handles the default branch" \
		"$(grep -cE 'default_branch' "$WF")"
}

# run_v2_enforcement — self-test group 'v2-enforcement' (wired into the dispatch + 'all').
run_v2_enforcement() {
	log_info "v2-enforcement: full policy->gate matrix (composition / states / one-of / pkgmgr / provisioning / workflow / consistency)"
	v2e_composition
	v2e_consistency
	v2e_states
	v2e_pkgmgr
	v2e_provisioning
	v2e_workflow
	if [ "$TPE_FAILS" -ne 0 ]; then log_error "v2-enforcement: $TPE_FAILS case(s) failed"; return 1; fi
	log_info "v2-enforcement: OK (composition + tool-states/gate + one-of + package-managers + provisioning + workflow + cross-subsystem consistency)"
}

# --- v2-review: Part D regression matrix + Part C cross-subsystem consistency -
# A faithful matrix over the REAL v2 scripts (canonical resolver, control-waivers
# lib, bootstrap, doctor, run-tool-plan, resolve-workflow-plan, build-security-
# summary, enforce-gates). Every case drives an actual CLI/lib and asserts an exact
# exit code / output substring. Items that cannot be exercised live this session are
# marked [structural] / [simulated]. Owns tests/fixtures/v2/{profiles/oneof-only,
# profiles/noop-required,runners/*}.
VR_FAILS=0
vr_check()   { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; VR_FAILS=$((VR_FAILS + 1)); fi; }
vr_atleast() { vr_check "$1" "$([ "${2:-0}" -ge 1 ] && echo yes || echo no)" "yes"; }
vr_contains(){ case "$2" in *"$3"*) vr_check "$1" yes yes ;; *) vr_check "$1" "no($2)" yes ;; esac; }
# vr_run <expected-exit> <desc> <command...> — run (stdout/stderr hidden), compare exit.
# A leading `env VAR=val` is supported because it is just part of the command vector.
vr_run() {
	vrr_e=$1; vrr_desc=$2; shift 2
	if "$@" >/dev/null 2>&1; then vrr_rc=0; else vrr_rc=$?; fi
	vr_check "$vrr_desc" "$vrr_rc" "$vrr_e"
}

# vr_mksum <out> <tools-json> <summary-overrides-json> — craft a v2 security summary
# (clean baseline counts + a tools{} policy block + summary overrides). No committed
# fixture is mutated; everything is built deterministically with jq.
vr_mksum() {
	jq -n --argjson tools "$2" --argjson so "$3" '
		{ version:"1.0", generated_at:"2026-01-01T00:00:00Z",
		  project:{name:"t",type:"laravel",criticality:"high"},
		  source:{commit:"c",branch:"b",workflow:"w"},
		  summary:({ secrets:0, critical_vulnerabilities:0, high_vulnerabilities:0,
			medium_vulnerabilities:0, architecture_violations:0, type_errors:0,
			test_failures:0, unsafe_docker:0, unsafe_github_actions:0, expired_exceptions:0,
			missing_sbom:false, missing_release_evidence:false } + $so),
		  tools:$tools, one_of_groups:{},
		  exceptions:{active:0,expired:0},
		  evidence:{ sbom:{present:true,path:"x"}, release_evidence:{present:true,path:"y"} } }' > "$1"
}

# vr_waiver_json <out> <tool> <expires_at> [approved_by] — write a schema-conformant
# control-waivers file. approved_by defaults to a DISTINCT approver (no self-approval).
vr_waiver_json() {
	jq -n --arg t "$2" --arg exp "$3" --arg ap "${4:-bob}" '
		{version:"1", waivers:[{tool:$t, justification:"self-test", owner:"alice",
		 approved_by:$ap, created_at:"2000-01-01", expires_at:$exp, tracking_issue:"ISSUE-1"}]}' > "$1"
}

# --- (D) project tool-policy override: weaken/strengthen/keys/policy/waiver ----
vr_override() {
	_R="$ROOT/scripts/resolve-effective-profile.sh"
	_d=$(mktemp -d)
	# Overrides (built inline — no secrets, no abs paths).
	printf '{"tools":{"phpstan":{"policy":"optional"}}}'  > "$_d/weaken-required.json"   # required -> optional
	printf '{"tools":{"php-tests":{"policy":"optional"}}}' > "$_d/weaken-oneof.json"     # one-of (php-tests) -> optional
	printf '{"tools":{"deptrac":{"policy":"required"}}}'  > "$_d/strengthen.json"        # recommended -> required
	printf '{"tools":{"not_a_real_tool":{"policy":"required"}}}' > "$_d/typo.json"
	printf '{"tools":{" ":{"policy":"required"}}}'        > "$_d/blank-key.json"
	printf '{"tools":{"phpstan":{"policy":null}}}'        > "$_d/pol-null.json"
	printf '{"tools":{"phpstan":{}}}'                     > "$_d/pol-missing.json"
	printf '{"tools":{"phpstan":{"policy":5}}}'           > "$_d/pol-numeric.json"
	printf '{"tools":{"phpstan":{"policy":"bogus"}}}'     > "$_d/pol-unknown.json"
	printf '{"tools":{"phpstan":"required"}}'             > "$_d/pol-nonobject.json"

	# no-downgrade: a required / one-of control cannot be weakened (exit 2); strengthen OK (exit 0).
	vr_run 2 "(D) override weakening a REQUIRED control -> exit 2"  sh "$_R" --profile laravel --override "$_d/weaken-required.json" --format json
	vr_run 2 "(D) override weakening a ONE-OF control -> exit 2"    sh "$_R" --profile laravel --override "$_d/weaken-oneof.json" --format json
	vr_run 0 "(D) override STRENGTHENING (recommended->required) -> exit 0" sh "$_R" --profile laravel --override "$_d/strengthen.json" --format json
	vr_check "(D) strengthen actually raises deptrac -> required" \
		"$(sh "$_R" --profile laravel --override "$_d/strengthen.json" --format json 2>/dev/null | jq -r '.tools.deptrac.policy')" "required"

	# unknown/typo + blank key => exit 2.
	vr_run 2 "(D) unknown/typo override key -> exit 2"  sh "$_R" --profile laravel --override "$_d/typo.json" --format json
	vr_run 2 "(D) blank override key -> exit 2"         sh "$_R" --profile laravel --override "$_d/blank-key.json" --format json

	# invalid override policy values (null/missing/numeric/unknown/non-object) => exit 2.
	vr_run 2 "(D) override policy null -> exit 2"        sh "$_R" --profile laravel --override "$_d/pol-null.json" --format json
	vr_run 2 "(D) override policy missing -> exit 2"     sh "$_R" --profile laravel --override "$_d/pol-missing.json" --format json
	vr_run 2 "(D) override policy numeric -> exit 2"     sh "$_R" --profile laravel --override "$_d/pol-numeric.json" --format json
	vr_run 2 "(D) override policy unknown-enum -> exit 2" sh "$_R" --profile laravel --override "$_d/pol-unknown.json" --format json
	vr_run 2 "(D) override entry non-object -> exit 2"   sh "$_R" --profile laravel --override "$_d/pol-nonobject.json" --format json

	# weakening WITH a valid waiver => exit 0; with self-approved / expired / invalid-date => still exit 2.
	vr_waiver_json "$_d/w-valid.json"   phpstan 2999-12-31
	vr_waiver_json "$_d/w-self.json"    phpstan 2999-12-31 alice          # owner==approved_by
	vr_waiver_json "$_d/w-expired.json" phpstan 2000-01-02
	vr_waiver_json "$_d/w-baddate.json" phpstan 2026-99-99
	vr_run 0 "(D) weaken required WITH valid waiver -> exit 0"       sh "$_R" --profile laravel --override "$_d/weaken-required.json" --waivers "$_d/w-valid.json" --format json
	vr_run 2 "(D) weaken required + self-approved waiver -> exit 2"  sh "$_R" --profile laravel --override "$_d/weaken-required.json" --waivers "$_d/w-self.json" --format json
	vr_run 2 "(D) weaken required + EXPIRED waiver -> exit 2"        sh "$_R" --profile laravel --override "$_d/weaken-required.json" --waivers "$_d/w-expired.json" --format json
	vr_run 2 "(D) weaken required + invalid-date waiver -> exit 2"   sh "$_R" --profile laravel --override "$_d/weaken-required.json" --waivers "$_d/w-baddate.json" --format json

	# missing override validator + --override => exit 2 (no bypass). (Issue 10) Run
	# against a TEMP COPY of scripts/ with the validator removed — NEVER rename the real
	# repo file (an interrupted rename would leave the worktree broken). EP_REPO_ROOT
	# points the copied resolver at the real profiles/.
	if [ -f "$ROOT/scripts/lib/tool-policy-override.sh" ]; then
		_tcp=$(mktemp -d)
		cp -R "$ROOT/scripts" "$_tcp/scripts"
		rm -f "$_tcp/scripts/lib/tool-policy-override.sh"
		if EP_REPO_ROOT="$ROOT" sh "$_tcp/scripts/resolve-effective-profile.sh" \
			--profile laravel --override "$_d/strengthen.json" --format json >/dev/null 2>&1; then _r=0; else _r=$?; fi
		rm -rf "$_tcp"
		vr_check "(D) missing override validator + --override -> exit 2 (no bypass)" "$_r" "2"
		vr_check "(D) real override validator untouched (temp-copy method)" "$([ -f "$ROOT/scripts/lib/tool-policy-override.sh" ] && echo yes || echo no)" "yes"
	else
		log_warn "(D) tool-policy-override.sh absent; SKIPPING hidden-validator case"
	fi

	# --profile and --manifest together => exit 2; neither => exit 2.
	vr_run 2 "(D) --profile AND --manifest together -> exit 2" sh "$_R" --profile laravel --manifest "$ROOT/profiles/laravel/profile.manifest.json" --format json
	vr_run 2 "(D) neither --profile nor --manifest -> exit 2"  sh "$_R" --format json

	rm -rf "$_d"
}

# --- (D) control-waiver validation via the SHARED lib (cw_validate_file/keys) --
vr_waivers() {
	# Source the canonical validator and exercise it directly (no consumer parses waivers).
	# NOTE: the lib's functions use internal `_d`/`_f`/`_today`/`_rc` (POSIX sh has no
	# function scope), so this helper deliberately uses _wd/_wt to avoid clobbering.
	# shellcheck source=scripts/lib/control-waivers.sh
	. "$ROOT/scripts/lib/control-waivers.sh"
	_wt=$(cw_today_utc)
	_wd=$(mktemp -d)
	# valid future + valid today -> validate OK and the key is APPLIED (appears in cw_valid_keys).
	vr_waiver_json "$_wd/future.json" larastan 2999-12-31
	vr_waiver_json "$_wd/today.json"  larastan "$_wt"
	vr_run 0 "(D) waiver valid future -> cw_validate_file rc 0"  cw_validate_file "$_wd/future.json"
	vr_check "(D) valid future waiver is APPLIED (key listed)" \
		"$(cw_valid_keys "$_wd/future.json" 2>/dev/null | grep -c '^larastan$')" "1"
	vr_run 0 "(D) waiver expiring TODAY -> cw_validate_file rc 0" cw_validate_file "$_wd/today.json"
	vr_check "(D) today waiver is APPLIED (valid through end of UTC day)" \
		"$(cw_valid_keys "$_wd/today.json" "$_wt" 2>/dev/null | grep -c '^larastan$')" "1"
	# expired -> structurally valid but NOT applied (absent from cw_valid_keys).
	vr_waiver_json "$_wd/expired.json" larastan 2000-01-02
	vr_run 0 "(D) expired waiver -> still structurally valid (rc 0)" cw_validate_file "$_wd/expired.json"
	vr_check "(D) expired waiver is NOT applied (key absent)" \
		"$(cw_valid_keys "$_wd/expired.json" 2>/dev/null | grep -c '^larastan$')" "0"
	# self-approved -> invalid (owner==approved_by).
	vr_waiver_json "$_wd/self.json" larastan 2999-12-31 alice
	vr_run 2 "(D) self-approved waiver -> invalid (rc 2)" cw_validate_file "$_wd/self.json"
	# missing approved_by -> invalid.
	jq -n '{version:"1",waivers:[{tool:"larastan",justification:"x",owner:"alice",created_at:"2020-01-01",expires_at:"2999-12-31",tracking_issue:"I"}]}' > "$_wd/missing-approver.json"
	vr_run 2 "(D) missing approved_by -> invalid (rc 2)" cw_validate_file "$_wd/missing-approver.json"
	# bad dates: invalid month / feb-31 / non-date text / empty expires_at -> invalid.
	vr_waiver_json "$_wd/badmonth.json" larastan 2026-99-99
	vr_waiver_json "$_wd/feb31.json"    larastan 2026-02-31
	vr_waiver_json "$_wd/text.json"     larastan soon
	vr_waiver_json "$_wd/emptyexp.json" larastan ""
	vr_run 2 "(D) invalid month 2026-99-99 -> invalid (rc 2)" cw_validate_file "$_wd/badmonth.json"
	vr_run 2 "(D) feb-31 (2026-02-31) -> invalid (rc 2)"      cw_validate_file "$_wd/feb31.json"
	vr_run 2 "(D) non-date text expires_at -> invalid (rc 2)" cw_validate_file "$_wd/text.json"
	vr_run 2 "(D) empty expires_at -> invalid (rc 2)"         cw_validate_file "$_wd/emptyexp.json"
	rm -rf "$_wd"
}

# --- (D) bootstrap: required-disabled gate, package-manager, rollback, lint ----
vr_bootstrap() {
	_B="$ROOT/scripts/bootstrap-profile-tools.sh"

	# required tool disabled in installation.json WITHOUT a waiver => fail (exit 3) BEFORE any mutation.
	_dt=$(mktemp -d); mkdir -p "$_dt/.sentinel-shield"; printf '{"require":{}}' > "$_dt/composer.json"
	printf '{"disabled_tools":["phpstan"]}' > "$_dt/.sentinel-shield/installation.json"
	_before=$(cat "$_dt/composer.json")
	vr_run 3 "(D) bootstrap required-disabled, no waiver -> exit 3" sh "$_B" --profile laravel --target "$_dt" --apply
	vr_check "(D) bootstrap fails BEFORE mutation (composer.json unchanged)" "$(cat "$_dt/composer.json")" "$_before"
	# WITH a valid control-waiver => reported WAIVED (exit 0).
	vr_waiver_json "$_dt/.sentinel-shield/control-waivers.json" phpstan 2999-12-31
	_out=$(sh "$_B" --profile laravel --target "$_dt" --dry-run 2>&1); _r=$?
	vr_check "(D) bootstrap required-disabled WITH valid waiver -> exit 0" "$_r" "0"
	vr_contains "(D) bootstrap reports the disabled-required tool as waived" "$_out" "waived"
	rm -rf "$_dt"

	# Node package-manager resolution from multiple lockfiles.
	_pm=$(mktemp -d); printf '{"name":"x","packageManager":"yarn@1.22.0"}' > "$_pm/package.json"
	printf '{}' > "$_pm/package-lock.json"; printf '' > "$_pm/yarn.lock"
	vr_run 0 "(D) multi-lockfile + MATCHING packageManager -> exit 0" sh "$_B" --profile node --target "$_pm" --dry-run
	rm -rf "$_pm"
	_pm=$(mktemp -d); printf '{"name":"x","packageManager":"pnpm@8"}' > "$_pm/package.json"
	printf '{}' > "$_pm/package-lock.json"; printf '' > "$_pm/yarn.lock"
	vr_run 2 "(D) multi-lockfile + NON-matching packageManager -> exit 2" sh "$_B" --profile node --target "$_pm" --dry-run
	rm -rf "$_pm"
	_pm=$(mktemp -d); printf '{"name":"x"}' > "$_pm/package.json"
	printf '{}' > "$_pm/package-lock.json"; printf '' > "$_pm/yarn.lock"
	vr_run 2 "(D) multi-lockfile + NO packageManager -> exit 2" sh "$_B" --profile node --target "$_pm" --dry-run
	rm -rf "$_pm"

	# rollback: a mutating command failing AFTER the touched-flag is set must roll back
	# the dependency-declaration files and exit non-zero. Failure is injected with a stub
	# composer on PATH (no real composer this session).
	_rb=$(mktemp -d); printf '{"name":"app/app","require":{}}' > "$_rb/composer.json"
	_before=$(cat "$_rb/composer.json")
	_fbin=$(mktemp -d)
	cat > "$_fbin/composer" <<'FAKE'
#!/bin/sh
case "$*" in *validate*) exit 0 ;; *) echo "fake composer: forced failure ($*)" >&2; exit 1 ;; esac
FAKE
	chmod +x "$_fbin/composer"
	if _log=$(PATH="$_fbin:$PATH" sh "$_B" --profile laravel --target "$_rb" --apply 2>&1); then _r=0; else _r=$?; fi
	vr_atleast "(D) bootstrap rollback: failed install exits non-zero" "$([ "$_r" -ne 0 ] && echo 1 || echo 0)"
	vr_contains "(D) bootstrap rollback: failure reports a rollback" "$_log" "roll"
	vr_check "(D) bootstrap rollback: composer.json restored" "$(cat "$_rb/composer.json")" "$_before"
	rm -rf "$_rb" "$_fbin"

	# Lint bootstrap with ShellCheck. The whole repo intentionally uses the mandated
	# `SCRIPT_DIR=$(CDPATH= cd -- ...)` idiom which trips the SC1007 *warning* in EVERY
	# script, so the contract here is "no ERROR-severity findings" (-S error). See limitations.
	if command_exists shellcheck; then
		vr_run 0 "(D) shellcheck parses bootstrap (no error-severity findings)" \
			shellcheck -x -S error "$ROOT/scripts/bootstrap-profile-tools.sh"
	else
		log_warn "(D) shellcheck not present; SKIPPING bootstrap lint (validate with: shellcheck -x -S error scripts/bootstrap-profile-tools.sh)"
	fi
}

# --- (D) planners + summary: target scoping, one-of gating, applicability ------
vr_planning() {
	_FX="$ROOT/tests/fixtures/v2"

	# build-security-summary target probes do NOT fall back to the SS repo: an EMPTY
	# target makes required tools unavailable/not-configured (never a spoofed pass).
	_e=$(mktemp -d); mkdir -p "$_e/reports/raw"
	sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_e/reports/raw" --output "$_e/ss.json" \
		--profile laravel --target "$_e" >/dev/null 2>&1 || true
	vr_check "(D) build-summary: empty target -> required phpstan unavailable (no SS-repo fallback)" \
		"$(jq -r '.tools.phpstan.status' "$_e/ss.json" 2>/dev/null)" "unavailable"
	vr_atleast "(D) build-summary: empty target -> required_tool_failures>=1" \
		"$(jq -r '.summary.required_tool_failures // 0' "$_e/ss.json" 2>/dev/null)"
	rm -rf "$_e"

	# doctor: an UNSATISFIED required one-of group fails under require-existing (exit 3);
	# satisfying it (pest only) passes (exit 0). Isolated via the oneof-only fixture.
	_e=$(mktemp -d)
	vr_run 3 "(D) doctor: unsatisfied required one-of (neither pest nor phpunit) -> exit 3" \
		env EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/doctor.sh" --target "$_e" --profile oneof-only --tool-mode require-existing --quiet
	mkdir -p "$_e/vendor/bin"; printf '#!/bin/sh\n' > "$_e/vendor/bin/pest"; chmod +x "$_e/vendor/bin/pest"
	vr_run 0 "(D) doctor: required one-of satisfied (pest only) -> exit 0" \
		env EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/doctor.sh" --target "$_e" --profile oneof-only --tool-mode require-existing --quiet
	rm -rf "$_e"

	# resolve-workflow-plan excludes a not-applicable tool: node WITHOUT tsconfig drops
	# typescript from the PR plan; WITH tsconfig it appears (proves it is the applicability
	# filter, not mere absence).
	_js="$ROOT/tests/e2e/js-only"
	vr_check "(D) workflow-plan: node w/o tsconfig EXCLUDES typescript (not-applicable)" \
		"$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile node --target "$_js" --stage pr 2>/dev/null | jq -r '[.tools[].tool]|map(select(.=="typescript"))|length')" "0"
	_ts=$(mktemp -d); printf '{"name":"x"}' > "$_ts/package.json"; printf '{}' > "$_ts/package-lock.json"; printf '{}' > "$_ts/tsconfig.json"
	vr_check "(D) workflow-plan: node WITH tsconfig INCLUDES typescript (applicable)" \
		"$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile node --target "$_ts" --stage pr 2>/dev/null | jq -r '[.tools[].tool]|map(select(.=="typescript"))|length')" "1"
	rm -rf "$_ts"

	# the workflow PLAN scheduled set equals the run-tool-plan scheduled execution set
	# (both consume the one canonical resolver; one-of members do not run in scheduled).
	_w=$(mktemp -d); cp -R "$_js/." "$_w/" 2>/dev/null || true
	_wp=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile node --target "$_w" --stage scheduled 2>/dev/null | jq -S -c '[.tools[].tool]|sort')
	sh "$ROOT/scripts/run-tool-plan.sh" --profile node --target "$_w" --stage scheduled >/dev/null 2>&1 || true
	_rtp=$(jq -S -c '[((.tools // {})|keys[]), ((.one_of_groups // {})|keys[])]|sort' "$_w/reports/scheduled-execution.json" 2>/dev/null || echo NA)
	vr_check "(D) workflow-plan scheduled set == run-tool-plan scheduled set" "$_wp" "$_rtp"
	rm -rf "$_w"

	# run-tool-plan: a STALE valid report cannot satisfy a no-op runner (B17 deletes it
	# first) -> the required tool is unavailable -> exit 3.
	_e=$(mktemp -d); mkdir -p "$_e/reports/raw"; printf '{"stale":true}' > "$_e/reports/raw/noop.json"
	vr_run 3 "(D) run-tool-plan: stale report + no-op runner -> exit 3" \
		env EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/run-tool-plan.sh" --profile noop-required --target "$_e" --stage pr
	vr_check "(D) run-tool-plan: stale report did NOT satisfy (status unavailable)" \
		"$(jq -r '.tools.noop.status' "$_e/reports/pr-execution.json" 2>/dev/null)" "unavailable"
	vr_check "(D) run-tool-plan: no fabricated report_present from stale" \
		"$(jq -r '.tools.noop.report_present' "$_e/reports/pr-execution.json" 2>/dev/null)" "false"
	rm -rf "$_e"

	# run-tool-plan: a required one-of group with NEITHER member present -> exit 3;
	# with a member present (pest) the selected member runs -> exit 0.
	_e=$(mktemp -d)
	vr_run 3 "(D) run-tool-plan: one-of neither member present -> exit 3" \
		env EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/run-tool-plan.sh" --profile oneof-only --target "$_e" --stage pr
	vr_check "(D) run-tool-plan: one-of unsatisfied recorded" \
		"$(jq -r '.one_of_groups.tests.status' "$_e/reports/pr-execution.json" 2>/dev/null)" "unsatisfied"
	mkdir -p "$_e/vendor/bin"; printf '#!/bin/sh\n' > "$_e/vendor/bin/pest"; chmod +x "$_e/vendor/bin/pest"
	vr_run 0 "(D) run-tool-plan: one-of satisfied (pest selected + ran) -> exit 0" \
		env EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/run-tool-plan.sh" --profile oneof-only --target "$_e" --stage pr
	vr_check "(D) run-tool-plan: selected member ran" \
		"$(jq -r '.one_of_groups.tests.status' "$_e/reports/pr-execution.json" 2>/dev/null)" "ran"
	rm -rf "$_e"
}

# --- (D) enforce-gates: summary-only counter + policy-only failure visibility --
vr_gate_env() { sh "$ROOT/scripts/resolve-gates.sh" --profile "$ROOT/templates/profile.yaml" --mode baseline --output-dir "$1" --format env >/dev/null 2>&1; }
# vr_gate — v2-review sub-suite: gate.
vr_gate() {
	_d=$(mktemp -d); vr_gate_env "$_d"; _genv="$_d/sentinel-shield-gates.env"

	# summary-only required_tool_failures>0 (no detailed .tools records) => fail.
	vr_mksum "$_d/summ-only.json" '{}' '{"required_tool_failures":1}'
	vr_run 1 "(D) enforce: summary-only required_tool_failures>0 -> exit 1" \
		sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/summ-only.json" --output-dir "$_d" --format json
	vr_contains "(D) enforce: summary-only failure surfaces required_tool_policy in JSON" \
		"$(jq -c '.failed_gates' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)" "required_tool_policy"

	# policy-only failure (a required tool unavailable; ALL finding counts 0) must show in
	# JSON failed_gates AND markdown (NOT 'None') AND the exit code.
	vr_mksum "$_d/policy.json" '{"phpstan":{"tool":"phpstan","policy":"required","status":"unavailable","gate_enforced":true}}' '{}'
	vr_run 1 "(D) enforce: policy-only failure -> exit 1" \
		sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/policy.json" --output-dir "$_d" --format all
	vr_contains "(D) enforce: policy-only failure in JSON failed_gates" \
		"$(jq -c '.failed_gates' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)" "required_tool_policy"
	# the Failed-gates section of the markdown lists required_tool_policy (not 'None.').
	_mdfail=$(awk '/^## Failed gates/{f=1;next} f&&/^## /{f=0} f' "$_d/sentinel-shield-enforcement.md" 2>/dev/null)
	vr_contains "(D) enforce: policy-only failure in markdown Failed-gates (not None)" "$_mdfail" "required_tool_policy"
	rm -rf "$_d"
}

# --- (C1) cross-subsystem consistency: same normalized policy set everywhere ----
vr_consistency() {
	_PK='[.tools|to_entries[]|select(.value.policy=="required" or .value.policy=="recommended")|{(.key):.value.policy}]|add'
	_PW='[.stages|to_entries[].value[]|select(.policy=="required" or .policy=="recommended")|{(.tool):.policy}]|add'
	_PS='[.tools|to_entries[]|select(.value|type=="object" and has("policy"))|select(.value.policy=="required" or .value.policy=="recommended")|{(.value.tool):.value.policy}]|add'
	_d=$(mktemp -d); mkdir -p "$_d/raw"
	for _p in laravel laravel-react-docker; do
		_eff=$(sh "$ROOT/scripts/resolve-effective-profile.sh" --profile "$_p" --format json 2>/dev/null || true)
		_tp=$(sh "$ROOT/scripts/resolve-tool-plan.sh" --profile "$_p" --format json 2>/dev/null || true)
		_wp=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile "$_p" --stage all 2>/dev/null || true)
		sh "$ROOT/scripts/build-security-summary.sh" --raw-dir "$_d/raw" --output "$_d/ss.json" --profile "$_p" >/dev/null 2>&1 || true
		_he=$(printf '%s' "$_eff" | jq -S -c "$_PK" 2>/dev/null || echo NAe)
		_ht=$(printf '%s' "$_tp"  | jq -S -c "$_PK" 2>/dev/null || echo NAt)
		_hw=$(printf '%s' "$_wp"  | jq -S -c "$_PW" 2>/dev/null || echo NAw)
		_hs=$(jq -S -c "$_PS" "$_d/ss.json" 2>/dev/null || echo NAs)
		vr_check "(C1)[$_p] resolve-tool-plan set == resolver set"        "$_ht" "$_he"
		vr_check "(C1)[$_p] resolve-workflow-plan set == resolver set"    "$_hw" "$_he"
		vr_check "(C1)[$_p] build-security-summary set == resolver set"   "$_hs" "$_he"
	done
	rm -rf "$_d"
}

# --- (C2) a valid waiver is VISIBLE and does NOT flip the tool to pass/optional -
vr_waiver_visibility() {
	_FX="$ROOT/tests/fixtures/v2"
	# doctor: a valid waiver for the unsatisfied one-of GROUP surfaces a WAIVED line and
	# downgrades exit to 0, but the group is still reported as a one-of control (not flipped).
	_e=$(mktemp -d); vr_waiver_json "$_e/cw.json" tests 2999-12-31
	_out=$(EP_REPO_ROOT="$_FX" sh "$ROOT/scripts/doctor.sh" --target "$_e" --profile oneof-only \
		--tool-mode require-existing --control-waivers "$_e/cw.json" 2>&1); _r=$?
	vr_check "(C2) doctor with valid waiver -> exit 0" "$_r" "0"
	vr_contains "(C2) doctor shows the waiver (WAIVED line for the group)" "$_out" "WAIVED"
	vr_contains "(C2) doctor still lists the group as one-of (not flipped to pass/optional)" "$_out" "one-of tests"
	rm -rf "$_e"

	# enforce-gates: a valid waiver for a required-unavailable tool surfaces in JSON
	# (.tool_policy.waived) AND markdown, downgrades the gate (exit 0), and keeps the
	# tool's policy as required (never rewritten to pass/optional).
	_d=$(mktemp -d); vr_gate_env "$_d"; _genv="$_d/sentinel-shield-gates.env"
	vr_mksum "$_d/p.json" '{"phpstan":{"tool":"phpstan","policy":"required","status":"unavailable","gate_enforced":true}}' '{}'
	vr_waiver_json "$_d/cw.json" phpstan 2999-12-31
	vr_run 0 "(C2) enforce with valid waiver -> exit 0 (downgraded)" \
		sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/p.json" --control-waivers "$_d/cw.json" --output-dir "$_d" --format all
	vr_check "(C2) enforce JSON records the tool as waived" \
		"$(jq -r '[.tool_policy.waived[].tool]|index("phpstan")!=null' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)" "true"
	vr_contains "(C2) enforce markdown mentions the waiver" "$(cat "$_d/sentinel-shield-enforcement.md" 2>/dev/null)" "waived"
	vr_check "(C2) waiver does NOT flip the tool policy (still required)" \
		"$(jq -r '.tools.phpstan.policy' "$_d/p.json")" "required"
	vr_check "(C2) waiver does NOT show the tool as a required-tool-failure" \
		"$(jq -r '[.tool_policy.required_tool_failures[]?.tool]|index("phpstan")//"none"' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)" "none"
	rm -rf "$_d"
}

# --- (C3) a control-waiver does NOT suppress findings -------------------------
vr_findings_not_suppressed() {
	_d=$(mktemp -d); vr_gate_env "$_d"; _genv="$_d/sentinel-shield-gates.env"
	# semgrep RAN and reported findings (high_vulnerabilities=1); a control-waiver exists
	# for semgrep (availability channel) — it must NOT suppress the finding gate.
	vr_mksum "$_d/f.json" '{"semgrep":{"tool":"semgrep","policy":"required","status":"findings","gate_enforced":true}}' '{"high_vulnerabilities":1}'
	vr_waiver_json "$_d/cw.json" semgrep 2999-12-31
	vr_run 1 "(C3) waiver does NOT suppress findings: high_vulnerabilities still fails" \
		sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_genv" --summary "$_d/f.json" --control-waivers "$_d/cw.json" --output-dir "$_d" --format json
	vr_contains "(C3) the finding gate (high_vulnerabilities) is the failure" \
		"$(jq -c '.failed_gates' "$_d/sentinel-shield-enforcement.json" 2>/dev/null)" "high_vulnerabilities"
	rm -rf "$_d"
}

# run_v2_review — self-test group 'v2-review' (wired into the dispatch + 'all').
run_v2_review() {
	log_info "v2-review: Part D regression matrix + Part C cross-subsystem consistency (override / waivers / bootstrap / planners / gate)"
	vr_override
	vr_waivers
	vr_bootstrap
	vr_planning
	vr_gate
	vr_consistency
	vr_waiver_visibility
	vr_findings_not_suppressed
	if [ "$VR_FAILS" -ne 0 ]; then log_error "v2-review: $VR_FAILS case(s) failed"; return 1; fi
	log_info "v2-review: OK (override no-downgrade + waivers + bootstrap gate/rollback + planners + enforce-gate + cross-subsystem consistency + waiver visibility/non-suppression)"
}

# --- round 3: POSIX waivers, stale runners, quoting/globbing, php/js test split ---
VR3_FAILS=0
v3_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; VR3_FAILS=$((VR3_FAILS + 1)); fi; }
# v3_rc <expected> <desc> -- run last arg as a command (via the CALLER's "$@"); compare exit.
v3_rc() { _exp="$1"; _desc="$2"; shift 2; if "$@" >/dev/null 2>&1; then _g=0; else _g=$?; fi; v3_check "$_desc" "$_g" "$_exp"; }

# Issue 1/2/3: waiver validation portability + version + safe keys (validator run via /bin/sh).
v3_waivers() {
	_w=$(mktemp -d)
	_b='{"version":"1","waivers":[{"tool":"%s","justification":"x","owner":"a","approved_by":"b","created_at":"%s","expires_at":"%s","tracking_issue":"#1"}]}'
	printf "$_b" phpstan 2026-08-09 2026-09-08 > "$_w/p0809.json"
	printf "$_b" phpstan 2028-02-01 2028-02-29 > "$_w/leap.json"
	printf "$_b" phpstan 2026-01-01 2026-02-29 > "$_w/nonleap.json"
	printf "$_b" phpstan 2026-01-01 2026-04-31 > "$_w/apr31.json"
	printf "$_b" phpstan 0000-01-01 2026-01-01 > "$_w/yr0.json"
	echo '{"waivers":[]}' > "$_w/nover.json"; echo '{"version":"2","waivers":[]}' > "$_w/v2.json"
	echo '{"version":"1","waivers":[]}' > "$_w/v1.json"
	printf "$_b" 'phpstan semgrep' 2026-01-01 2099-01-01 > "$_w/space.json"
	printf "$_b" '../phpstan' 2026-01-01 2099-01-01 > "$_w/trav.json"
	printf 'phpstan\tsemgrep' > "$_w/tk"; printf "$_b" "$(cat "$_w/tk")" 2026-01-01 2099-01-01 > "$_w/tab.json"
	# run EXACTLY as the prompt specifies — via /bin/sh, sourcing the lib standalone —
	# but cwd-independent ($ROOT subshell) so the probe (and the lib's relative
	# common-lib lookup) work regardless of where self-test was launched from. `if` so
	# a non-zero exit does not trip the harness's set -e before we print it.
	V(){ if ( cd "$ROOT" && sh -c '. scripts/lib/control-waivers.sh; cw_validate_file "$1"' sh "$1" ) >/dev/null 2>&1; then echo 0; else echo $?; fi; }
	v3_check "(1) /bin/sh validates 2026-08-09/2026-09-08 (no \$((10#..)))" "$(V "$_w/p0809.json")" "0"
	v3_check "(1) /bin/sh accepts leap 2028-02-29" "$(V "$_w/leap.json")" "0"
	v3_check "(1) /bin/sh rejects 2026-02-29" "$(V "$_w/nonleap.json")" "2"
	v3_check "(1) /bin/sh rejects 2026-04-31" "$(V "$_w/apr31.json")" "2"
	v3_check "(1) /bin/sh rejects year 0000" "$(V "$_w/yr0.json")" "2"
	v3_check "(2) missing version -> exit 2" "$(V "$_w/nover.json")" "2"
	v3_check "(2) unsupported version 2 -> exit 2" "$(V "$_w/v2.json")" "2"
	v3_check "(2) version 1 -> valid" "$(V "$_w/v1.json")" "0"
	v3_check "(3) tool key with space -> exit 2" "$(V "$_w/space.json")" "2"
	v3_check "(3) tool key traversal ../ -> exit 2" "$(V "$_w/trav.json")" "2"
	v3_check "(3) tool key with TAB -> exit 2" "$(V "$_w/tab.json")" "2"
	rm -rf "$_w"
}

# Issue 4/5: doctor + maturity validate a malformed waiver fail-closed even without jq on PATH.
v3_nojq_failclosed() {
	_t=$(mktemp -d); mkdir -p "$_t/.sentinel-shield"
	printf '{"version":"1","waivers":[{"tool":"x x"}]}' > "$_t/.sentinel-shield/control-waivers.json"  # malformed (unsafe key + missing fields)
	# shim PATH with no jq (keep sh/printf/etc. from a minimal busybox-like set: easiest is to
	# point PATH at an empty dir + the real coreutils EXCEPT jq — we hide jq via a wrapper dir).
	_bin=$(mktemp -d)
	for _c in sh dirname basename cat printf grep sed awk tr date mktemp rm mkdir jq; do _p=$(command -v "$_c" 2>/dev/null) && ln -s "$_p" "$_bin/$_c" 2>/dev/null; done
	rm -f "$_bin/jq"   # hide jq only
	v3_rc 2 "(4) doctor: malformed waiver + no jq -> exit 2" env PATH="$_bin" sh "$ROOT/scripts/doctor.sh" --target "$_t" --profile laravel
	v3_rc 2 "(5) maturity: malformed waiver + no jq -> exit 2" env PATH="$_bin" sh "$ROOT/scripts/maturity-report.sh" --target "$_t" --profile laravel
	# valid waiver file + jq present => doctor does not fail FOR THE WAIVER (may still exit 3 for
	# missing required tools, which is separate); malformed + jq present => exit 2.
	printf '{"version":"1","waivers":[{"tool":"x x"}]}' > "$_t/.sentinel-shield/control-waivers.json"
	v3_rc 2 "(4) doctor: malformed waiver + jq present -> exit 2" sh "$ROOT/scripts/doctor.sh" --target "$_t" --profile laravel
	rm -rf "$_t" "$_bin"
}

# Issue 7: direct runner invocation clears a stale report when the tool/runtime is absent.
v3_stale_runners() {
	_t=$(mktemp -d); mkdir -p "$_t/reports/raw"; cd "$_t"
	for _r in phpstan:phpstan.json:SENTINEL_SHIELD_PHPSTAN_BIN jest:js-tests.json:SENTINEL_SHIELD_JEST_BIN vitest:js-tests.json:SENTINEL_SHIELD_VITEST_BIN; do
		_name=${_r%%:*}; _rest=${_r#*:}; _rep=${_rest%%:*}; _env=${_rest#*:}
		echo '{"stale":"VALID"}' > "reports/raw/$_rep"
		env "$_env=/nonexistent-bin" sh "$ROOT/scripts/runners/$_name.sh" --output "reports/raw/$_rep" >/dev/null 2>&1
		v3_check "(7) direct $_name: stale report cleared when tool absent" "$([ -f "reports/raw/$_rep" ] && echo present || echo absent)" "absent"
	done
	cd "$ROOT"; rm -rf "$_t"
}

# Issue 8: resolve-workflow-plan handles --target paths with spaces and glob chars.
v3_target_quoting() {
	for _name in 'sp ace' 'glob[1]' 'normal'; do
		_t=$(mktemp -d)/"$_name"; mkdir -p "$_t"
		_out=$(sh "$ROOT/scripts/resolve-workflow-plan.sh" --profile laravel --target "$_t" --stage pr 2>/dev/null | jq -r '.stage' 2>/dev/null)
		v3_check "(8) workflow-plan target '$_name' resolves" "$_out" "pr"
		rm -rf "$(dirname "$_t")"
	done
}

# Issue 9: maturity activation parsing is glob-proof (files named * ? in CWD do not alter columns).
v3_maturity_glob() {
	_t=$(mktemp -d); cd "$_t"; : > '*'; : > '?'
	_out=$(sh "$ROOT/scripts/maturity-report.sh" --format md 2>/dev/null)
	v3_check "(9) maturity output does not leak CWD glob ('*' file)" "$(printf '%s' "$_out" | grep -c "$(basename "$_t")")" "0"
	v3_check "(9) maturity still produces a table" "$(printf '%s' "$_out" | grep -c '^| Tool ')" "1"
	cd "$ROOT"; rm -rf "$_t"
}

# Issue 6: summary-only required-failure count stays numeric (empty REQF_REC + summary count 1).
v3_summary_numeric() {
	_t=$(mktemp -d); mkdir -p "$_t"
	sh "$ROOT/scripts/resolve-gates.sh" --mode baseline --output-dir "$_t" --format env >/dev/null 2>&1
	printf '{"version":"1.0","generated_at":"t","summary":{"secrets":0,"critical_vulnerabilities":0,"high_vulnerabilities":0,"medium_vulnerabilities":0,"architecture_violations":0,"type_errors":0,"test_failures":0,"unsafe_docker":0,"unsafe_github_actions":0,"expired_exceptions":0,"missing_sbom":false,"missing_release_evidence":false,"required_tool_failures":1},"evidence":{"sbom":{"present":true},"release_evidence":{"present":true}},"exceptions":{"active":0,"expired":0}}' > "$_t/s.json"
	if sh "$ROOT/scripts/enforce-gates.sh" --gates-env "$_t/sentinel-shield-gates.env" --summary "$_t/s.json" --output-dir "$_t" --format all >/dev/null 2>&1; then _r=0; else _r=$?; fi
	v3_check "(6) summary-only required_tool_failures=1 -> gate fail (exit 1, no arith error)" "$_r" "1"
	v3_check "(6) enforcement JSON valid" "$(jq -e . "$_t/sentinel-shield-enforcement.json" >/dev/null 2>&1 && echo ok || echo bad)" "ok"
	rm -rf "$_t"
}

# Outside-diff finding: jest/vitest runners must validate the normalized report SHAPE
# ({failures,errors} numbers), not just JSON syntax — a malformed adapter output must
# NOT be published as a clean report.
v3_report_shape() {
	for _r in jest vitest; do
		_t=$(mktemp -d); mkdir -p "$_t/reports/raw" "$_t/fb"; ( cd "$_t" || exit
			# fake runner writes its raw report; fake `node` (the adapter host) writes a
			# WRONG-shape OUTPUT (last arg) — the runner must reject it and leave $OUTPUT absent.
			printf '#!/bin/sh\nfor a in "$@"; do case "$a" in --outputFile=*) echo "{}">${a#--outputFile=};; *=*) : ;; esac; done\n' > fb/"$_r"; chmod +x fb/"$_r"
			printf '#!/bin/sh\n_o=""; for a in "$@"; do _o="$a"; done; printf "{\\"wrong\\":1}" > "$_o"; exit 0\n' > fb/node; chmod +x fb/node
			_env=$(printf 'SENTINEL_SHIELD_%s_BIN' "$(printf '%s' "$_r" | tr a-z A-Z)")
			PATH="$_t/fb:$PATH" env "$_env=$_t/fb/$_r" sh "$ROOT/scripts/runners/$_r.sh" --output reports/raw/js-tests.json >/dev/null 2>&1
		)
		v3_check "(F1) $_r: malformed-shape adapter output is NOT published (report absent)" \
			"$([ -f "$_t/reports/raw/js-tests.json" ] && echo present || echo absent)" "absent"
		rm -rf "$_t"
	done
}

# Issue 11: php-tests and js-tests are INDEPENDENT one-of groups.
v3_test_split() {
	_R="$ROOT/scripts/resolve-effective-profile.sh"
	v3_check "(11) laravel one-of groups = php-tests" "$(sh "$_R" --profile laravel 2>/dev/null | jq -rc '.one_of_groups|keys')" '["php-tests"]'
	v3_check "(11) react one-of groups = js-tests" "$(sh "$_R" --profile react 2>/dev/null | jq -rc '.one_of_groups|keys')" '["js-tests"]'
	v3_check "(11) laravel-react-docker has BOTH php-tests + js-tests" "$(sh "$_R" --profile laravel-react-docker 2>/dev/null | jq -rc '.one_of_groups|keys|sort')" '["js-tests","php-tests"]'
	# satisfaction independence (with --target): pest satisfies php-tests, NOT js-tests; vitest the reverse.
	_t=$(mktemp -d); mkdir -p "$_t/vendor/bin" "$_t/node_modules/.bin"
	printf '#!/bin/sh\n' > "$_t/vendor/bin/pest"; chmod +x "$_t/vendor/bin/pest"
	v3_check "(11) laravel + pest only -> php-tests satisfied" "$(sh "$_R" --profile laravel --target "$_t" 2>/dev/null | jq -r '.one_of_groups["php-tests"].status')" "satisfied"
	v3_check "(11) combined + pest only -> js-tests UNSATISFIED" "$(sh "$_R" --profile laravel-react-docker --target "$_t" 2>/dev/null | jq -r '.one_of_groups["js-tests"].status')" "unsatisfied"
	printf '#!/bin/sh\n' > "$_t/node_modules/.bin/vitest"; chmod +x "$_t/node_modules/.bin/vitest"
	v3_check "(11) react + vitest only -> js-tests satisfied" "$(sh "$_R" --profile react --target "$_t" 2>/dev/null | jq -r '.one_of_groups["js-tests"].status')" "satisfied"
	v3_check "(11) combined + pest+vitest -> php-tests satisfied" "$(sh "$_R" --profile laravel-react-docker --target "$_t" 2>/dev/null | jq -r '.one_of_groups["php-tests"].status')" "satisfied"
	v3_check "(11) combined + pest+vitest -> js-tests satisfied" "$(sh "$_R" --profile laravel-react-docker --target "$_t" 2>/dev/null | jq -r '.one_of_groups["js-tests"].status')" "satisfied"
	# remove BOTH runners: a PHP-only project (pest, no js runner) leaves js-tests unsatisfied.
	rm -f "$_t/vendor/bin/pest" "$_t/node_modules/.bin/vitest"
	printf '#!/bin/sh\n' > "$_t/vendor/bin/pest"; chmod +x "$_t/vendor/bin/pest"
	v3_check "(11) combined + pest but NO js runner -> js-tests unsatisfied" "$(sh "$_R" --profile laravel-react-docker --target "$_t" 2>/dev/null | jq -r '.one_of_groups["js-tests"].status')" "unsatisfied"
	v3_check "(11) combined + pest but NO js runner -> php-tests satisfied" "$(sh "$_R" --profile laravel-react-docker --target "$_t" 2>/dev/null | jq -r '.one_of_groups["php-tests"].status')" "satisfied"
	rm -rf "$_t"
}

# Batch-4 review fixes: schema guards, disabled-tool plan exclusion, doctor jq
# fail-closed, combination manifest resolution, runner read-only flags.
v3_batch4() {
	_R="$ROOT/scripts/resolve-effective-profile.sh"
	# schema: policy=one-of REQUIRES a non-empty alternatives array (if check-jsonschema present).
	if command_exists check-jsonschema; then
		_sd=$(mktemp -d)
		printf '{"profile":"x","tool_policy_version":2,"files":[],"tools":{"t":{"policy":"one-of"}}}' > "$_sd/bad.json"
		check-jsonschema --schemafile "$ROOT/profiles/profile.manifest.schema.json" "$_sd/bad.json" >/dev/null 2>&1 && _r=0 || _r=1
		v3_check "(schema) one-of without alternatives -> rejected" "$_r" "1"
		printf '{"profile":"x","tool_policy_version":9,"files":[]}' > "$_sd/badv.json"
		check-jsonschema --schemafile "$ROOT/profiles/profile.manifest.schema.json" "$_sd/badv.json" >/dev/null 2>&1 && _r=0 || _r=1
		v3_check "(schema) tool_policy_version 9 -> rejected (const 2)" "$_r" "1"
		rm -rf "$_sd"
	else
		log_warn "(schema) check-jsonschema absent; SKIPPING schema-guard cases (jq-validity only)"
	fi
	# compat-resolver: cr_manifest_path resolves a combination profile.
	v3_check "(compat) cr_manifest_path resolves combination" \
		"$( ( cd "$ROOT" && sh -c '. scripts/lib/sentinel-shield-common.sh; . scripts/lib/compat-resolver.sh; cr_manifest_path "$(pwd)" laravel-react-docker' ) 2>/dev/null | grep -c 'combinations/laravel-react-docker.manifest.json')" "1"
	# resolve-tool-plan: a tool disabled via installation.json is reported 'disabled', not installable.
	_dt=$(mktemp -d); mkdir -p "$_dt/.sentinel-shield"; printf '{"disabled_tools":["rector"]}' > "$_dt/.sentinel-shield/installation.json"
	v3_check "(resolve-tool-plan) disabled tool -> decision=disabled" \
		"$(sh "$ROOT/scripts/resolve-tool-plan.sh" --profile laravel --target "$_dt" --format json 2>/dev/null | jq -r '.tools.rector.decision // "absent"')" "disabled"
	rm -rf "$_dt"
	# doctor: jq absent + require-existing -> exit 3 (fail closed); config-only -> not 3.
	_nb=$(mktemp -d); for _c in sh dirname basename cat printf grep sed awk tr date mktemp rm mkdir; do _p=$(command -v "$_c" 2>/dev/null) && ln -s "$_p" "$_nb/$_c" 2>/dev/null; done
	_dd=$(mktemp -d)
	if env PATH="$_nb" sh "$ROOT/scripts/doctor.sh" --target "$_dd" --profile laravel --tool-mode require-existing >/dev/null 2>&1; then _r=0; else _r=$?; fi
	v3_check "(doctor) jq absent + require-existing -> exit 3 (fail closed)" "$_r" "3"
	rm -rf "$_nb" "$_dd"
	# runners: read-only cache flags present.
	v3_check "(php-cs-fixer) invokes with --using-cache=no (read-only)" \
		"$(grep -E '"\$FIXER_BIN".*--using-cache=no' "$ROOT/scripts/runners/php-cs-fixer.sh" >/dev/null && echo yes || echo no)" "yes"
	v3_check "(phpunit) invokes with --do-not-cache-result (read-only)" \
		"$(grep -E '"\$PHPUNIT_BIN".*--do-not-cache-result' "$ROOT/scripts/runners/phpunit.sh" >/dev/null && echo yes || echo no)" "yes"
	v3_check "(npm-audit) differentiates Yarn classic vs berry" "$(grep -c '1\.\*)' "$ROOT/scripts/runners/npm-audit.sh")" "1"
}

# run_v2_review_round3 — self-test group 'v2-review-round3' (wired into the dispatch + 'all').
run_v2_review_round3() {
	log_info "v2-review-round3: POSIX waivers + version/keys + fail-closed validation + stale runners + quoting/globbing + php/js test split"
	v3_waivers
	v3_nojq_failclosed
	v3_stale_runners
	v3_target_quoting
	v3_maturity_glob
	v3_summary_numeric
	v3_report_shape
	v3_test_split
	v3_batch4
	if [ "$VR3_FAILS" -ne 0 ]; then log_error "v2-review-round3: $VR3_FAILS case(s) failed"; return 1; fi
	log_info "v2-review-round3: OK (portable waivers + safe keys + fail-closed + stale-runner + quoting + glob-proof + php/js test split)"
}

# --- e2e: run the LOCAL end-to-end harness (policy->gate over tests/e2e/) -----
run_e2e() {
	log_info "e2e: LOCAL end-to-end harness (scripts/e2e-harness.sh) — proves the full policy->gate path"
	sh "$ROOT/scripts/e2e-harness.sh" || { log_error "e2e: harness reported a broken fixture path"; return 1; }
	log_info "e2e: OK (local-harness; not a real CI run)"
}

# --- production-readiness: run every standalone tests/prod/*.sh suite --------
run_production_readiness() {
	log_info "production-readiness: running standalone tests/prod/*.sh suites"
	_prr_total=0
	_prr_fail=0
	for f in "$ROOT"/tests/prod/*.sh; do
		[ -e "$f" ] || continue
		_prr_total=$((_prr_total + 1))
		if sh "$f"; then
			log_info "production-readiness: PASS ${f#"$ROOT"/}"
		else
			_prr_fail=$((_prr_fail + 1))
			log_error "production-readiness: FAIL ${f#"$ROOT"/}"
		fi
	done
	if [ "$_prr_total" -eq 0 ]; then
		log_error "production-readiness: no tests/prod/*.sh suites found"
		return 1
	fi
	if [ "$_prr_fail" -ne 0 ]; then
		log_error "production-readiness: $_prr_fail of $_prr_total suite(s) failed"
		return 1
	fi
	log_info "production-readiness: OK ($_prr_total/$_prr_total suites passed)"
}

case "$SUB" in
	syntax) run_syntax ;;
	lifecycle) run_lifecycle ;;
	fallback) run_fallback ;;
	negative) run_negative ;;
	suppression) run_suppression ;;
	finding-scope) run_finding_scope ;;
	third-party) run_third_party ;;
	hadolint) run_hadolint ;;
	adapters) run_adapters ;;
	phpstan-runner) run_phpstan_runner ;;
	ud-multisource) run_ud_multisource ;;
	install-sync) run_install_sync ;;
	scanner-matrix) run_scanner_matrix ;;
	fixtures) run_fixtures ;;
	workflow-sanity) run_workflow_sanity ;;
	feature-completion) run_feature_completion ;;
	main-gate-harness) run_main_gate_harness ;;
	main-gate-evidence) run_main_gate_evidence ;;
	main-gate-exec) run_main_gate_exec ;;
	install-matrix) run_install_matrix ;;
	mode-readiness) run_mode_readiness ;;
	v022-fixtures) run_v022_fixtures ;;
	v023-coverage) run_v023_coverage ;;
	v023-regression) run_v023_regression ;;
	v024-collectors) run_v024_collectors ;;
	v024-coverage) run_v024_coverage ;;
	v024-docs) run_v024_docs ;;
	v025-live) run_v025_live ;;
	v026-live) run_v026_dependency_check ;;
	v027-live) run_v027_consumer_evidence ;;
	v028-live) run_v028_strict_ci_and_breadth ;;
	v029-live) run_v029_clean_strict_ci ;;
	v030-live) run_v030_dc_ci_cache ;;
	rc1-soak) run_v100rc_soak ;;
	v110-postga) run_v110_postga ;;
	v120-docs) run_v120_docs ;;
	v130-evidence) run_v130_evidence ;;
	v140-iac) run_v140_iac ;;
	v150-evidence) run_v150_evidence ;;
	v160-iac) run_v160_iac ;;
	v170-platform) run_v170_platform ;;
	v180-completion) run_v180_completion ;;
	v190-ai-install) run_v190_ai_install ;;
	v2-toolpolicy) run_v2_toolpolicy ;;
	v2-enforcement) run_v2_enforcement ;;
	v2-review) run_v2_review ;;
	v2-review-round3) run_v2_review_round3 ;;
	e2e) run_e2e ;;
	production-readiness) run_production_readiness ;;
	all)
		run_syntax
		run_lifecycle
		run_fallback
		run_negative
		run_suppression
		run_finding_scope
		run_third_party
		run_hadolint
		run_adapters
		run_phpstan_runner
		run_ud_multisource
		run_install_sync
		run_scanner_matrix
		run_fixtures
		run_workflow_sanity
		run_feature_completion
		run_main_gate_harness
		run_main_gate_evidence
		run_main_gate_exec
		run_install_matrix
		run_mode_readiness
		run_v022_fixtures
		run_v023_coverage
		run_v023_regression
		run_v024_collectors
		run_v024_coverage
		run_v024_docs
		run_v025_live
		run_v026_dependency_check
		run_v027_consumer_evidence
		run_v028_strict_ci_and_breadth
		run_v029_clean_strict_ci
		run_v030_dc_ci_cache
		run_v100rc_soak
		run_v110_postga
		run_v120_docs
		run_v130_evidence
		run_v140_iac
		run_v150_evidence
		run_v160_iac
		run_v170_platform
		run_v180_completion
		run_v190_ai_install
		run_v2_toolpolicy
		run_v2_enforcement
		run_v2_review
		run_v2_review_round3
		run_e2e
		run_production_readiness
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|install-matrix|mode-readiness|v022-fixtures|v023-coverage|v023-regression|v024-collectors|v024-coverage|v024-docs|v025-live|v026-live|v027-live|v028-live|v029-live|v030-live|rc1-soak|v110-postga|v120-docs|v130-evidence|v140-iac|v150-evidence|v160-iac|v170-platform|v180-completion|v190-ai-install|v2-toolpolicy|v2-enforcement|v2-review|v2-review-round3|e2e|production-readiness|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|install-matrix|mode-readiness|v022-fixtures|v023-coverage|v023-regression|v024-collectors|v024-coverage|v024-docs|v025-live|v026-live|v027-live|v028-live|v029-live|v030-live|rc1-soak|v110-postga|v120-docs|v130-evidence|v140-iac|v150-evidence|v160-iac|v170-platform|v180-completion|v190-ai-install|v2-toolpolicy|v2-enforcement|v2-review|v2-review-round3|e2e|production-readiness|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
