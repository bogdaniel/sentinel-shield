#!/bin/sh
# Sentinel Shield — self-test harness.
#
# Exercises the core enforcement lifecycle against fixture data so Sentinel Shield
# continuously tests ITSELF (YAML validity alone does not prove behavior). Used by
# github/workflows/ci-self-test.yml and runnable locally.
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
	log_info "syntax: sh -n over scripts"
	for f in scripts/*.sh scripts/lib/*.sh scripts/collectors/*.sh; do
		sh -n "$f" || { log_error "sh -n failed: $f"; return 1; }
	done
	log_info "syntax: jq-validate templates/ and schemas/ JSON"
	for f in $(find templates schemas -name '*.json' 2>/dev/null); do
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
	_wf="github/workflows/ci-security.yml github/workflows/ci-pipeline.yml examples/laravel-react-docker/.github/workflows/sentinel-shield.yml"
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

run_suppression() {
	log_info "suppression: accepted-risk gate suppression (unsafe_docker)"
	_ad='.summary.unsafe_docker = 1'
	_valid='{"version":"1.0","risks":[{"id":"d","gate":"unsafe_docker","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2999-12-31","status":"approved"}]}'
	_pending='{"version":"1.0","risks":[{"id":"d","gate":"unsafe_docker","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2999-12-31","status":"pending"}]}'
	_expired='{"version":"1.0","risks":[{"id":"d","gate":"unsafe_docker","owner":"plat","severity":"medium","reason":"hygiene","expires_at":"2000-01-01","status":"approved"}]}'
	_secret='{"version":"1.0","risks":[{"id":"s","gate":"secrets","owner":"plat","severity":"high","reason":"x","expires_at":"2999-12-31","status":"approved"}]}'

	run_suppression_case "baseline + unsafe_docker=1 + no accepted risk -> fail"        baseline 1 "$_ad" '{"version":"1.0","risks":[]}'
	run_suppression_case "baseline + unsafe_docker=1 + pending risk -> fail"            baseline 1 "$_ad" "$_pending"
	run_suppression_case "baseline + unsafe_docker=1 + expired approved risk -> fail"   baseline 1 "$_ad" "$_expired"
	run_suppression_case "baseline + unsafe_docker=1 + valid approved risk -> pass"     baseline 0 "$_ad" "$_valid"
	run_suppression_case "baseline + secrets=1 + approved risk for secrets -> fail"     baseline 1 '.summary.secrets = 1' "$_secret"

	if [ "$SUP_FAILS" -ne 0 ]; then
		log_error "suppression: $SUP_FAILS case(s) failed"
		return 1
	fi
	log_info "suppression: OK (only approved/unexpired suppress; secrets never)"
}

# --- third-party supply-chain scan ------------------------------------------
TP_FAILS=0
tp_check() { # tp_check <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2', expected '$3')"; TP_FAILS=$((TP_FAILS + 1)); fi
}

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

case "$SUB" in
	syntax) run_syntax ;;
	lifecycle) run_lifecycle ;;
	fallback) run_fallback ;;
	negative) run_negative ;;
	suppression) run_suppression ;;
	third-party) run_third_party ;;
	all)
		run_syntax
		run_lifecycle
		run_fallback
		run_negative
		run_suppression
		run_third_party
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|suppression|third-party|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|suppression|third-party|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
