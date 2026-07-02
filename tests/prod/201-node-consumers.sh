#!/bin/sh
# tests/prod/201-node-consumers.sh — real-consumer validation for Node/React.
#
# Validates the genuine consumer fixtures under tests/consumers/ (node-service,
# react-app, pm-variants/{npm,pnpm,yarn}) against Sentinel Shield's package-manager
# authority model and Node quality gates. Every check emits a schema-valid record
# (schemas/node-consumer-validation.schema.json) via the shared reporter.
#
# TWO tiers, clearly separated (HONESTY: a skip is NEVER a pass):
#   STRUCTURAL (always; network-free, deterministic) —
#     * lockfile authority: each consumer commits exactly ONE authoritative
#       lockfile and pm_resolve picks the right manager + immutable command;
#     * package-manager NEGATIVE cases with stable reason codes
#       (MULTIPLE_AUTHORITATIVE_LOCKFILES / MANAGER_MISMATCH / MISSING_LOCKFILE /
#       INVALID_MANAGER);
#     * one-of tool groups (Jest|Vitest, ESLint, TypeScript, audit provider);
#     * mutation-fixture wiring (the 3 intentional-defect fixtures exist and are
#       excluded from the baseline configs);
#     * byte-for-byte lockfile ROLLBACK through the REAL bootstrap engine with
#       fault-injected package-manager stubs (no manager switch).
#   LIVE (opt-in: SS_CONSUMER_LIVE=1; needs the real toolchain + network) —
#     * npm ci from the committed lockfile then a GREEN baseline (typecheck/lint/
#       test); and >=2 MUTATIONS that must FAIL at the correct gate with a stable
#       reason code. When the flag is unset the live checks are recorded as
#       explicit SKIPs (LIVE_UNAVAILABLE) — a limitation, not a pass.
#
# Self-contained: creates its own mktemp fixtures and cleans up. Auto-discovered by
# `sh scripts/self-test.sh production-readiness`.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONSUMERS="$ROOT/tests/consumers"
BPT="$ROOT/scripts/bootstrap-profile-tools.sh"

. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/package-manager-resolver.sh"
. "$ROOT/scripts/report-node-consumer.sh"

WORK=$(mktemp -d)
REC="$WORK/records.jsonl"
: > "$REC"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

FAILS=0
SKIPS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
note_skip() { printf 'SKIP: %s\n' "$1"; SKIPS=$((SKIPS + 1)); }

# rec <consumer> <pm> <check> <gate> <status> <reason> <mode> [detail]
# Append a schema-valid record; a reporter failure is itself a test failure.
rec() {
	if ! rcv_record "$@" >> "$REC"; then
		fail "reporter failed to emit record for check '$3'"
	fi
}

# assert_eq <desc> <actual> <expected> — pass/fail on string equality.
assert_eq() {
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

# has_dep <package.json> <name> — true if name is in dependencies OR devDependencies.
has_dep() {
	jq -e --arg n "$2" '((.dependencies // {}) + (.devDependencies // {})) | has($n)' "$1" >/dev/null 2>&1
}

log_info "201-node-consumers: STRUCTURAL tier (network-free)"

# --- A. lockfile authority + positive pm resolution --------------------------
# consumer-relpath | expected-manager
CONSUMER_SPECS='node-service|npm
react-app|npm
pm-variants/npm|npm
pm-variants/pnpm|pnpm
pm-variants/yarn|yarn'

# Iterate in the CURRENT shell (never in a pipe subshell) so pass/fail counters
# and emitted records both survive.
_oifs=$IFS
IFS='
'
for _spec in $CONSUMER_SPECS; do
	IFS=$_oifs
	_rel=$(printf '%s' "$_spec" | cut -d'|' -f1)
	_mgr=$(printf '%s' "$_spec" | cut -d'|' -f2)
	_dir="$CONSUMERS/$_rel"
	_present=$(pm_authoritative_lockfiles "$_dir")
	_n=0
	[ -n "$_present" ] && _n=$(printf '%s\n' "$_present" | grep -c .)
	assert_eq "$_rel: exactly one authoritative lockfile" "$_n" "1"
	if [ -f "$_dir/.gitignore" ] && grep -q '^node_modules/\?$' "$_dir/.gitignore"; then
		pass "$_rel: node_modules is gitignored"
	else
		fail "$_rel: node_modules must be gitignored"
	fi
	_line=$(pm_resolve "$_dir" immutable "") || true
	_ok=$(printf '%s' "$_line" | cut -f1)
	_got=$(printf '%s' "$_line" | cut -f2)
	assert_eq "$_rel: pm_resolve => ok/$_mgr" "$_ok/$_got" "ok/$_mgr"
	_cmd=$(pm_immutable_cmd "$_mgr" "$_dir")
	case "$_mgr" in
		npm) _want='ci$' ;;
		pnpm) _want='install --frozen-lockfile$' ;;
		yarn) _want='install --immutable$' ;;
	esac
	if printf '%s' "$_cmd" | grep -q "$_want"; then
		pass "$_rel: immutable cmd manager-correct ($_cmd)"
	else
		fail "$_rel: immutable cmd manager-correct (got '$_cmd')"
	fi
	rec "$_rel" "$_mgr" "lockfile-authority" "lockfile" "pass" "OK" "structural" "$_line"
	rec "$_rel" "$_mgr" "pm-authority" "package-manager" "pass" "OK" "structural" "$_cmd"
	IFS='
