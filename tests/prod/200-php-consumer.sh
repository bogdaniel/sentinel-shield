#!/bin/sh
# tests/prod/200-php-consumer.sh — real-consumer validation driver for the
# framework-agnostic PHP library fixture (tests/consumers/php-library).
#
# WHAT THIS PROVES (here, offline, with NO composer/php in the runner):
#   - the consumer manifest is well-formed and PSR-4 wired to src/;
#   - each quality dimension is satisfied by exactly ONE tool from an allowed
#     one-of set (PHPUnit|Pest, PHPStan|Psalm, Pint|PHP-CS-Fixer);
#   - the strict configs (phpstan.neon.dist at level max, pint.json) exist;
#   - the two INTENTIONAL seeded defects are still present in src/ (so a silent
#     removal of the payload fails the build);
#   - ONE mutation against a RUNNABLE gate (drop the static-analysis tool from the
#     manifest) is actually CAUGHT, with a stable reason_code — the gate is not a
#     no-op;
#   - a schema-valid consumer-validation record is emitted via the SHARED reporter.
#
# WHAT THIS EXPLICITLY DEFERS: composer/php are ABSENT in this sandbox, so
# `composer validate`, `phpunit`, `phpstan analyse`, `pint --test` and `php -l`
# CANNOT run. They are recorded as status="skip" with a TOOLCHAIN_ABSENT_* reason
# code — a SKIP is NOT a pass; CI (which has the toolchain) must still run them.
#
# Self-contained, network-free; mktemp scratch, trap cleanup. Auto-discovered by
# `sh scripts/self-test.sh production-readiness`.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONSUMER="$ROOT/tests/consumers/php-library"
MANIFEST="$CONSUMER/composer.json"
REPORTER="$ROOT/scripts/report-consumer-validation.sh"
SCHEMA="$ROOT/schemas/consumer-validation.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # desc actual expected
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required for this driver" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

GATES="$WORK/gates.ndjson"    # one compact gate object per line
: > "$GATES"

# add_gate <id> <tool_group> <tool> <status> <reason_code>
add_gate() {
	jq -c -n \
		--arg id "$1" --arg tg "$2" --arg tool "$3" --arg st "$4" --arg rc "$5" \
		'{id:$id, tool_group:$tg, tool:$tool, status:$st, reason_code:$rc}' >> "$GATES"
}

# --- tool-group detectors (read a composer.json path; echo selected tool or "") --
# One-of resolution per dimension. Empty output means the dimension is unsatisfied.
tg_test() {
	if   jq -e '.["require-dev"]["phpunit/phpunit"]' "$1" >/dev/null 2>&1; then echo phpunit
	elif jq -e '.["require-dev"]["pestphp/pest"]'    "$1" >/dev/null 2>&1; then echo pest
	else echo ""; fi
}
tg_static() {
	if   jq -e '.["require-dev"]["phpstan/phpstan"]' "$1" >/dev/null 2>&1; then echo phpstan
	elif jq -e '.["require-dev"]["vimeo/psalm"]'     "$1" >/dev/null 2>&1; then echo psalm
	else echo ""; fi
}
tg_style() {
	if   jq -e '.["require-dev"]["laravel/pint"]'          "$1" >/dev/null 2>&1; then echo pint
	elif jq -e '.["require-dev"]["friendsofphp/php-cs-fixer"]' "$1" >/dev/null 2>&1; then echo php-cs-fixer
	else echo ""; fi
}

# ===========================================================================
# RUNNABLE GATES (structural — no composer/php needed)
# ===========================================================================

# G: fixture exists at all.
if [ -f "$MANIFEST" ]; then pass "consumer fixture present at tests/consumers/php-library"
else fail "consumer fixture present at tests/consumers/php-library"; fi

# G1: manifest is valid JSON.
if jq -e . "$MANIFEST" >/dev/null 2>&1; then
	pass "manifest gate: composer.json is valid JSON"
	add_gate manifest_valid_json manifest composer pass OK
