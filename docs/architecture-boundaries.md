# Architecture Boundaries

Architecture rules exist so that security and change-safety are structural, not
incidental. Boundaries are enforced with Deptrac (PHP) and ESLint import rules
(Node/React), and violations block per [`../RELEASE-GATES.md`](../RELEASE-GATES.md).

The model is layered Clean Architecture / DDD with optional CQRS.

---

## Layer rules

```txt
Domain          Pure business rules. Entities, value objects, domain services.
Application     Use cases / handlers. Orchestrates the domain.
Infrastructure  Adapters: DB, HTTP clients, queues, framework integration.
Presentation    Controllers, CLI, HTTP, UI. Calls use cases.
```

Dependency direction (who may depend on whom):

```txt
Domain          → (nothing)            Domain cannot depend on Infrastructure.
                                        Domain cannot depend on the Framework.
Application     → Domain               Application may depend on Domain only.
Infrastructure  → Domain, Application  Infrastructure implements ports/interfaces
                                        defined by Domain/Application.
Presentation    → Application          Presentation calls use cases, not the DB.
```

Key invariants:

- **Domain cannot depend on Infrastructure or the Framework.** No Eloquent,
  Doctrine, HTTP, or framework facades in the domain layer.
- **Application depends on Domain only.** It defines ports (interfaces); it does not
  know concrete adapters.
- **Infrastructure implements ports.** Concrete DB/HTTP/queue adapters live here and
  satisfy interfaces declared higher up (dependency inversion).
- **Presentation calls use cases.** Controllers translate transport to use-case
  input and back; they contain no business logic.

---

## Module communication

- Modules (bounded contexts) communicate through explicit contracts: published
  interfaces, application services, domain events, or APIs.
- No reaching into another module's internal classes or database tables.
- Cross-module calls go through a contract, an event, or an API — never a direct
  import of internals.

```txt
Module A  --(contract / event / API)-->  Module B
   |                                         |
   internals private                    internals private
```

---

## Tenant boundaries

For multi-tenant systems (common in casino/compliance contexts):

- Tenant boundaries must be **explicit** in the data model and enforced in the
  application layer, not assumed from request context alone.
- Every tenant-scoped query is filtered by tenant; global queries are reviewed.
- Cross-tenant access is a high-risk change requiring security review.
- Tests assert that tenant A cannot read or mutate tenant B's data.

---

## Enforcement

| Stack | Tool | Config |
| --- | --- | --- |
| Laravel | Deptrac | [`../profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml) |
| Symfony | Deptrac | [`../profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml) |
| Node/React | ESLint import boundaries | profile `eslint.config.js` |

Deptrac defines layers by path/namespace and rules for allowed dependencies. Start
in report-only (`--report-uncovered` off, violations visible) and make violations
blocking once the existing graph is clean.
