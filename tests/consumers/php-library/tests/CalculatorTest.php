<?php

declare(strict_types=1);

namespace App\Tests;

use App\Calculator;
use PHPUnit\Framework\TestCase;

/**
 * PHPUnit suite for the PHP-library consumer fixture.
 *
 * These assertions exercise the CLEAN methods only. The seeded style / static-analysis
 * defects on Calculator::divide() and Calculator::riskyLength() are caught by the Pint
 * and PHPStan gates, not here — a green PHPUnit run alongside a red PHPStan/Pint run is
 * exactly what proves the gates are independent.
 */
final class CalculatorTest extends TestCase
{
    public function test_add_sums_two_integers(): void
    {
        $calc = new Calculator();
        self::assertSame(5, $calc->add(2, 3));
    }

    public function test_subtract_returns_difference(): void
    {
        $calc = new Calculator();
        self::assertSame(-1, $calc->subtract(2, 3));
    }

    public function test_divide_returns_float_quotient(): void
    {
        $calc = new Calculator();
        self::assertSame(2.5, $calc->divide(5, 2));
    }

    public function test_divide_by_zero_throws(): void
    {
        $calc = new Calculator();
        $this->expectException(\InvalidArgumentException::class);
        $calc->divide(1, 0);
    }
}
