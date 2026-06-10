<?php

declare(strict_types=1);

namespace App\Application\Order;

use App\Domain\Order\Order;
use App\Domain\Order\OrderRepository;

/**
 * Application use-case handler. Depends on Domain only (the Order entity and the
 * OrderRepository port) — Application -> Domain is ALLOWED. It must NOT reference
 * any concrete Infrastructure class.
 */
final class PlaceOrderHandler
{
    private OrderRepository $orders;

    public function __construct(OrderRepository $orders)
    {
        $this->orders = $orders;
    }

    public function handle(string $id): Order
    {
        $order = new Order($id);
        $this->orders->save($order);

        return $order;
    }
}
