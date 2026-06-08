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
		;;
	-h | --help)
		echo "Usage: self-test.sh [syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|all]"
		exit 0
		;;
	*)
		log_error "unknown subcommand: $SUB (expected syntax|lifecycle|fallback|negative|suppression|finding-scope|third-party|hadolint|adapters|phpstan-runner|ud-multisource|install-sync|all)"
		exit 2
		;;
esac

log_info "self-test '$SUB': PASS"
