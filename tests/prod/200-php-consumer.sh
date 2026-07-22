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
#   - each check emits a schema-valid, line-delimited consumer-validation record
#     (schemas/consumer-validation.schema.json) via the SHARED reporter, tagged
#     ecosystem="php".
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
SCHEMA="$ROOT/schemas/consumer-validation.schema.json"

. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/report-consumer-validation.sh"

# Every record from this driver is a PHP/Composer consumer, manager-agnostic.
RCV_ECOSYSTEM=php
PM=none

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # desc actual expected
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

command_exists jq || { echo "FAIL: jq is required for this driver" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

REC="$WORK/records.jsonl"    # one compact consumer-validation record per line
: > "$REC"

# rec <consumer> <pm> <check> <gate> <status> <reason> <mode> [detail]
# Append a schema-valid record; a reporter failure is itself a test failure.
rec() {
	if ! rcv_record "$@" >> "$REC"; then
		fail "reporter failed to emit record for check '$3'"
	fi
}

CONSUMER_NAME=php-library-consumer-fixture

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

log_info "200-php-consumer: structural gates + toolchain-adaptive live gates (network-free)"

# ===========================================================================
# RUNNABLE GATES (structural — no composer/php needed)
# ===========================================================================

# G: fixture exists at all.
if [ -f "$MANIFEST" ]; then
	pass "consumer fixture present at tests/consumers/php-library"
	rec "$CONSUMER_NAME" "$PM" "fixture-present" "manifest" "pass" "OK" "structural" "tests/consumers/php-library"
else
	fail "consumer fixture present at tests/consumers/php-library"
	rec "$CONSUMER_NAME" "$PM" "fixture-present" "manifest" "fail" "MANIFEST_INVALID_JSON" "structural" "missing composer.json"
fi

# G1: manifest is valid JSON.
if jq -e . "$MANIFEST" >/dev/null 2>&1; then
	pass "manifest gate: composer.json is valid JSON"
	rec "$CONSUMER_NAME" "$PM" "manifest-valid-json" "manifest" "pass" "OK" "structural" "composer.json"
else
	fail "manifest gate: composer.json is valid JSON"
	rec "$CONSUMER_NAME" "$PM" "manifest-valid-json" "manifest" "fail" "MANIFEST_INVALID_JSON" "structural" "composer.json"
fi

# G2: PSR-4 autoload App\ -> src/.
_psr4=$(jq -r '.autoload["psr-4"]["App\\"] // ""' "$MANIFEST" 2>/dev/null || echo "")
if [ "$_psr4" = "src/" ]; then
	pass "manifest gate: PSR-4 App\\ -> src/"
	rec "$CONSUMER_NAME" "$PM" "psr4-autoload" "manifest" "pass" "OK" "structural" "App\\ => src/"
else
	fail "manifest gate: PSR-4 App\\ -> src/ (got '$_psr4')"
	rec "$CONSUMER_NAME" "$PM" "psr4-autoload" "manifest" "fail" "PSR4_AUTOLOAD_MISSING" "structural" "got '$_psr4'"
fi

# G3: this is a library, not a framework app (honest labeling).
_type=$(jq -r '.type // ""' "$MANIFEST")
check "manifest gate: type is 'library' (not a framework app)" "$_type" "library"
if [ "$_type" = "library" ]; then
	rec "$CONSUMER_NAME" "$PM" "manifest-type-library" "manifest" "pass" "OK" "structural" "type=library"
else
	rec "$CONSUMER_NAME" "$PM" "manifest-type-library" "manifest" "fail" "MANIFEST_TYPE_NOT_LIBRARY" "structural" "type=$_type"
fi
# Guard against accidental framework runtime deps that would make it Laravel/Symfony.
if jq -e '.require | keys[] | select(test("^(laravel/framework|symfony/framework-bundle)$"))' "$MANIFEST" >/dev/null 2>&1; then
	fail "manifest gate: no framework runtime dependency (php-library must stay framework-neutral)"
	rec "$CONSUMER_NAME" "$PM" "framework-neutral" "manifest" "fail" "FRAMEWORK_RUNTIME_DEP" "structural" "laravel/symfony runtime dep present"
else
	pass "manifest gate: no framework runtime dependency (framework-neutral)"
	rec "$CONSUMER_NAME" "$PM" "framework-neutral" "manifest" "pass" "OK" "structural" "no framework runtime dep"
fi

# G4..G6: one-of tool groups.
SEL_TEST=$(tg_test "$MANIFEST")
SEL_STATIC=$(tg_static "$MANIFEST")
SEL_STYLE=$(tg_style "$MANIFEST")

if [ -n "$SEL_TEST" ]; then
	pass "tool-group gate: test = $SEL_TEST (one-of PHPUnit|Pest)"
	rec "$CONSUMER_NAME" "$PM" "one-of-test-runner" "one-of" "pass" "OK" "structural" "$SEL_TEST"
else
	fail "tool-group gate: a test tool (PHPUnit|Pest) is declared"
	rec "$CONSUMER_NAME" "$PM" "one-of-test-runner" "one-of" "fail" "TEST_TOOL_MISSING" "structural" "none of phpunit|pest"
fi

if [ -n "$SEL_STATIC" ]; then
	pass "tool-group gate: static_analysis = $SEL_STATIC (one-of PHPStan|Psalm)"
	rec "$CONSUMER_NAME" "$PM" "one-of-static-analysis" "one-of" "pass" "OK" "structural" "$SEL_STATIC"
else
	fail "tool-group gate: a static-analysis tool (PHPStan|Psalm) is declared"
	rec "$CONSUMER_NAME" "$PM" "one-of-static-analysis" "one-of" "fail" "STATIC_ANALYSIS_TOOL_MISSING" "structural" "none of phpstan|psalm"
fi

if [ -n "$SEL_STYLE" ]; then
	pass "tool-group gate: style = $SEL_STYLE (one-of Pint|PHP-CS-Fixer)"
	rec "$CONSUMER_NAME" "$PM" "one-of-style" "one-of" "pass" "OK" "structural" "$SEL_STYLE"
else
	fail "tool-group gate: a style tool (Pint|PHP-CS-Fixer) is declared"
	rec "$CONSUMER_NAME" "$PM" "one-of-style" "one-of" "fail" "STYLE_TOOL_MISSING" "structural" "none of pint|php-cs-fixer"
fi

# G7: PHPStan config present + declares a level.
if [ -f "$CONSUMER/phpstan.neon.dist" ] && grep -q 'level:' "$CONSUMER/phpstan.neon.dist"; then
	pass "config gate: phpstan.neon.dist present with a level"
	rec "$CONSUMER_NAME" "$PM" "phpstan-config" "config" "pass" "OK" "structural" "phpstan.neon.dist"
else
	fail "config gate: phpstan.neon.dist present with a level"
	rec "$CONSUMER_NAME" "$PM" "phpstan-config" "config" "fail" "PHPSTAN_CONFIG_MISSING" "structural" "phpstan.neon.dist"
fi

# G8: style config present (pint.json valid JSON OR .php-cs-fixer.php present).
if { [ -f "$CONSUMER/pint.json" ] && jq -e . "$CONSUMER/pint.json" >/dev/null 2>&1; } \
	|| [ -f "$CONSUMER/.php-cs-fixer.php" ]; then
	pass "config gate: style config present ($SEL_STYLE)"
	rec "$CONSUMER_NAME" "$PM" "style-config" "config" "pass" "OK" "structural" "$SEL_STYLE"
else
	fail "config gate: style config present"
	rec "$CONSUMER_NAME" "$PM" "style-config" "config" "fail" "STYLE_CONFIG_MISSING" "structural" "$SEL_STYLE"
fi

# G9: the two intentional seeded defects are still present (payload not silently removed).
if grep -q 'SEEDED-STYLE-FINDING' "$CONSUMER/src/Calculator.php" \
	&& grep -q 'SEEDED-PHPSTAN-FINDING' "$CONSUMER/src/Calculator.php"; then
	pass "payload gate: both seeded defects present for CI gates to catch"
	rec "$CONSUMER_NAME" "$PM" "seeded-findings" "config" "pass" "OK" "structural" "SEEDED-STYLE-FINDING + SEEDED-PHPSTAN-FINDING"
else
	fail "payload gate: both seeded defects present"
	rec "$CONSUMER_NAME" "$PM" "seeded-findings" "config" "fail" "SEEDED_FINDING_ABSENT" "structural" "seeded payload missing"
fi

# ===========================================================================
# LIVE GATES — toolchain-ADAPTIVE. Cheap, network-free gates (composer validate,
# php -l) RUN for real when the tool is present (e.g. in CI); when absent they are
# recorded as an explicit reason-coded SKIP. Dependency-install gates
# (phpunit/phpstan/pint) need `composer install` (network) and stay deferred to a
# dedicated CI job. A skip is NOT a pass; and a present toolchain must NEVER fail
# this suite merely for being present.
# ===========================================================================
COMPOSER_PRESENCE=absent
PHP_PRESENCE=absent
command -v composer >/dev/null 2>&1 && COMPOSER_PRESENCE=present
command -v php >/dev/null 2>&1 && PHP_PRESENCE=present
log_info "200-php-consumer: toolchain composer=$COMPOSER_PRESENCE php=$PHP_PRESENCE"

# composer validate (schema only, network-free) — live when composer is present.
if [ "$COMPOSER_PRESENCE" = present ]; then
	if ( cd "$CONSUMER" && composer validate --no-check-all --no-check-lock --no-check-publish >/dev/null 2>&1 ); then
		pass "live: composer validate passes on the consumer manifest"
		rec "$CONSUMER_NAME" "$PM" "composer-validate" "manifest" "pass" "OK" "live" "composer validate --no-check-all"
	else
		fail "live: composer validate failed on the consumer manifest"
		rec "$CONSUMER_NAME" "$PM" "composer-validate" "manifest" "fail" "COMPOSER_VALIDATE_FAILED" "live" "composer validate --no-check-all"
	fi
else
	rec "$CONSUMER_NAME" "$PM" "composer-validate" "manifest" "skip" "TOOLCHAIN_ABSENT_COMPOSER" "live" "composer absent in runner"
fi

# php -l (network-free) — lint every PSR-4 source when php is present.
if [ "$PHP_PRESENCE" = present ]; then
	_lint_ok=1
	for _f in "$CONSUMER"/src/*.php; do
		[ -f "$_f" ] || continue
		php -l "$_f" >/dev/null 2>&1 || _lint_ok=0
	done
	if [ "$_lint_ok" = 1 ]; then
		pass "live: php -l passes on all consumer src/*.php"
		rec "$CONSUMER_NAME" "$PM" "php-syntax-lint" "config" "pass" "OK" "live" "php -l src/*.php"
	else
		fail "live: php -l reported a syntax error in consumer src"
		rec "$CONSUMER_NAME" "$PM" "php-syntax-lint" "config" "fail" "PHP_SYNTAX_ERROR" "live" "php -l src/*.php"
	fi
else
	rec "$CONSUMER_NAME" "$PM" "php-syntax-lint" "config" "skip" "TOOLCHAIN_ABSENT_PHP" "live" "php absent in runner"
fi

# Dependency-install gates need `composer install` (network) — deferred to a
# dedicated CI job regardless of php presence; recorded as an explicit skip.
_dep_reason=DEPS_NOT_INSTALLED
[ "$PHP_PRESENCE" = present ] || _dep_reason=TOOLCHAIN_ABSENT_PHP
rec "$CONSUMER_NAME" "$PM" "phpunit-run" "test" "skip" "$_dep_reason" "live" "requires composer install (deferred to CI)"
rec "$CONSUMER_NAME" "$PM" "phpstan-analyse" "static-analysis" "skip" "$_dep_reason" "live" "requires composer install (deferred to CI)"
rec "$CONSUMER_NAME" "$PM" "pint-check" "style" "skip" "$_dep_reason" "live" "requires composer install (deferred to CI)"

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
	rec "$CONSUMER_NAME" "$PM" "static-analysis-mutation" "static-analysis" "pass" "STATIC_ANALYSIS_TOOL_MISSING" "structural" "dropped phpstan; detector reported missing (caught)"
else
	MUT_OBSERVED=pass
	fail "mutation: dropping phpstan should be caught but detector still found '$MUT_SEL'"
	rec "$CONSUMER_NAME" "$PM" "static-analysis-mutation" "static-analysis" "fail" "STATIC_ANALYSIS_TOOL_MISSING" "structural" "detector still found '$MUT_SEL' (not caught)"
fi
# Sanity: the mutation must not have touched the real fixture.
check "mutation: real manifest untouched (still resolves phpstan)" "$(tg_static "$MANIFEST")" "phpstan"

# ===========================================================================
# VALIDATE the emitted evidence structurally against the schema (jq, no ajv).
# ===========================================================================
if rcv_validate "$REC"; then
	pass "all emitted records conform to consumer-validation.schema.json (jq-structural)"
else
	fail "emitted records failed schema validation"
fi
# Confirm the schema file itself is valid JSON (jq-structural gate).
if jq -e . "$SCHEMA" >/dev/null 2>&1; then
	pass "consumer-validation.schema.json is valid JSON"
else
	fail "consumer-validation.schema.json is not valid JSON"
fi

# Every record must be tagged ecosystem=php and schema_version=1.
_badeco=$(jq -c 'select(.ecosystem != "php")' "$REC" 2>/dev/null | grep -c . || true)
check "record: every record tagged ecosystem=php" "$_badeco" "0"
_badver=$(jq -c 'select(.schema_version != "1")' "$REC" 2>/dev/null | grep -c . || true)
check "record: every record schema_version=1" "$_badver" "0"

# At least one gate is an explicit, reason-coded SKIP (a skip is NOT a pass).
_skips=$(jq -s -r '[.[] | select(.status=="skip")] | length' "$REC")
if [ "$_skips" -ge 1 ]; then
	pass "record: $_skips gate(s) explicitly SKIPPED with a reason_code (deferred to CI)"
else
	fail "record: expected >=1 explicit SKIP gate"
fi
# Every skip must carry a recognized, stable deferral reason (never a bare/hidden
# skip): TOOLCHAIN_ABSENT_* when the tool is missing, or DEPS_NOT_INSTALLED for a
# gate that needs `composer install` (deferred to a dedicated CI job).
_badskip=$(jq -s -r '[.[] | select(.status=="skip") | select((.reason_code|test("^(TOOLCHAIN_ABSENT_[A-Z]+|DEPS_NOT_INSTALLED)$"))|not)] | length' "$REC")
check "record: every SKIP carries a recognized deferral reason_code" "$_badskip" "0"

# The mutation record proves the static-analysis gate caught the injected regression.
_mut=$(jq -s -r '[.[] | select(.check=="static-analysis-mutation" and .status=="pass" and .reason_code=="STATIC_ANALYSIS_TOOL_MISSING")] | length' "$REC")
check "record: static-analysis mutation caught (STATIC_ANALYSIS_TOOL_MISSING)" "$_mut" "1"

# Emit the records to stderr for CI log capture (stdout stays quiet for the runner).
printf '\n--- consumer-validation records (php-library) ---\n' >&2
jq -c . "$REC" >&2

_total=$(grep -c . "$REC" 2>/dev/null || :)
if [ "$FAILS" -ne 0 ]; then
	printf '\n200-php-consumer: %s record(s) emitted, %d skip(s), %d failure(s)\n' "$_total" "$_skips" "$FAILS"
	printf '%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\n200-php-consumer: %s record(s) emitted, %d skip(s) (CI-deferred), 0 failures\n' "$_total" "$_skips"
printf 'All php-library consumer assertions passed (with explicit CI-deferred SKIPs).\n'
exit 0