else
	fail "manifest gate: composer.json is valid JSON"
	add_gate manifest_valid_json manifest composer fail MANIFEST_INVALID_JSON
fi

# G2: PSR-4 autoload App\ -> src/.
_psr4=$(jq -r '.autoload["psr-4"]["App\\"] // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ "$_psr4" = "src/" ]; then
	pass "manifest gate: PSR-4 App\\ -> src/"
	add_gate psr4_autoload manifest composer pass OK
else
	fail "manifest gate: PSR-4 App\\ -> src/ (got '$_psr4')"
	add_gate psr4_autoload manifest composer fail PSR4_AUTOLOAD_MISSING
fi

# G3: this is a library, not a framework app (honest labeling).
_type=$(jq -r '.type // ""' "$MANIFEST")
check "manifest gate: type is 'library' (not a framework app)" "$_type" "library"
# Guard against accidental framework runtime deps that would make it Laravel/Symfony.
if jq -e '.require | keys[] | select(test("^(laravel/framework|symfony/framework-bundle)$"))' "$MANIFEST" >/dev/null 2>&1; then
	fail "manifest gate: no framework runtime dependency (php-library must stay framework-neutral)"
else
	pass "manifest gate: no framework runtime dependency (framework-neutral)"
fi

# G4..G6: one-of tool groups.
SEL_TEST=$(tg_test "$MANIFEST")
SEL_STATIC=$(tg_static "$MANIFEST")
SEL_STYLE=$(tg_style "$MANIFEST")

if [ -n "$SEL_TEST" ]; then
	pass "tool-group gate: test = $SEL_TEST (one-of PHPUnit|Pest)"
	add_gate test_toolgroup test "$SEL_TEST" pass OK
else
	fail "tool-group gate: a test tool (PHPUnit|Pest) is declared"
	add_gate test_toolgroup test none fail TEST_TOOL_MISSING
fi

if [ -n "$SEL_STATIC" ]; then
	pass "tool-group gate: static_analysis = $SEL_STATIC (one-of PHPStan|Psalm)"
	add_gate static_analysis_toolgroup static_analysis "$SEL_STATIC" pass OK
else
	fail "tool-group gate: a static-analysis tool (PHPStan|Psalm) is declared"
	add_gate static_analysis_toolgroup static_analysis none fail STATIC_ANALYSIS_TOOL_MISSING
fi

if [ -n "$SEL_STYLE" ]; then
	pass "tool-group gate: style = $SEL_STYLE (one-of Pint|PHP-CS-Fixer)"
	add_gate style_toolgroup style "$SEL_STYLE" pass OK
else
	fail "tool-group gate: a style tool (Pint|PHP-CS-Fixer) is declared"
	add_gate style_toolgroup style none fail STYLE_TOOL_MISSING
fi

# G7: PHPStan config present + declares a level.
if [ -f "$CONSUMER/phpstan.neon.dist" ] && grep -q 'level:' "$CONSUMER/phpstan.neon.dist"; then
	pass "config gate: phpstan.neon.dist present with a level"
	add_gate phpstan_config config phpstan pass OK
else
	fail "config gate: phpstan.neon.dist present with a level"
	add_gate phpstan_config config phpstan fail PHPSTAN_CONFIG_MISSING
fi

# G8: style config present (pint.json valid JSON OR .php-cs-fixer.php present).
if { [ -f "$CONSUMER/pint.json" ] && jq -e . "$CONSUMER/pint.json" >/dev/null 2>&1; } \
	|| [ -f "$CONSUMER/.php-cs-fixer.php" ]; then
	pass "config gate: style config present ($SEL_STYLE)"
	add_gate style_config config "$SEL_STYLE" pass OK
else
	fail "config gate: style config present"
	add_gate style_config config "$SEL_STYLE" fail STYLE_CONFIG_MISSING
fi

# G9: the two intentional seeded defects are still present (payload not silently removed).
if grep -q 'SEEDED-STYLE-FINDING' "$CONSUMER/src/Calculator.php" \
	&& grep -q 'SEEDED-PHPSTAN-FINDING' "$CONSUMER/src/Calculator.php"; then
	pass "payload gate: both seeded defects present for CI gates to catch"
	add_gate seeded_findings config source pass OK
else
	fail "payload gate: both seeded defects present"
	add_gate seeded_findings config source fail SEEDED_FINDING_ABSENT
fi

# ===========================================================================
# SKIP GATES (require composer/php — ABSENT in this runner; deferred to CI)
# ===========================================================================
COMPOSER_PRESENCE=absent
PHP_PRESENCE=absent
command -v composer >/dev/null 2>&1 && COMPOSER_PRESENCE=present
command -v php >/dev/null 2>&1 && PHP_PRESENCE=present

# Honesty: this sandbox has neither. If a future runner DOES have them, we still
# record skip (this driver is the structural harness; the executing gate lives in
# scripts/run-php-quality.sh and CI). We assert the SKIP is explicit + reason-coded.
add_gate composer_validate manifest composer skip TOOLCHAIN_ABSENT_COMPOSER
add_gate phpunit_run       test phpunit         skip TOOLCHAIN_ABSENT_PHP
add_gate phpstan_analyse   static_analysis phpstan skip TOOLCHAIN_ABSENT_PHP
add_gate pint_check        style pint           skip TOOLCHAIN_ABSENT_PHP
add_gate php_syntax_lint   config php           skip TOOLCHAIN_ABSENT_PHP

check "toolchain: composer absent in this runner (gate deferred)" "$COMPOSER_PRESENCE" "absent"
check "toolchain: php absent in this runner (gate deferred)" "$PHP_PRESENCE" "absent"

# ===========================================================================
# MUTATION: prove a RUNNABLE gate actually catches a regression.
# Inject: remove the static-analysis tool from a COPY of the manifest, then re-run
# the static_analysis one-of detector. Expect it to now report MISSING (fail).
# ===========================================================================
MUT_MANIFEST="$WORK/mutated-composer.json"
jq 'del(.["require-dev"]["phpstan/phpstan"])' "$MANIFEST" > "$MUT_MANIFEST"
MUT_SEL=$(tg_static "$MUT_MANIFEST")
if [ -z "$MUT_SEL" ]; then
	MUT_OBSERVED=fail
	pass "mutation: dropping phpstan from the manifest is CAUGHT by static_analysis_toolgroup"
else
	MUT_OBSERVED=pass
	fail "mutation: dropping phpstan should be caught but detector still found '$MUT_SEL'"
fi
# Sanity: the mutation must not have touched the real fixture.
check "mutation: real manifest untouched (still resolves phpstan)" "$(tg_static "$MANIFEST")" "phpstan"

MUT_JSON="$WORK/mutation.json"
jq -n \
	--arg tg static_analysis_toolgroup \
	--arg exp fail \
	--arg obs "$MUT_OBSERVED" \
	--arg rc STATIC_ANALYSIS_TOOL_MISSING \
	--argjson caught "$([ "$MUT_OBSERVED" = fail ] && echo true || echo false)" \
	'{applied:true, target_gate:$tg, expected_status:$exp, observed_status:$obs, reason_code:$rc, caught:$caught}' \
	> "$MUT_JSON"

# ===========================================================================
# ASSEMBLE + EMIT the record via the SHARED reporter.
# ===========================================================================
TG_JSON="$WORK/tool-groups.json"
jq -n \
	--arg t "$SEL_TEST" --arg s "$SEL_STATIC" --arg y "$SEL_STYLE" \
	'{
		test:            {selected:$t, candidates:["phpunit","pest"]},
		static_analysis: {selected:$s, candidates:["phpstan","psalm"]},
		style:           {selected:$y, candidates:["pint","php-cs-fixer"]}
	}' > "$TG_JSON"

