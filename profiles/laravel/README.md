# Laravel Profile

Sentinel Shield baseline for modern Laravel (PHP 8.3+, PSR-12, app code in `app/`).

## What's here

| File | Purpose |
| --- | --- |
| `phpstan.neon` | PHPStan + Larastan static analysis |
| `psalm.xml` | Psalm static analysis with taint tracking |
| `pint.json` | Laravel Pint (PSR-12 + strictness) |
| `deptrac.yaml` | Architecture boundary enforcement |
| `rector.php` | Automated refactors (dry-run in CI) |
| `composer.json.security-scripts.example` | Dev deps + `composer` scripts |

## Install

```sh
# Copy configs into the project root.
cp phpstan.neon psalm.xml pint.json deptrac.yaml rector.php /path/to/project/

# Merge require-dev and scripts from the example into composer.json, then:
composer install
```

## Run

```sh
composer quality        # phpstan + psalm + pint + deptrac + test
composer psalm:taint    # taint analysis (slower; run in security CI)
composer security:audit # composer audit --locked
composer rector:dry     # preview refactors
```

## Assumptions

- Namespaces follow `App\Domain`, `App\Application`, `App\Infrastructure`, `App\Http`
  for Deptrac. Adjust `deptrac.yaml` collectors if your layout differs.
- New code declares `strict_types=1` (enforced by Pint).
- PHPStan starts at level 6 and Psalm at errorLevel 4 — both migration-friendly.
  Raise toward PHPStan max / Psalm level 1 for `strict` mode, using baselines for
  legacy debt.

## Notes

- Generate baselines so legacy debt does not block new work:
  - `vendor/bin/phpstan analyse --generate-baseline`
  - `vendor/bin/psalm --set-baseline=psalm-baseline.xml`
- Every `ignoreErrors` / suppression should be justified and, in `regulated` mode,
  linked to an exception record.
