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
	_out=$( cd "$_empty" && sh "$_rh" --list ); _rc=$?
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
	printf 'on: [push]\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4\n      - uses: ./.github/actions/x\n' > "$_d/wf/good.yml"
	sh scripts/audit-github-actions-pins.sh --output "$_d/ghbad.json" "$_d/wf/bad.yml" >/dev/null 2>&1
	ad_check "GH pin audit flags tag/branch/container refs" "$(jq 'length' "$_d/ghbad.json" 2>/dev/null)" "3"
	sh scripts/audit-github-actions-pins.sh --output "$_d/ghgood.json" "$_d/wf/good.yml" >/dev/null 2>&1
	ad_check "GH pin audit passes SHA + local refs" "$(jq 'length' "$_d/ghgood.json" 2>/dev/null)" "0"
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
	_dr=$(sh scripts/sync-baseline.sh --target "$_t" 2>/dev/null | grep -c 'manual-review-needed (managed drift')
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
	echo '[{"Verified":true},{"Verified":false}]' > "$_r/trufflehog.json"
	sm_check "trufflehog -> secrets (verified only)" "$(sh "$C/trufflehog.sh" --input "$_r/trufflehog.json" | jq '.summary.secrets')" "1"
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

run_workflow_sanity() {
	log_info "workflow-sanity: no pull_request_target trigger, permissions present, DAST allowlist, AI non-gating"
	WF_GH="$ROOT/github/workflows"; WF_TPL="$ROOT/templates/workflows"

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

	if [ "$WS_FAILS" -ne 0 ]; then log_error "workflow-sanity: $WS_FAILS case(s) failed"; return 1; fi
	log_info "workflow-sanity: OK (no PRT trigger, permissions present, DAST allowlisted, AI non-gating)"
}

# --- feature completion (v0.1.14) -------------------------------------------
FC_FAILS=0
fc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; FC_FAILS=$((FC_FAILS + 1)); fi; }

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
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
