<?php

declare(strict_types=1);

namespace App\Domain\Order;

use App\Infrastructure\Persistence\DoctrineOrderRepository;

/**
 * Domain entity that ILLEGALLY reaches into the Infrastructure layer.
 *
 * The `use` of DoctrineOrderRepository below is a deliberate boundary breach:
 * Domain has ruleset `~` (may depend on nothing internal), so a
 * Domain -> Infrastructure edge is disallowed and Deptrac reports it.
 */
final class Order
{
    private string $id;

    public function __construct(string $id)
    {
        $this->id = $id;
    }

    public function id(): string
    {
        return $this->id;
    }

    public function persistVia(DoctrineOrderRepository $repository): void
    {
        // Boundary breach: Domain must not know a concrete Infrastructure adapter.
        $repository->save($this);
    }
}
