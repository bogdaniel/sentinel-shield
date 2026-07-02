<?php

declare(strict_types=1);

namespace App;

/**
 * A tiny, framework-agnostic value helper used as the PHP-library consumer fixture.
 *
 * This class deliberately carries TWO seeded defects so the real CI gates have
 * something concrete to catch:
 *
 *   1. STYLE (Pint / PHP-CS-Fixer): {@see divide()} below is indented with spaces
 *      and uses a non-canonical brace/blank-line layout that Laravel Pint's default
 *      preset reformats. `pint --test` reports it as a style violation.
 *
 *   2. STATIC ANALYSIS (PHPStan level max): {@see riskyLength()} calls strlen() on a
 *      parameter typed `int`, which PHPStan flags as
 *      "Parameter #1 $string of function strlen expects string, int given".
 *
 * Both are INTENTIONAL. Do not "fix" them — they are the fixture's payload. The
 * driver (tests/prod/200-php-consumer.sh) asserts the markers below are present so a
 * silent removal is caught.
 */
final class Calculator
{
    public function add(int $a, int $b): int
    {
        return $a + $b;
    }

    public function subtract(int $a, int $b): int
    {
        return $a - $b;
    }

    // SEEDED-STYLE-FINDING: intentionally mis-formatted for Pint to flag.
    public function divide(int $a,int $b): float
    {
            if ($b === 0) {
                throw new \InvalidArgumentException('division by zero');
            }
        return $a / $b;
    }

    /**
     * SEEDED-PHPSTAN-FINDING: passes an int where strlen() expects a string.
     * PHPStan at level max reports this as a type error.
     */
    public function riskyLength(int $value): int
    {
        return strlen($value);
    }
}
