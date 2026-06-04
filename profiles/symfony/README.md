# Symfony Profile

Sentinel Shield baseline for Symfony 6/7 (PHP 8.3+, PSR-12, app code in `src/`).

## What's here

| File | Purpose |
| --- | --- |
| `phpstan.neon` | PHPStan + Symfony + Doctrine extensions |
| `psalm.xml` | Psalm with Symfony plugin + taint tracking |
| `php-cs-fixer.php` | PHP-CS-Fixer (PSR-12 + Symfony rules + strictness) |
| `deptrac.yaml` | Architecture boundary enforcement |
| `rector.php` | Automated refactors (dry-run in CI) |

## Install

```sh
cp phpstan.neon psalm.xml php-cs-fixer.php deptrac.yaml rector.php /path/to/project/
# rename php-cs-fixer.php to .php-cs-fixer.dist.php if you prefer the dist convention
composer require --dev phpstan/phpstan phpstan/extension-installer \
    phpstan/phpstan-symfony phpstan/phpstan-doctrine \
    vimeo/psalm psalm/plugin-symfony \
    friendsofphp/php-cs-fixer rector/rector rector/rector-symfony \
    qossmic/deptrac-shim
```

## Run

```sh
php bin/console cache:warmup --env=dev          # needed for container-aware analysis
vendor/bin/phpstan analyse --memory-limit=1G
vendor/bin/psalm --no-cache
vendor/bin/psalm --taint-analysis --no-cache
vendor/bin/php-cs-fixer fix --dry-run --diff
vendor/bin/deptrac analyse --config-file=deptrac.yaml
composer audit --locked
```

## Assumptions

- Namespaces follow `App\Domain`, `App\Application`, `App\Infrastructure`,
  `App\Controller`. Adjust `deptrac.yaml` if different.
- The compiled container XML path matches `var/cache/dev/...`. Update
  `containerXmlPath` in `phpstan.neon` and `psalm.xml` if your kernel class differs.

## Notes

- Generate baselines for legacy debt before making analysers blocking.
- Each suppression should be justified and, in `regulated` mode, tracked as an
  exception.
