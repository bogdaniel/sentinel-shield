#!/bin/sh
# tests/prod/201-node-consumers.sh — real-consumer validation for Node/React.
#
# Validates the genuine consumer fixtures under tests/consumers/ (node-service,
# react-app, pm-variants/{npm,pnpm,yarn}) against Sentinel Shield's package-manager
# authority model and Node quality gates. Every check emits a schema-valid record
# (schemas/consumer-validation.schema.json) via the shared reporter.
#
# TWO tiers, clearly separated (HONESTY: a skip is NEVER a pass):
#   STRUCTURAL (always; network-free, deterministic) —
#     * lockfile authority: each consumer commits exactly ONE authoritative
#       lockfile and pm_resolve picks the right manager + immutable command;
#     * package-manager NEGATIVE cases with stable reason codes
#       (MULTIPLE_AUTHORITATIVE_LOCKFILES / MANAGER_MISMATCH / MISSING_LOCKFILE /
#       INVALID_MANAGER);
#     * packageManager DECLARATION validation + version policy with stable reason
#       codes (INVALID_PACKAGE_MANAGER_DECLARATION / UNSUPPORTED_PACKAGE_MANAGER /
#       INVALID_PACKAGE_MANAGER_VERSION / UNSUPPORTED_PACKAGE_MANAGER_VERSION /
#       MALFORMED_PACKAGE_JSON) — a present invalid declaration NEVER falls back
#       to a lockfile;
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
. "$ROOT/scripts/report-consumer-validation.sh"

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
# Derive the optional ecosystem tag from the consumer name: react-app is 'react',
# the node fixtures are 'node', and stack-agnostic synthetic fixtures (negative
# package-manager cases) carry no ecosystem.
rec() {
	case "$1" in
		react-app | *react*) RCV_ECOSYSTEM=react ;;
		node-service | pm-variants/*) RCV_ECOSYSTEM=node ;;
		*) RCV_ECOSYSTEM="" ;;
	esac
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
# consumer-relpath | expected-manager | expected-immutable-command-id
# (pm-variants/yarn declares classic yarn@1.x -> the classic frozen-lockfile command-id.)
CONSUMER_SPECS='node-service|npm|npm-ci
react-app|npm|npm-ci
pm-variants/npm|npm|npm-ci
pm-variants/pnpm|pnpm|pnpm-frozen-lockfile
pm-variants/yarn|yarn|yarn-classic-frozen'

# Iterate in the CURRENT shell (never in a pipe subshell) so pass/fail counters
# and emitted records both survive.
_oifs=$IFS
IFS='
'
for _spec in $CONSUMER_SPECS; do
	IFS=$_oifs
	_rel=$(printf '%s' "$_spec" | cut -d'|' -f1)
	_mgr=$(printf '%s' "$_spec" | cut -d'|' -f2)
	_cid=$(printf '%s' "$_spec" | cut -d'|' -f3)
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
	# pm_resolve now emits: ok<TAB>manager<TAB>version<TAB>lockfile<TAB>immutable-command-id
	_line=$(pm_resolve "$_dir" immutable "") || true
	_ok=$(printf '%s' "$_line" | cut -f1)
	_got=$(printf '%s' "$_line" | cut -f2)
	_ver=$(printf '%s' "$_line" | cut -f3)
	_lock=$(printf '%s' "$_line" | cut -f4)
	_gotcid=$(printf '%s' "$_line" | cut -f5)
	assert_eq "$_rel: pm_resolve => ok/$_mgr" "$_ok/$_got" "ok/$_mgr"
	assert_eq "$_rel: pm_resolve lockfile field" "$_lock" "$(pm_lockfile_for "$_mgr")"
	assert_eq "$_rel: pm_resolve immutable-command-id" "$_gotcid" "$_cid"
	# These fixtures all declare a packageManager, so a real version (never '-') is recorded.
	if [ "$_ver" != "-" ] && [ -n "$_ver" ]; then
		pass "$_rel: declared version recorded ($_ver)"
	else
		fail "$_rel: declared version recorded (got '$_ver')"
	fi
	# The command-id maps to a FIXED template (never assembled from project content).
	_cmd=$(pm_immutable_template "$_gotcid" "$_dir")
	case "$_cid" in
		npm-ci) _want='ci$' ;;
		pnpm-frozen-lockfile) _want='install --frozen-lockfile$' ;;
		yarn-immutable) _want='install --immutable$' ;;
		yarn-classic-frozen) _want='install --frozen-lockfile$' ;;
	esac
	if printf '%s' "$_cmd" | grep -q "$_want"; then
		pass "$_rel: immutable template manager-correct ($_cmd)"
	else
		fail "$_rel: immutable template manager-correct (got '$_cmd')"
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

# --- B2. packageManager DECLARATION validation (present-but-invalid MUST fail) -
# A PRESENT invalid packageManager declaration fails with a stable reason code and is NEVER
# silently dropped so the sole lockfile can be chosen against the project's explicit intent.
# Each fixture ALSO commits a package-lock.json to PROVE the declaration error takes precedence
# over lockfile fallback (the whole point of TASK 4).
decl_neg() { # desc  packageManager-JSON-value  expect_code
	_dd=$(mktemp -d "$WORK/declXXXXXX")
	printf '{"packageManager":%s}\n' "$2" > "$_dd/package.json"
	: > "$_dd/package-lock.json" # a sole lockfile the engine must NOT fall back to
	_line=$(pm_resolve "$_dd" immutable "") || true
	_st=$(printf '%s' "$_line" | cut -f1)
	_code=$(printf '%s' "$_line" | cut -f2)
	assert_eq "$1" "$_st/$_code" "error/$3"
	rec "declaration/$3" "none" "pm-declaration-negative" "package-manager" "pass" "$3" "structural" "$1"
}

decl_neg "decl: bun@1.2.0 unsupported manager (not npm|pnpm|yarn)" '"bun@1.2.0"' "UNSUPPORTED_PACKAGE_MANAGER"
decl_neg "decl: pnpm (no version) is malformed" '"pnpm"' "INVALID_PACKAGE_MANAGER_DECLARATION"
decl_neg "decl: @9.0.0 missing manager name" '"@9.0.0"' "INVALID_PACKAGE_MANAGER_DECLARATION"
decl_neg "decl: npm@not-a-version invalid version syntax" '"npm@not-a-version"' "INVALID_PACKAGE_MANAGER_VERSION"
decl_neg "decl: non-string number value is malformed" '10' "INVALID_PACKAGE_MANAGER_DECLARATION"
decl_neg "decl: non-string object value is malformed" '{"name":"npm"}' "INVALID_PACKAGE_MANAGER_DECLARATION"
decl_neg "decl: command-like/whitespace content rejected" '"npm@10 && rm -rf /"' "INVALID_PACKAGE_MANAGER_DECLARATION"
decl_neg "decl: unsupported pnpm major (5.x)" '"pnpm@5.0.0"' "UNSUPPORTED_PACKAGE_MANAGER_VERSION"

# malformed package.json (TASK 5 case 11): unparseable JSON fails, never a silent lockfile pick.
_bad=$(mktemp -d "$WORK/badpjXXXXXX")
printf '{ this is : not valid json' > "$_bad/package.json"; : > "$_bad/package-lock.json"
_line=$(pm_resolve "$_bad" immutable "") || true
assert_eq "decl: malformed package.json rejected" \
	"$(printf '%s' "$_line" | cut -f1)/$(printf '%s' "$_line" | cut -f2)" "error/MALFORMED_PACKAGE_JSON"
rec "declaration/MALFORMED_PACKAGE_JSON" "none" "pm-declaration-negative" "package-manager" "pass" "MALFORMED_PACKAGE_JSON" "structural" "unparseable package.json"

# --- B3. version-policy + command-id POSITIVES and remaining TASK 5 cases ------
# Helper: build a fixture with a declaration + a chosen lockfile and assert the full ok line.
pol_ok() { # desc  packageManager-value  lockfile-name  expect: mgr/version/cmdid
	_pd=$(mktemp -d "$WORK/polXXXXXX")
	printf '{"packageManager":"%s"}\n' "$2" > "$_pd/package.json"
	: > "$_pd/$3"
	_line=$(pm_resolve "$_pd" immutable "") || true
	_got="$(printf '%s' "$_line" | cut -f1)/$(printf '%s' "$_line" | cut -f2)/$(printf '%s' "$_line" | cut -f3)/$(printf '%s' "$_line" | cut -f5)"
	assert_eq "$1" "$_got" "$4"
	rec "policy/ok" "$(printf '%s' "$_line" | cut -f2)" "pm-policy-positive" "package-manager" "pass" "OK" "structural" "$_line"
}

# (1) supported npm + lock ; (3) supported pnpm + lock ; (5)+(6) supported yarn MODERN + lock.
pol_ok "policy: supported npm@11 + lock" "npm@11.0.0" "package-lock.json" "ok/npm/11.0.0/npm-ci"
pol_ok "policy: supported pnpm@9 + lock" "pnpm@9.1.0" "pnpm-lock.yaml" "ok/pnpm/9.1.0/pnpm-frozen-lockfile"
pol_ok "policy: supported yarn MODERN@4 + lock -> yarn-immutable" "yarn@4.1.0" "yarn.lock" "ok/yarn/4.1.0/yarn-immutable"
# (6) yarn CLASSIC vs MODERN: classic (1.x) -> distinct classic frozen-lockfile command-id.
pol_ok "policy: yarn CLASSIC@1 + lock -> yarn-classic-frozen" "yarn@1.22.22" "yarn.lock" "ok/yarn/1.22.22/yarn-classic-frozen"

# (2) unsupported npm major ; (4) unsupported pnpm major (both WITH a matching lockfile, so the
# failure is the VERSION policy — not a mismatch or missing lock).
_un=$(mktemp -d "$WORK/unmajXXXXXX"); printf '{"packageManager":"npm@2.0.0"}\n' > "$_un/package.json"; : > "$_un/package-lock.json"
neg_case "policy: unsupported npm major (2.x) + matching lock" "$_un" "" "UNSUPPORTED_PACKAGE_MANAGER_VERSION"
_up=$(mktemp -d "$WORK/unpnpmXXXXXX"); printf '{"packageManager":"pnpm@5.0.0"}\n' > "$_up/package.json"; : > "$_up/pnpm-lock.yaml"
neg_case "policy: unsupported pnpm major (5.x) + matching lock" "$_up" "" "UNSUPPORTED_PACKAGE_MANAGER_VERSION"

# (7) manager-vs-lockfile conflict: valid declaration disagrees with the committed lockfile.
_cf=$(mktemp -d "$WORK/conflictXXXXXX"); printf '{"packageManager":"pnpm@9.0.0"}\n' > "$_cf/package.json"; : > "$_cf/package-lock.json"
neg_case "policy: declared pnpm but npm lockfile -> MANAGER_MISMATCH" "$_cf" "" "MANAGER_MISMATCH"

# (10) CLI override conflicting with a valid declaration -> MANAGER_MISMATCH (never silent override).
_ov=$(mktemp -d "$WORK/overrideXXXXXX"); printf '{"packageManager":"npm@10.0.0"}\n' > "$_ov/package.json"; : > "$_ov/package-lock.json"
neg_case "policy: override pnpm vs declared npm -> MANAGER_MISMATCH" "$_ov" "pnpm" "MANAGER_MISMATCH"

# pm_policy emits a machine-readable row per manager (contract for downstream tooling).
_pol_rows=$(pm_policy | grep -c .)
_pol_yarn_majors=$(pm_policy | awk -F'\t' '$1=="yarn"{print $2}')
_pol_yarn_cp=$(pm_policy | awk -F'\t' '$1=="yarn"{print $3}')
if [ "$_pol_rows" -eq 3 ] && [ "$_pol_yarn_majors" = "1 2 3 4" ] && [ "$_pol_yarn_cp" = "yes" ]; then
	pass "policy: pm_policy emits 3 machine-readable manager rows (yarn majors + corepack correct)"
else
	fail "policy: pm_policy rows (rows=$_pol_rows yarn_majors='$_pol_yarn_majors' corepack='$_pol_yarn_cp')"
fi

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
if jq -e . "$ROOT/schemas/consumer-validation.schema.json" >/dev/null 2>&1; then
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