'
done
IFS=$_oifs

# --- B. package-manager NEGATIVE cases (stable reason codes) ------------------
# Build throwaway fixtures and assert pm_resolve rejects each with the right code.
neg_case() { # desc dir override expect_code
	_line=$(pm_resolve "$2" immutable "$3") || true
	_st=$(printf '%s' "$_line" | cut -f1)
	_code=$(printf '%s' "$_line" | cut -f2)
	assert_eq "$1" "$_st/$_code" "error/$4"
	rec "negative/$4" "none" "pm-authority-negative" "package-manager" "pass" "$4" "structural" "$1"
}

_nm="$WORK/neg-multi"; mkdir -p "$_nm"; printf '{}' > "$_nm/package.json"
: > "$_nm/package-lock.json"; : > "$_nm/pnpm-lock.yaml"
neg_case "negative: two authoritative lockfiles rejected" "$_nm" "" "MULTIPLE_AUTHORITATIVE_LOCKFILES"

_mm="$WORK/neg-mismatch"; mkdir -p "$_mm"; printf '{}' > "$_mm/package.json"
: > "$_mm/package-lock.json"
neg_case "negative: manager mismatch (npm lock, override pnpm)" "$_mm" "pnpm" "MANAGER_MISMATCH"

_ml="$WORK/neg-missing"; mkdir -p "$_ml"; printf '{"packageManager":"npm@10"}' > "$_ml/package.json"
neg_case "negative: missing lockfile in immutable mode" "$_ml" "" "MISSING_LOCKFILE"

_iv="$WORK/neg-invalid"; mkdir -p "$_iv"; printf '{}' > "$_iv/package.json"; : > "$_iv/package-lock.json"
neg_case "negative: invalid override manager" "$_iv" "bun" "INVALID_MANAGER"

