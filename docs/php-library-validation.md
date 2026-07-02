# PHP-library real-consumer validation

This documents the **`php_library`** consumer harness: a framework-agnostic Composer
package that Sentinel Shield validates end-to-end. It is one of the five mandatory consumer
shapes in the [consumer validation runbook](consumer-validation-runbook.md) and is
explicitly **not** a Laravel or Symfony application — it exercises the PHP profile against a
plain library so we prove the engine does not assume a framework.

## Pieces

| Path | Role |
|------|------|
| [`tests/consumers/php-library/`](../tests/consumers/php-library/) | The standalone consumer fixture (Composer package, PSR-4 `App\` → `src/`). |
| [`tests/prod/200-php-consumer.sh`](../tests/prod/200-php-consumer.sh) | The driver. Runs the gates it can, records the rest as explicit SKIPs, injects one mutation, emits a record. |
| [`scripts/report-consumer-validation.sh`](../scripts/report-consumer-validation.sh) | Shared reporter that assembles the record. |
| [`schemas/consumer-validation.schema.json`](../schemas/consumer-validation.schema.json) | Record contract (jq-structural here, ajv in CI). |

## Tool groups — one-of per dimension

The PHP profile accepts alternatives; the fixture selects one from each set and the driver
asserts a member of each group is present:

| Dimension | Selected in fixture | Accepted one-of set |
|-----------|--------------------|---------------------|
| Tests | `phpunit/phpunit` | **PHPUnit** \| **Pest** |
| Static analysis | `phpstan/phpstan` (level `max`) | **PHPStan** \| **Psalm** |
| Style | `laravel/pint` | **Pint** \| **PHP-CS-Fixer** |

## What runs here vs. what is deferred (composer/php absent)

The sandbox that runs `sh scripts/self-test.sh production-readiness` has **no `composer` and
no `php`**. The driver therefore splits gates into two honest classes.

### Runnable now (structural, offline)

- `manifest_valid_json` — `composer.json` parses.
- `psr4_autoload` — `autoload.psr-4["App\\"] == "src/"`.
- `test_toolgroup` / `static_analysis_toolgroup` / `style_toolgroup` — one-of resolution.
- `phpstan_config` — `phpstan.neon.dist` present, declares a `level`.
- `style_config` — `pint.json` valid JSON (or `.php-cs-fixer.php`).
- `seeded_findings` — both intentional defects are still in `src/Calculator.php`.

### Deferred to CI — recorded as `status: "skip"` (a SKIP is NOT a pass)

Each carries a stable `reason_code` so CI can enumerate the deferred work:

| Gate | reason_code |
|------|-------------|
| `composer_validate` | `TOOLCHAIN_ABSENT_COMPOSER` |
| `phpunit_run` | `TOOLCHAIN_ABSENT_PHP` |
| `phpstan_analyse` | `TOOLCHAIN_ABSENT_PHP` |
| `pint_check` | `TOOLCHAIN_ABSENT_PHP` |
| `php_syntax_lint` | `TOOLCHAIN_ABSENT_PHP` |

Because SKIP gates exist, the record's `result` is **`partial`**, never `pass`. A `partial`
record cannot satisfy a `framework-validated`/`full-platform` release gate on its own — the
real CI run (with the toolchain) that flips those SKIPs to `pass`/`fail` is what counts. See
the runbook's [structural-vs-GitHub-verified](consumer-validation-runbook.md#structural-vs-github-verified-evidence)
section.

## The seeded defects (intentional payload)

`src/Calculator.php` ships two deliberate findings so the real CI gates have something to
catch — this is how we prove the gates are not no-ops:

1. **Style** (`Calculator::divide()`) — non-canonical indentation/braces that
   `pint --test` reports.
2. **Static analysis** (`Calculator::riskyLength()`) — `strlen(int)`; PHPStan at `level: max`
   reports a type error.

`phpstan.neon.dist` deliberately carries **no baseline** for the seeded finding — baselining
it would hide the very thing under test. The driver's `seeded_findings` gate greps for the
`SEEDED-STYLE-FINDING` / `SEEDED-PHPSTAN-FINDING` markers, so silently deleting the payload
fails the build.

## The mutation (proving a runnable gate bites)

The driver injects **one** fault against a gate it *can* run: it removes
`phpstan/phpstan` from a throwaway **copy** of `composer.json`, re-runs the
static-analysis one-of detector, and asserts it now reports **missing**:

```
mutation.target_gate      = static_analysis_toolgroup
mutation.expected_status  = fail
mutation.observed_status  = fail
mutation.reason_code      = STATIC_ANALYSIS_TOOL_MISSING
mutation.caught           = true
```

The real fixture is left untouched (the driver re-asserts it still resolves `phpstan`). This
is the offline analogue of "inject a failing test / phpstan error and watch the correct gate
go red" — done at the one gate the sandbox can actually execute.

## composer.lock policy

`composer.lock` is **not committed** and `vendor/` is `.gitignore`d. CI regenerates both with
`composer install` at the release ref, then runs `composer validate --strict`. We do not
hand-fake a lock (unresolvable hashes) nor commit an instantly-stale one — per the honesty
mandate, an absent lock that CI regenerates beats a fake green one.

## Running it

```sh
# Just this consumer:
sh tests/prod/200-php-consumer.sh            # prints PASS/FAIL lines + the record on stderr

# As part of the whole production-readiness suite (auto-discovered):
sh scripts/self-test.sh production-readiness
```

Exit `0` = all runnable assertions passed (with explicit CI-deferred SKIPs); `1` = an
assertion failed. The emitted record is echoed to stderr for CI log capture.
