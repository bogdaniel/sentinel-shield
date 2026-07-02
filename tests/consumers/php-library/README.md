# php-library consumer fixture

A **framework-agnostic PHP library** (`stack: php_library`) used as a real-consumer
validation target for Sentinel Shield. It is a plain [Composer](https://getcomposer.org)
package with PSR-4 autoloading — it is **NOT a Laravel or Symfony application** and pulls
in no framework runtime. That is the point: it proves Sentinel Shield's PHP profile works
on a library it does not own, independent of any framework.

## Layout

| Path | Purpose |
|------|---------|
| `composer.json` | Package manifest. `require-dev` pins one tool per quality dimension. |
| `src/Calculator.php` | Library code carrying two **intentional** seeded defects (see below). |
| `tests/CalculatorTest.php` | PHPUnit suite covering the clean methods. |
| `phpstan.neon.dist` | PHPStan at `level: max`, no baseline. |
| `pint.json` | Laravel Pint style config (the style tool for this fixture). |
| `phpunit.xml.dist` | PHPUnit runner config. |

## Tool groups (one-of per dimension)

Sentinel Shield accepts alternatives; this fixture selects one from each:

| Dimension | Selected | Accepted alternatives |
|-----------|----------|-----------------------|
| Tests | `phpunit/phpunit` | Pest |
| Static analysis | `phpstan/phpstan` | Psalm |
| Style | `laravel/pint` | PHP-CS-Fixer |

## Seeded defects (do NOT "fix")

`src/Calculator.php` deliberately carries two findings so the CI gates have something real
to catch:

1. **Style** — `Calculator::divide()` is mis-indented / non-canonical; `pint --test` flags it.
2. **Static analysis** — `Calculator::riskyLength()` calls `strlen()` on an `int`; PHPStan
   at `level: max` reports a type error.

The driver `tests/prod/200-php-consumer.sh` asserts the seed markers are present, so a
silent removal of the payload is itself a test failure.

## composer.lock

`composer.lock` is **intentionally not committed** and is listed as a regenerated artifact.
CI runs `composer install` (or `composer update` on first pin) at the exact release ref to
produce it, then `composer validate --strict`. Hand-committing a lock here would either be a
**fake** (unresolvable hashes) or immediately stale; per the honesty mandate we do neither.
`vendor/` is likewise `.gitignore`d and reconstructed in CI.

## Running the gates

Locally, once `composer`/`php` are installed and `composer install` has run:

```sh
composer install
vendor/bin/phpunit                          # tests
vendor/bin/phpstan analyse --no-progress    # static analysis (will report the seeded finding)
vendor/bin/pint --test                      # style (will report the seeded finding)
```

In an environment WITHOUT `composer`/`php` (the current sandbox), those three gates are
reported as **SKIP** with a `TOOLCHAIN_ABSENT_*` reason code by the driver — a skip is not a
pass. See [`docs/php-library-validation.md`](../../../docs/php-library-validation.md).