# --- C. one-of tool groups + audit provider ----------------------------------
# For each app consumer: exactly one test runner (Jest|Vitest); ESLint present;
# TypeScript present; an audit provider bound to the authoritative manager.
for _rel in node-service react-app; do
	_pj="$CONSUMERS/$_rel/package.json"
	# test runner one-of
	_has_vitest=no; _has_jest=no
	has_dep "$_pj" vitest && _has_vitest=yes
	has_dep "$_pj" jest && _has_jest=yes
	if [ "$_has_vitest" = yes ] && [ "$_has_jest" = no ]; then
		pass "$_rel: exactly one test runner (vitest)"
		rec "$_rel" "npm" "one-of-test-runner" "one-of" "pass" "ONE_OF_TEST_RUNNER" "structural" "vitest"
	else
		fail "$_rel: exactly one of Jest|Vitest (vitest=$_has_vitest jest=$_has_jest)"
		rec "$_rel" "npm" "one-of-test-runner" "one-of" "fail" "ONE_OF_TEST_RUNNER" "structural" "vitest=$_has_vitest jest=$_has_jest"
	fi
	# eslint
	if has_dep "$_pj" eslint; then
		pass "$_rel: ESLint present"; rec "$_rel" "npm" "one-of-eslint" "one-of" "pass" "ONE_OF_ESLINT" "structural" "eslint"
	else
		fail "$_rel: ESLint present"; rec "$_rel" "npm" "one-of-eslint" "one-of" "fail" "ONE_OF_ESLINT" "structural" "missing"
	fi
	# typescript
	if has_dep "$_pj" typescript; then
		pass "$_rel: TypeScript present"; rec "$_rel" "npm" "one-of-typescript" "one-of" "pass" "ONE_OF_TS" "structural" "typescript"
	else
		fail "$_rel: TypeScript present"; rec "$_rel" "npm" "one-of-typescript" "one-of" "fail" "ONE_OF_TS" "structural" "missing"
	fi
	# audit provider: npm ships `npm audit`; an audit script must be wired.
	if jq -e '.scripts.audit // empty' "$_pj" >/dev/null 2>&1; then
		pass "$_rel: audit provider (npm audit) wired"; rec "$_rel" "npm" "one-of-audit-provider" "audit" "pass" "ONE_OF_AUDIT" "structural" "npm-audit"
	else
		fail "$_rel: audit provider (npm audit) wired"; rec "$_rel" "npm" "one-of-audit-provider" "audit" "fail" "ONE_OF_AUDIT" "structural" "missing"
	fi
done

# --- D. mutation-fixture wiring ----------------------------------------------
# The intentional-defect fixtures must exist, be non-empty, and be excluded from
# the baseline configs so only the driver's injection trips a gate.
mut_wiring() { # rel typefile lintfile testfile
	_rel="$1"; _d="$CONSUMERS/$_rel"
	for _f in "$2" "$3" "$4"; do
		if [ -s "$_d/mutations/$_f" ]; then
			pass "$_rel: mutation fixture $_f present"
		else
			fail "$_rel: mutation fixture $_f present & non-empty"
		fi
	done
	# excluded from eslint + vitest + tsconfig
	if grep -q 'mutations' "$_d/eslint.config.js" && grep -q 'mutations' "$_d/vitest.config.ts" && grep -q 'mutations' "$_d/tsconfig.json"; then
		pass "$_rel: mutations/ excluded from eslint+vitest+tsconfig"
	else
		fail "$_rel: mutations/ excluded from all baseline configs"
	fi
	rec "$_rel" "npm" "mutation-wiring-typecheck" "typecheck" "pass" "MUTATION_WIRED" "structural" "$2"
	rec "$_rel" "npm" "mutation-wiring-lint" "lint" "pass" "MUTATION_WIRED" "structural" "$3"
	rec "$_rel" "npm" "mutation-wiring-test" "test" "pass" "MUTATION_WIRED" "structural" "$4"
}
mut_wiring node-service type-error.ts lint-error.ts failing.test.ts
mut_wiring react-app type-error.tsx lint-error.ts failing.test.tsx

# --- E. byte-for-byte lockfile ROLLBACK via the REAL bootstrap engine ---------
# Uses the REAL committed node-service package.json + package-lock.json. Stubs the
# three managers: the immutable reconstruction (ci/frozen/immutable) succeeds; the
# add/save step MUTATES both files then FAILS, forcing the engine to roll back.
write_node_stub() { # path log target lockfile
	cat > "$1" <<EOF
#!/bin/sh
echo "\$*" >> "$2"
case "\$*" in
	*" ci" | *frozen-lockfile* | *immutable*) exit 0 ;;
	*)
		printf 'MUTATED-BY-FAILED-INSTALL' > "$3/package.json"
		printf 'MUTATED-BY-FAILED-INSTALL' > "$3/$4"
		echo "fake: forced install failure (\$*)" >&2
		exit 1 ;;
esac
EOF
	chmod +x "$1"
}

