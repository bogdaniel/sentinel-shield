# Deptrac Validation (v0.1.25) — Real-Run Evidence + Setup

This document records a **real** Deptrac run against a purpose-built layered PHP
fixture, the resulting artifacts, how the Sentinel Shield Deptrac collector maps
them, and how to wire Deptrac into Laravel and Symfony projects. Unlike the
v0.1.24 fixtures (hand-authored JSON exercising count mappings only), the
`deptrac-clean.json` and `deptrac-violations.json` fixtures here were **produced
by a real `deptrac analyse` invocation** — see §83 for the evidence.

> **Honesty contract.** Deptrac is only marked "live-validated" because a REAL
> deptrac binary (deptrac/deptrac 4.6.1) produced a REAL `deptrac.json` from a
> real PHP source tree. If you cannot reproduce a real run, fall back to these
> fixtures and treat the result as **fixture-backed, not live**. Never emit a
> clean result when nothing was analysed — absence is `unavailable`, not `pass`.

---

## Fixtures in this directory

| File | Purpose | Origin |
|---|---|---|
| `project/` | Minimal layered PHP project (Domain / Application / Infrastructure) + `deptrac.yaml` + `composer.json` | Hand-authored source; runnable for a real Deptrac analysis |
| `deptrac.yaml` | The exact config that produced the artifacts (copy of `project/deptrac.yaml`) | Hand-authored |
| `deptrac-clean.json` | `Report.Violations: 0` | **REAL deptrac 4.6.1 output** (clean variant of the project) |
| `deptrac-violations.json` | `Report.Violations: 2` | **REAL deptrac 4.6.1 output** (two deliberate breaches) |
| `deptrac-invalid.json` | Malformed JSON | Hand-authored (collector error-path test) |

The fixture project layout:

```
project/
  composer.json                 # require-dev: deptrac/deptrac ^4, PSR-4 App\ -> src/
  deptrac.yaml                  # src/, inward-only layered ruleset
  src/Domain/Order/Order.php            # entity; contains a deliberate Domain->Infrastructure breach
  src/Domain/Order/OrderRepository.php  # port (interface) declared in Domain
  src/Application/Order/PlaceOrderHandler.php  # use-case handler (Domain-only deps)
  src/Infrastructure/Persistence/DoctrineOrderRepository.php  # adapter implementing the port
```

---

## 83. Real Deptrac run — attempt result (THE honesty line)

**Result: REAL RUN SUCCEEDED.** A genuine Deptrac binary analysed the fixture and
emitted a genuine JSON report.

- Docker image `qossmic/deptrac:latest` / `ghcr.io/qossmic/deptrac` / `smordev/deptrac`:
  **not available** (pull access denied / not found). No prebuilt Deptrac image
  exists on Docker Hub or GHCR.
- Deptrac dropped the standalone `.phar` release asset; `releases/latest` of
  `qossmic/deptrac` 404s. The project moved to **`deptrac/deptrac`**, latest
  **4.6.1**, distributed via Composer only.
- Real run path used: official `composer:2` image →
  `composer require --dev deptrac/deptrac:^4` (installed **deptrac/deptrac 4.6.1**,
  PHP 8.5.6) → `vendor/bin/deptrac analyse --config-file=deptrac.yaml
  --formatter=json --output=deptrac.json --no-progress`.
  - Note: the v4 CLI flag is `--formatter=json` (not `--report-type`).

Verbatim real outputs:

```
deptrac 4.6.1
```

Violations artifact (`deptrac-violations.json`, deptrac exit code 1 — failures present):

```json
{
    "Report": { "Violations": 2, "Skipped violations": 0, "Uncovered": 0, "Allowed": 10, "Warnings": 0, "Errors": 0 },
    "files": {
        "/app/src/Application/Order/PlaceOrderHandler.php": {
            "messages": [{ "message": "App\\Application\\Order\\PlaceOrderHandler must not depend on App\\Infrastructure\\Persistence\\DoctrineOrderRepository (Application on Infrastructure)", "line": 35, "type": "error" }],
            "violations": 1
        },
        "/app/src/Domain/Order/Order.php": {
            "messages": [{ "message": "App\\Domain\\Order\\Order must not depend on App\\Infrastructure\\Persistence\\DoctrineOrderRepository (Domain on Infrastructure)", "line": 30, "type": "error" }],
            "violations": 1
        }
    }
}
```

Clean artifact (`deptrac-clean.json`, deptrac exit code 0):

```json
{ "Report": { "Violations": 0, "Skipped violations": 0, "Uncovered": 0, "Allowed": 10, "Warnings": 0, "Errors": 0 }, "files": [] }
```

The clean and violations variants differ only by the two deliberate breaches; both
were produced by the same real binary against the same `deptrac.yaml`. The
collector parses the `.Report.Violations` number, so both artifacts exercise the
production parse path.

### Reproduce the real run

