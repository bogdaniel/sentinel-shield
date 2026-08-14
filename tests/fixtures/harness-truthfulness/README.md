# Harness-truthfulness fixtures

Deliberately broken and deliberately correct shell fixtures for `tests/prod/306`.

They are **not** production tests and must never be discovered as such. Two properties keep
them out: they live outside `tests/prod/`, and none of them is named `NNN-*.sh`. `306` asserts
both, because a broken fixture that leaked into the production sweep would fail the sweep for
the wrong reason — and a fixture that silently stopped being discovered by `306` would take its
detector's evidence with it.

Each detector has a `bad-*` fixture it must reject and a `good-*` control it must accept.