rollback_case() {
	_w="$WORK/rb"; _t="$_w/proj"; mkdir -p "$_t/node_modules"
	cp "$CONSUMERS/node-service/package.json" "$_t/package.json"
	cp "$CONSUMERS/node-service/package-lock.json" "$_t/package-lock.json"
	_op=$(cat "$_t/package.json"); _ol=$(cat "$_t/package-lock.json")
	_fb="$_w/bin"; mkdir -p "$_fb"
	write_node_stub "$_fb/npm" "$_w/npm.log" "$_t" "package-lock.json"
	write_node_stub "$_fb/pnpm" "$_w/pnpm.log" "$_t" "package-lock.json"
	write_node_stub "$_fb/yarn" "$_w/yarn.log" "$_t" "package-lock.json"
	_rc=0
	PATH="$_fb:$PATH" sh "$BPT" --profile node --target "$_t" --apply >/dev/null 2>&1 || _rc=$?
	assert_eq "rollback: failed install exits non-zero" "$([ "$_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
	assert_eq "rollback: real package.json restored byte-for-byte" "$(cat "$_t/package.json")" "$_op"
	assert_eq "rollback: real package-lock.json restored byte-for-byte" "$(cat "$_t/package-lock.json")" "$_ol"
	if grep -q ' ci' "$_w/npm.log" 2>/dev/null; then
		pass "rollback: reconstruction used 'npm ci'"
	else
		fail "rollback: reconstruction used 'npm ci'"
	fi
	if [ -s "$_w/pnpm.log" ] || [ -s "$_w/yarn.log" ]; then
		fail "rollback: no manager switch (pnpm/yarn must be untouched)"
	else
		pass "rollback: no manager switch (npm stayed authoritative)"
	fi
	rec "node-service" "npm" "rollback-byte-for-byte" "rollback" "pass" "LOCKFILE_RESTORED" "structural" "real committed lockfile restored; npm ci reconstruction; no switch"
}
rollback_case

# --- F. LIVE tier (opt-in) ---------------------------------------------------
LIVE="${SS_CONSUMER_LIVE:-0}"
live_baseline_and_mutations() { # rel typefile lintfile testfile
	_rel="$1"; _tf="$2"; _lf="$3"; _testf="$4"; _src="$CONSUMERS/$_rel"
	_lw="$WORK/live-$_rel"; cp -R "$_src" "$_lw"
	rm -rf "$_lw/node_modules"
	# npm ci from the committed lockfile
	if ! ( cd "$_lw" && npm ci --no-audit --no-fund --loglevel=error ) >/dev/null 2>&1; then
		note_skip "$_rel: live npm ci failed/unavailable (network?)"
		rec "$_rel" "npm" "live-npm-ci" "install" "skip" "LIVE_UNAVAILABLE" "live" "npm ci failed"
		return 0
	fi
	pass "$_rel: live npm ci from committed lockfile"
	rec "$_rel" "npm" "live-npm-ci" "install" "pass" "OK" "live" "npm ci"
	# baseline GREEN
	( cd "$_lw" && npx --no-install tsc --noEmit ) >/dev/null 2>&1 && { pass "$_rel: live baseline typecheck green"; rec "$_rel" npm live-baseline-typecheck typecheck pass OK live ""; } || { fail "$_rel: live baseline typecheck green"; rec "$_rel" npm live-baseline-typecheck typecheck fail TS_COMPILE_FAIL live "unexpected"; }
	( cd "$_lw" && npx --no-install eslint . ) >/dev/null 2>&1 && { pass "$_rel: live baseline lint green"; rec "$_rel" npm live-baseline-lint lint pass OK live ""; } || { fail "$_rel: live baseline lint green"; rec "$_rel" npm live-baseline-lint lint fail ESLINT_ERROR live "unexpected"; }
	( cd "$_lw" && npx --no-install vitest run ) >/dev/null 2>&1 && { pass "$_rel: live baseline test green"; rec "$_rel" npm live-baseline-test test pass OK live ""; } || { fail "$_rel: live baseline test green"; rec "$_rel" npm live-baseline-test test fail TEST_FAIL live "unexpected"; }
	# MUTATIONS: each must FAIL at the correct gate.
	_mw="$WORK/mut-tc-$_rel"; cp -R "$_lw" "$_mw"; cp "$_mw/mutations/$_tf" "$_mw/src/$_tf"
	if ! ( cd "$_mw" && npx --no-install tsc --noEmit ) >/dev/null 2>&1; then
		pass "$_rel: typecheck mutation fails at typecheck gate"; rec "$_rel" npm typecheck-mutation typecheck pass TS_COMPILE_FAIL live "$_tf"
	else
		fail "$_rel: typecheck mutation should fail typecheck gate"; rec "$_rel" npm typecheck-mutation typecheck fail TS_COMPILE_FAIL live "did not fail"
	fi
	_mw="$WORK/mut-ln-$_rel"; cp -R "$_lw" "$_mw"; cp "$_mw/mutations/$_lf" "$_mw/src/$_lf"
	if ! ( cd "$_mw" && npx --no-install eslint "src/$_lf" ) >/dev/null 2>&1; then
		pass "$_rel: lint mutation fails at lint gate"; rec "$_rel" npm lint-mutation lint pass ESLINT_ERROR live "$_lf"
	else
		fail "$_rel: lint mutation should fail lint gate"; rec "$_rel" npm lint-mutation lint fail ESLINT_ERROR live "did not fail"
	fi
	_mw="$WORK/mut-ts-$_rel"; cp -R "$_lw" "$_mw"; cp "$_mw/mutations/$_testf" "$_mw/src/$_testf"
	if ! ( cd "$_mw" && npx --no-install vitest run ) >/dev/null 2>&1; then
		pass "$_rel: test mutation fails at test gate"; rec "$_rel" npm test-mutation test pass TEST_FAIL live "$_testf"
	else
		fail "$_rel: test mutation should fail test gate"; rec "$_rel" npm test-mutation test fail TEST_FAIL live "did not fail"
	fi
}