GATES_JSON="$WORK/gates.json"
jq -s . "$GATES" > "$GATES_JSON"

# result: runnable gates passed + mutation caught, but SKIP gates exist -> "partial".
RESULT=partial
if [ "$FAILS" -ne 0 ] || [ "$MUT_OBSERVED" != fail ]; then
	RESULT=fail
fi

RECORD="$WORK/record.json"
_rc=0
sh "$REPORTER" \
	--consumer-name php-library-consumer-fixture \
	--consumer-kind php-library \
	--consumer-path tests/consumers/php-library \
	--profile php_library \
	--composer "$COMPOSER_PRESENCE" \
	--php "$PHP_PRESENCE" \
	--result "$RESULT" \
	--tool-groups-file "$TG_JSON" \
	--gates-file "$GATES_JSON" \
	--mutation-file "$MUT_JSON" \
	--limitation "composer absent in runner: 'composer validate' + lockfile resolution deferred to CI" \
	--limitation "php absent in runner: phpunit/phpstan/pint execution deferred to CI" \
	> "$RECORD" 2>/dev/null || _rc=$?
check "reporter: shared report-consumer-validation.sh exited 0" "$_rc" "0"

# ===========================================================================
# VALIDATE the emitted record structurally against the schema (jq, no ajv).
# ===========================================================================
if [ -s "$RECORD" ] && jq -e . "$RECORD" >/dev/null 2>&1; then
	pass "record: reporter emitted valid JSON"
