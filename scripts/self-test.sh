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

case "$SUB" in
	syntax) run_syntax ;;
	lifecycle) run_lifecycle ;;
	fallback) run_fallback ;;
	negative) run_negative ;;
	all)
		run_syntax
		run_lifecycle
		run_fallback
		run_negative
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