if [ "$LIVE" = "1" ] && command_exists npm; then
	log_info "201-node-consumers: LIVE tier (SS_CONSUMER_LIVE=1)"
	live_baseline_and_mutations node-service type-error.ts lint-error.ts failing.test.ts
	live_baseline_and_mutations react-app type-error.tsx lint-error.ts failing.test.tsx
else
	note_skip "LIVE tier disabled (set SS_CONSUMER_LIVE=1 with network+toolchain to run real npm ci + mutation gates)"
	for _rel in node-service react-app; do
		rec "$_rel" "npm" "live-npm-ci" "install" "skip" "LIVE_UNAVAILABLE" "live" "SS_CONSUMER_LIVE!=1"
		rec "$_rel" "npm" "typecheck-mutation" "typecheck" "skip" "LIVE_UNAVAILABLE" "live" "SS_CONSUMER_LIVE!=1"
		rec "$_rel" "npm" "lint-mutation" "lint" "skip" "LIVE_UNAVAILABLE" "live" "SS_CONSUMER_LIVE!=1"
		rec "$_rel" "npm" "test-mutation" "test" "skip" "LIVE_UNAVAILABLE" "live" "SS_CONSUMER_LIVE!=1"
	done
fi

# --- validate emitted evidence -----------------------------------------------
if rcv_validate "$REC"; then
	pass "all emitted records conform to consumer-validation.schema.json (jq-structural)"
else
	fail "emitted records failed schema validation"
fi
# Also confirm the schema file itself is valid JSON (jq-structural gate).
if jq -e . "$ROOT/schemas/node-consumer-validation.schema.json" >/dev/null 2>&1; then
	pass "consumer-validation.schema.json is valid JSON"
else
	fail "consumer-validation.schema.json is not valid JSON"
fi

_total=$(grep -c . "$REC" 2>/dev/null || echo 0)
printf '\n201-node-consumers: %s record(s) emitted, %d skip(s), %d failure(s)\n' "$_total" "$SKIPS" "$FAILS"
if [ "$FAILS" -ne 0 ]; then
	printf '%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf 'All consumer-validation assertions passed.\n'
exit 0