else
	fail "record: reporter emitted valid JSON"
fi

# Every top-level required key from the schema must be present in the record.
_missing=$(jq -r --slurpfile rec "$RECORD" \
	'.required[] as $k | select(($rec[0] | has($k)) | not) | $k' "$SCHEMA" 2>/dev/null || echo "JQERR")
if [ -z "$_missing" ]; then
	pass "record: all schema-required top-level keys present"
else
	fail "record: missing schema-required keys -> $_missing"
fi

# Every reason_code used (gates + mutation) must be in the schema enum.
_enum="$WORK/enum.json"
jq -c '.["$defs"].reasonCode.enum' "$SCHEMA" > "$_enum"
_bad=$(jq -r --slurpfile enum "$_enum" '
	([.gates[].reason_code] + [.mutation.reason_code]) | unique
	| map(select(. as $c | ($enum[0] | index($c)) | not)) | .[]' "$RECORD" 2>/dev/null || echo "JQERR")
if [ -z "$_bad" ]; then
	pass "record: all reason_codes are within the schema enum"
else
	fail "record: reason_codes outside schema enum -> $_bad"
fi

# Semantic assertions on the record.
check "record: schema_version is 1" "$(jq -r '.schema_version' "$RECORD")" "1"
check "record: consumer.kind is php-library (NOT laravel/symfony)" "$(jq -r '.consumer.kind' "$RECORD")" "php-library"
check "record: mutation was caught" "$(jq -r '.mutation.caught' "$RECORD")" "true"
check "record: result is partial (runnable pass + deferred skips)" "$(jq -r '.result' "$RECORD")" "partial"

# At least one gate is an explicit, reason-coded SKIP (a skip is NOT a pass).
_skips=$(jq -r '[.gates[] | select(.status=="skip")] | length' "$RECORD")
if [ "$_skips" -ge 1 ]; then
	pass "record: $_skips gate(s) explicitly SKIPPED with a reason_code (deferred to CI)"
else
	fail "record: expected >=1 explicit SKIP gate"
fi
# Every skip must carry a TOOLCHAIN_ABSENT_* reason (never a bare/hidden skip).
_badskip=$(jq -r '[.gates[] | select(.status=="skip" and (.reason_code|startswith("TOOLCHAIN_ABSENT_")|not))] | length' "$RECORD")
check "record: every SKIP carries a TOOLCHAIN_ABSENT_* reason_code" "$_badskip" "0"

# Emit the record to stderr for CI log capture (stdout stays quiet for the runner).
printf '\n--- consumer-validation record ---\n' >&2
jq . "$RECORD" >&2

if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll php-library consumer assertions passed (with explicit CI-deferred SKIPs).\n'
exit 0
