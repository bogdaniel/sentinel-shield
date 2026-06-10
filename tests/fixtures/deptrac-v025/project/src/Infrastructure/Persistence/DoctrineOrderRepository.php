<?php

declare(strict_types=1);

namespace App\Infrastructure\Persistence;

use App\Domain\Order\Order;
use App\Domain\Order\OrderRepository;

/**
 * Infrastructure adapter. Depending on Domain (the Order entity + OrderRepository
 * port) is ALLOWED — Infrastructure -> Domain points inward.
 */
final class DoctrineOrderRepository implements OrderRepository
{
    /** @var array<string, Order> */
    private array $store = [];

    public function save(Order $order): void
    {
        $this->store[$order->id()] = $order;
    }

    public function find(string $id): ?Order
    {
        return $this->store[$id] ?? null;
    }
}