```sh
cd tests/fixtures/deptrac-v025/project
docker run --rm -v "$PWD":/app -w /app composer:2 sh -c '
  composer require --dev --no-interaction deptrac/deptrac:^4 &&
  vendor/bin/deptrac analyse --config-file=deptrac.yaml --formatter=json --output=deptrac.json --no-progress
'
cat deptrac.json
# then: scripts/collectors/deptrac.sh --input deptrac.json
```

(The committed fixture project is kept minimal — `vendor/`, `composer.lock`, and the
generated `deptrac.json` are not committed; the command above regenerates them.)

---

## Collector behaviour (verified locally, v0.1.25)

Running `scripts/collectors/deptrac.sh` against these fixtures produced:

| Input | `architecture_violations` | `status` | exit |
|---|---|---|---|
| `deptrac-clean.json` | `0` | `pass` | 0 |
| `deptrac-violations.json` | `2` | `fail` | 0 |
| `deptrac-invalid.json` (malformed) | — | error | **2** |
| missing file | `0` | `unavailable` | 0 |

The collector reads `.Report.Violations` (the second branch of the defensive
parser in `scripts/collectors/deptrac.sh`), folds it into the canonical summary as
`architecture_violations`, sets `fail` when nonzero and `pass` when zero. Malformed
JSON exits 2; a missing/empty report emits `status=unavailable` and exits 0 — never
a fake `pass`.

---

## 92. Laravel / Symfony Deptrac setup

Both frameworks install Deptrac the same way and differ only in the source root and
presentation namespace. Use the shipped profiles as the starting point:

- **Laravel** → [`profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml):
  paths `./app`, presentation `App\Http\*`.
- **Symfony** → [`profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml):
  paths `./src`, presentation `App\Controller\*`.

Install and run (Deptrac 4, Composer-only — no PHAR):

```sh
composer require --dev deptrac/deptrac:^4
vendor/bin/deptrac analyse --config-file=deptrac.yaml --formatter=json \
  --output=reports/raw/deptrac.json --no-progress
scripts/collectors/deptrac.sh --input reports/raw/deptrac.json
```

Framework specifics:

- **Laravel** — the default skeleton scatters logic across `app/Http`, `app/Models`,
  and service providers, so Clean-Architecture layering is opt-in. Wrap Eloquent
  behind repository interfaces declared in `Domain`/`Application` and implemented in
  `Infrastructure`. Calling a Facade from `Domain` is a boundary smell Deptrac flags
  once `App\Domain` is mapped.
- **Symfony** — keep Doctrine entities in `Domain` only if persistence-ignorant; if
  they carry ORM mapping attributes, move them to `Infrastructure` or a dedicated
  mapping layer. Controllers depend on Application handlers (via the message bus),
  never on Infrastructure repositories directly.

Older docs may show `composer require --dev qossmic/deptrac-shim` and
`--report-json=...`. For Deptrac 4 use `deptrac/deptrac:^4` and `--formatter=json
--output=...`; the JSON shape (`.Report.Violations`) is unchanged.

## 93. Module (bounded-context) boundary example

Module boundaries stop one feature module reaching into another's internals. Map
each module as a layer and publish only an explicit API:

```yaml
layers:
  - name: Billing
    collectors: [{ type: classNameRegex, value: '#^App\\Billing\\.*#' }]
  - name: Catalog
    collectors: [{ type: classNameRegex, value: '#^App\\Catalog\\.*#' }]
  - name: BillingApi
    collectors: [{ type: classNameRegex, value: '#^App\\Billing\\Api\\.*#' }]
ruleset:
  Catalog:
    - BillingApi   # Catalog may use Billing's published API only
  Billing: ~       # Billing keeps its internals private
```

**Violation:** `App\Catalog\PriceSync` references `App\Billing\Internal\Ledger` →
a Catalog→Billing edge that is not allowed (only `BillingApi` is), `+1` to
`architecture_violations`. **Fix:** route the call through `App\Billing\Api\*`.

## 94. Layer boundary example (matches the real fixture)

The fixture enforces inward-only layering (`Domain` ← `Application`; `Infrastructure`
→ `Domain`; `Domain` depends on nothing internal):

```
Application ──> Domain
Infrastructure ──> Domain
Domain: ~   (no internal dependencies)
```

**Real violation (from `deptrac-violations.json`):**
`App\Domain\Order\Order` imports `App\Infrastructure\Persistence\DoctrineOrderRepository`.
Domain has ruleset `~`, so the Domain→Infrastructure edge is illegal — Deptrac
reported it verbatim:
`App\Domain\Order\Order must not depend on App\Infrastructure\Persistence\DoctrineOrderRepository (Domain on Infrastructure)`.
**Fix:** the `OrderRepository` interface is already declared in `Domain` and
implemented in `Infrastructure`; inject the port instead of referencing the concrete
adapter so the dependency points inward.

## 95. CQRS boundary example

Commands (writes) and queries (reads) stay separate, and neither leaks into the
other or onto the transport layer:

