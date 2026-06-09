<?php

declare(strict_types=1);

namespace Fixture\Modern;

use Attribute;

#[Attribute(Attribute::TARGET_CLASS)]
final class Tag
{
    public function __construct(public readonly string $name) {}
}

enum Status: string
{
    case Active = 'active';
    case Inactive = 'inactive';

    public function label(): string
    {
        return match ($this) {
            Status::Active => 'Active',
            Status::Inactive => 'Inactive',
        };
    }
}

#[Tag('user')]
final class User
{
    public int $id = 0;                       // typed property

    public function __construct(
        public readonly string $email,        // constructor property promotion + readonly
        private readonly Status $status = Status::Active,
    ) {}

    public function describe(): string
    {
        return match (true) {
            $this->status === Status::Active => "{$this->email} active",
            default => "{$this->email} inactive",
        };
    }
}
