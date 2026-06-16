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

# --- install-matrix (v0.1.22): round-trip docker-only / php-library / node-react -----------
IM_FAILS=0
im_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; IM_FAILS=$((IM_FAILS + 1)); fi; }
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
	cl_check "trufflehog fixture -> secrets (verified only)" "$([ "$(sh "$C/trufflehog.sh" --input "$LIB/trufflehog.json" 2>/dev/null | jq '.summary.secrets')" -ge 1 ] && echo yes || echo no)" "yes"
	if [ "$CL_FAILS" -ne 0 ]; then log_error "v024-collectors: $CL_FAILS case(s) failed"; return 1; fi
	log_info "v024-collectors: OK (complete collector fixture library iterated; normalized output verified)"
}

# --- v024-coverage: dep-check hardening, modes-v024, IaC/deptrac/arch v024, DAST, workflow ----
VC_FAILS=0
vc_check() { if [ "$2" = "$3" ]; then log_info "PASS: $1 ($2)"; else log_error "FAIL: $1 (got '$2' exp '$3')"; VC_FAILS=$((VC_FAILS + 1)); fi; }
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
		_ups=$(grep -c 'uses: actions/upload-artifact' "$_wf" 2>/dev/null || echo 0)
		_alw=$(grep -c 'if: always()' "$_wf" 2>/dev/null || echo 0)
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

run_v029_clean_strict_ci() {
	log_info "v029: clean strict CI — override precedence, evidence isolation, DC propertyfile container-readable"
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

	# (60) DC propertyfile is container-readable (the v029 fix) AND key never echoed (no set -x).
	cs_check "(60) audit makes propertyfile container-readable (chmod 644)" "$([ "$(grep -c 'chmod 644' "$A")" -ge 1 ] && echo yes || echo no)" "yes"
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
	# (54) container-readable propertyfile perms in the script.
	cc_check "(54) propertyfile is container-readable (chmod 644)" "$([ "$(grep -c 'chmod 644' "$A")" -ge 1 ] && echo yes || echo no)" "yes"

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
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|install-matrix|mode-readiness|v022-fixtures|v023-coverage|v023-regression|v024-collectors|v024-coverage|v024-docs|v025-live|v026-live|v027-live|v028-live|v029-live|v030-live|rc1-soak|v110-postga|v120-docs|v130-evidence|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|scanner-matrix|fixtures|workflow-sanity|feature-completion|main-gate-harness|main-gate-evidence|main-gate-exec|install-matrix|mode-readiness|v022-fixtures|v023-coverage|v023-regression|v024-collectors|v024-coverage|v024-docs|v025-live|v026-live|v027-live|v028-live|v029-live|v030-live|rc1-soak|v110-postga|v120-docs|v130-evidence|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
