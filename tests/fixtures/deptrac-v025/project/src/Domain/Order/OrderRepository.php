<?php

declare(strict_types=1);

namespace App\Domain\Order;

/**
 * Port (interface) declared in the Domain layer. Implementations live in
 * Infrastructure. This is the inward-pointing dependency Clean Architecture wants.
 */
interface OrderRepository
{
    public function save(Order $order): void;

    public function find(string $id): ?Order;
}
