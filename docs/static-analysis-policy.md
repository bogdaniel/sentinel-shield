# Static Analysis Policy (v0.1.14)

Deterministic static analysis on the PR-fast/main gates. Summary keys: `type_errors`
(PHPStan/Larastan, Psalm, tsc, ESLint errors), `php_syntax_errors` (php -l), `style_violations`
(Pint/PHP-CS-Fixer/PHPCS), `architecture_violations` (Deptrac, architecture tests).

| Tool | Runner | Raw | Maps to | Gate |
|---|---|---|---|---|
| PHPStan/Larastan | runners/laravel-phpstan.sh | phpstan.json | type_errors | baseline+ |
| Psalm | runners/psalm.sh | psalm.json | type_errors | opt-in |
| php -l | runners/php-syntax.sh | php-syntax.json | php_syntax_errors | baseline+ |
| Pint/PHP-CS-Fixer | runners/php-style.sh | php-style.json | style_violations | strict+ |
| ESLint | runners/eslint.sh | eslint.json | type_errors/med/high | baseline+ |
| tsc --noEmit | runners/typescript.sh | typescript.json | type_errors | baseline+ |
| Deptrac | runners/deptrac.sh | deptrac.json | architecture_violations | baseline+ |
| architecture tests | runners/architecture-tests.sh | architecture-tests.json | architecture_violations | opt-in |

Missing tool → unavailable (never fake-clean). Triage:
[`remediation/phpstan-psalm-triage.md`](remediation/phpstan-psalm-triage.md),
[`remediation/deptrac-architecture-triage.md`](remediation/deptrac-architecture-triage.md).
PHPStan baseline debt: keep a `phpstan-baseline.neon` and shrink it over time (never regenerate to hide new errors).
