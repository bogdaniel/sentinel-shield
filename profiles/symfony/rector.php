<?php

declare(strict_types=1);

/**
 * Sentinel Shield — Symfony Rector configuration.
 *
 *   vendor/bin/rector process --dry-run   # CI: preview
 *   vendor/bin/rector process             # local: apply, then review diff
 *
 * Requires:
 *   composer require --dev rector/rector rector/rector-symfony
 */

use Rector\Config\RectorConfig;
use Rector\Set\ValueObject\LevelSetList;
use Rector\Set\ValueObject\SetList;

return static function (RectorConfig $rectorConfig): void {
    $rectorConfig->paths([
        __DIR__ . '/src',
        __DIR__ . '/tests',
    ]);

    $rectorConfig->skip([
        __DIR__ . '/var',
        __DIR__ . '/vendor',
        __DIR__ . '/src/Kernel.php',
    ]);

    $rectorConfig->sets([
        LevelSetList::UP_TO_PHP_83,
        SetList::CODE_QUALITY,
        SetList::DEAD_CODE,
        SetList::TYPE_DECLARATION,
    ]);

    // Symfony sets (once rector/rector-symfony is installed), e.g.:
    // $rectorConfig->sets([\Rector\Symfony\Set\SymfonySetList::SYMFONY_70]);
    // $rectorConfig->symfonyContainerXml(__DIR__ . '/var/cache/dev/App_KernelDevDebugContainer.xml');

    $rectorConfig->importNames();
    $rectorConfig->importShortClasses(false);
};
