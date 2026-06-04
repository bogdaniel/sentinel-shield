<?php

declare(strict_types=1);

/**
 * Sentinel Shield — Symfony PHP-CS-Fixer configuration.
 *
 * PSR-12 base plus the Symfony ruleset and strictness rules.
 *
 *   vendor/bin/php-cs-fixer fix --dry-run --diff   # CI: check only
 *   vendor/bin/php-cs-fixer fix                     # local: apply
 *
 * Requires:
 *   composer require --dev friendsofphp/php-cs-fixer
 */

$finder = (new PhpCsFixer\Finder())
    ->in(__DIR__ . '/src')
    ->in(__DIR__ . '/tests')
    ->exclude(['var', 'vendor']);

return (new PhpCsFixer\Config())
    ->setRiskyAllowed(true)
    ->setRules([
        '@PSR12' => true,
        '@Symfony' => true,
        '@Symfony:risky' => true,
        'declare_strict_types' => true,
        'strict_comparison' => true,
        'strict_param' => true,
        'no_unused_imports' => true,
        'ordered_imports' => ['sort_algorithm' => 'alpha'],
        'global_namespace_import' => [
            'import_classes' => true,
            'import_constants' => false,
            'import_functions' => false,
        ],
        'native_function_invocation' => ['include' => ['@compiler_optimized'], 'scope' => 'namespaced'],
        'single_quote' => true,
        'trailing_comma_in_multiline' => ['elements' => ['arrays', 'arguments', 'parameters']],
        'phpdoc_align' => false,
    ])
    ->setFinder($finder)
    ->setCacheFile(__DIR__ . '/var/.php-cs-fixer.cache');