```yaml
layers:
  - name: Command
    collectors: [{ type: classNameRegex, value: '#^App\\Application\\Command\\.*#' }]
  - name: Query
    collectors: [{ type: classNameRegex, value: '#^App\\Application\\Query\\.*#' }]
  - name: Domain
    collectors: [{ type: classNameRegex, value: '#^App\\Domain\\.*#' }]
ruleset:
  Command: [Domain]   # command handlers mutate the domain model
  Query:   [Domain]   # read models project from domain / a read store
  Domain: ~
  # Command and Query must NOT depend on each other.
```

**Violation:** `App\Application\Query\OrderSummaryHandler` depends on
`App\Application\Command\PlaceOrderHandler` (a query reaching into the write path) →
a Query→Command edge the ruleset omits, `+1`. **Fix:** read from a dedicated read
model / projection instead of invoking a command handler.

## 96. Accepted-risk guidance

When a violation is real but intentionally accepted (e.g. a pragmatic shortcut with
a remediation date), record it explicitly — never hide it:

- Use Deptrac's `skip_violations` to list the **specific** class pairs knowingly
  accepted — never an empty-but-permissive catch-all. The collector still reports the
  remaining violations honestly.
- Pair each accepted item with a Sentinel Shield exception entry (owner, reason,
  expiry) so `expired_exceptions` surfaces it when the window lapses — accepted risk
  is time-boxed, not permanent.
- Document the trade-off in the PR/ADR. Accepted risk reduces the actionable count;
  it must never zero out an un-triaged breach.

## 97. False-positive guidance

Architecture findings are usually real, but these patterns produce noise:

- **Unmapped namespace** → shows as *uncovered* and can distort edges. Add a layer (or
  an explicit catch-all); do not silence by deleting the layer.
- **Shared kernel / value objects** (Money, Uuid, Result) trip layer rules. Model them
  as an explicit `SharedKernel` layer every layer may depend on, not per-class holes.
- **Framework base classes** can pull in unexpected vendor edges — restrict layers to
  your own `App\*` namespaces (as the profiles do) so vendor code is out of scope.
- **Interface vs. implementation** — a "violation" pointing at an interface in the
  right layer is usually a mapping-regex bug, not a real breach. Confirm the regex
  before suppressing.

Triage rule: confirm the edge is genuinely allowed-by-design before suppressing.
Never blanket-suppress to turn a `fail` green.

## 98. Architecture-policy notes

- Treat architecture checks as **blocking** (`architecture_violations > 0` fails the
  gate) only once the layer graph is already clean at adoption, collectors cover the
  codebase with no significant *uncovered* surface, and `skip_violations` is empty or
  only documented/time-boxed items. Until then run in **observe mode** (collect counts,
  do not block) and burn the graph down first.
- `unavailable` is a gate failure to investigate, not a pass — if Deptrac did not run,
  do not let the gate go green.
- In regulated contexts: retain every `reports/raw/deptrac.json` as audit evidence,
  tolerate no `unavailable` on protected paths, require approved exceptions (owner /
  justification / expiry), and review ruleset / `skip_violations` changes like code.

## 99. Profile-recommendation notes

Start from the shipped profiles and adapt — do not hand-roll from scratch:

- Symfony → [`profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml)
  (`src/`, `App\Controller\*` presentation).
- Laravel → [`profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml)
  (`app/`, `App\Http\*` presentation).

Both ship the same inward-only layered ruleset (`Domain` ← `Application` ←
`Presentation`; `Infrastructure` → Domain+Application). Adjust the `classNameRegex`
collectors to your real namespaces, add `SharedKernel` / module layers as needed
(§93, §95), keep `skip_violations` explicit, and begin in observe mode. The fixture
`project/deptrac.yaml` is a trimmed three-layer variant of the Symfony profile and is
the exact config that produced the real artifacts above.

## 100. Maturity line

**Promote ONLY if a real binary/artifact exists — and one does.** For v0.1.25 the
Deptrac collector contract is **live-validated against real Deptrac output**:
deptrac/deptrac **4.6.1** analysed the fixture project and produced the committed
`deptrac-clean.json` (`Report.Violations: 0`) and `deptrac-violations.json`
(`Report.Violations: 2`), and `scripts/collectors/deptrac.sh` mapped them to
`architecture_violations` `0`/`pass` and `2`/`fail` respectively (§83, collector
table above).

Scope of the claim — be precise:

- **Live-validated:** the collector's parse-and-map of a *real* Deptrac 4.6.1 JSON
  report (the `.Report.Violations` shape) on a real layered PHP tree.
- **Still not validated:** a live run on a *real pilot consumer* repository that
  ships its own `deptrac.yaml` over its own architecture. No pilot consumer ships
  Deptrac config yet, so end-to-end product adoption remains experimental /
  only-if-configured per `product-status.md`. The fixture project is a controlled
  minimal app, not a production consumer.

Net: the **collector ↔ real Deptrac artifact** contract is proven; **product-level
Deptrac adoption** is not. Configure deliberately, run in observe mode first, and
never emit a clean result when nothing was analysed.
