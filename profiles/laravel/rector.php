<?php

declare(strict_types=1);

/**
 * Sentinel Shield — Laravel Rector configuration.
 *
 * Rector performs automated, safe refactors and helps keep code on modern PHP and
 * Laravel idioms. Always run dry-run first in CI; apply locally and review the diff.
 *
 *   vendor/bin/rector process --dry-run   # CI: shows changes, does not write
 *   vendor/bin/rector process             # local: applies changes
 *
 * Requires:
 *   composer require --dev rector/rector driftingly/rector-laravel
 */

use Rector\Config\RectorConfig;
use Rector\Php83\Rector\ClassMethod\AddOverrideAttributeToOverriddenMethodsRector;
use Rector\Set\ValueObject\LevelSetList;
use Rector\Set\ValueObject\SetList;
use Rector\CodeQuality\Rector\Class_\InlineConstructorDefaultToPropertyRector;

return static function (RectorConfig $rectorConfig): void {
    $rectorConfig->paths([
        __DIR__ . '/app',
        __DIR__ . '/routes',
        __DIR__ . '/database',
        __DIR__ . '/tests',
    ]);

    $rectorConfig->skip([
        __DIR__ . '/bootstrap',
        __DIR__ . '/storage',
        __DIR__ . '/vendor',
    ]);

    // Target the PHP version the project runs on. Keep in sync with composer.json.
    $rectorConfig->sets([
        LevelSetList::UP_TO_PHP_83,
        SetList::CODE_QUALITY,
        SetList::DEAD_CODE,
        SetList::TYPE_DECLARATION,
    ]);

    // Enable rules that are safe and high-value for most apps.
    $rectorConfig->rule(InlineConstructorDefaultToPropertyRector::class);
    $rectorConfig->rule(AddOverrideAttributeToOverriddenMethodsRector::class);

    // Import short class names rather than leaving FQCN inline.
    $rectorConfig->importNames();
    $rectorConfig->importShortClasses(false);

    // Add Laravel-specific sets once driftingly/rector-laravel is installed, e.g.:
    // $rectorConfig->sets([\RectorLaravel\Set\LaravelSetList::LARAVEL_110]);
};
