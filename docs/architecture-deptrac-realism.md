# Architecture & Deptrac Realism (v0.1.24)

How Sentinel Shield's architecture-boundary checks behave in practice: what the
Deptrac and architecture-tests collectors expect on clean and violating inputs,
how to wire Deptrac into Symfony and Laravel projects, worked boundary examples,
and how to triage findings honestly without emitting fake-clean results.

> **Maturity — be honest.** Architecture-boundary enforcement (Deptrac and the
> generic `architecture-tests` collector) is **experimental** and
> **only-if-configured**. Per [`product-status.md`](product-status.md): Deptrac is
> **not live-validated** — no pilot consumer ships a `deptrac.yaml`, and the
> main-branch gate lists Deptrac among the **unproven** tools. Nothing in this
> document is promoted to `supported`; promotion requires a real, cited run on a
> repository that actually defines architecture layers. **Never emit a clean
> result when there was nothing to analyse** — absent config or absent binary must
> surface as `unavailable`, not `pass`.

The fixtures referenced here live under `tests/fixtures/deptrac-v024/` and
`tests/fixtures/architecture-v024/`. They let the self-test harness exercise the
collector count mappings **without** installing Deptrac or any architecture-test
runner. They are test inputs, not evidence of a live consumer run.

---

## Collector contract (recap)

| Collector | Script | Reads | Maps to |
|---|---|---|---|
| Deptrac | `scripts/collectors/deptrac.sh` | `.report.violations` \| `.Report.Violations` (number) \| `.violations` (array→length, or number) | `architecture_violations` |
| architecture-tests | `scripts/collectors/architecture-tests.sh` | `(.violations // .failures // 0)`, array→length else number, floored | `architecture_violations` |

Both collectors guard their input: a missing or empty file emits
`status=unavailable` and exits 0; invalid JSON exits 2. A nonzero count sets
`status=fail`; zero sets `status=pass`. Both fold the count into the canonical
collector summary under `architecture_violations`.

The v0.1.24 fixtures use the `.Report.Violations` shape for Deptrac (the second
branch of the defensive parser) and the bare `.violations` number for
architecture-tests.

---

## 164. Deptrac collector — clean test expectation

**Input:** `tests/fixtures/deptrac-v024/deptrac-clean.json`

```json
{ "Report": { "Violations": 0, "Skipped_violations": 0, "Uncovered": 0, "Allowed": 12, "Warnings": 0, "Errors": 0 } }
```

**Run:** `scripts/collectors/deptrac.sh --input tests/fixtures/deptrac-v024/deptrac-clean.json`

**Expectation:** the parser takes the `.Report.Violations` branch, reads `0`, and
emits:

```json
{ "tool": "deptrac", "status": "pass", "summary": { "architecture_violations": 0, ... } }
```

`architecture_violations == 0`, `status == "pass"`. A clean Deptrac report means
the dependency graph respects every ruleset edge — it does **not** mean Deptrac was
skipped. A skipped/absent Deptrac run is `unavailable`, never `pass`.

## 165. Deptrac collector — violation test expectation

**Input:** `tests/fixtures/deptrac-v024/deptrac-violations.json`

```json
{ "Report": { "Violations": 3, ... }, "files": { ... three boundary violations ... } }
```

**Run:** `scripts/collectors/deptrac.sh --input tests/fixtures/deptrac-v024/deptrac-violations.json`

**Expectation:** `.Report.Violations == 3`, so:

```json
{ "tool": "deptrac", "status": "fail", "summary": { "architecture_violations": 3, ... } }
```

`architecture_violations == 3`, `status == "fail"`. The `files` block carries the
human-readable violation messages (Domain→Infrastructure, Presentation→Infrastructure,
Presentation→Domain); the collector only counts `.Report.Violations`, but the
detail block is what a triager reads.

## 168. architecture-tests collector — clean test expectation

**Input:** `tests/fixtures/architecture-v024/architecture-clean.json`

```json
{ "violations": 0 }
```

**Run:** `scripts/collectors/architecture-tests.sh --input tests/fixtures/architecture-v024/architecture-clean.json`

**Expectation:** `(.violations // .failures // 0)` resolves to `0`:

```json
{ "tool": "architecture-tests", "status": "pass", "summary": { "architecture_violations": 0, ... } }
```

`architecture_violations == 0`, `status == "pass"`. As with Deptrac, a clean count
means the suite ran and found no boundary breaks — not that it was skipped.

## 169. architecture-tests collector — violation test expectation

**Input:** `tests/fixtures/architecture-v024/architecture-violations.json`

```json
{ "violations": 3 }
```

**Run:** `scripts/collectors/architecture-tests.sh --input tests/fixtures/architecture-v024/architecture-violations.json`

**Expectation:** count `3`:

```json
{ "tool": "architecture-tests", "status": "fail", "summary": { "architecture_violations": 3, ... } }
```

`architecture_violations == 3`, `status == "fail"`. The collector also accepts
`.failures` and treats an array value as its length, so test runners that emit a
list of failed assertions instead of a count still map correctly.

> **Verified locally (v0.1.24).** Running both collectors on the four fixtures
> produced: deptrac clean → `architecture_violations: 0` (`pass`); deptrac
> violations → `3` (`fail`); architecture-tests clean → `0` (`pass`);
> architecture-tests violations → `3` (`fail`).

---

## 170. Symfony architecture guide

For a Symfony app with code under `src/`, wire Deptrac via
[`profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml). The default
layout assumes:

- `App\Domain\*` — domain layer (entities, value objects, pure business rules)
- `App\Application\*` — use cases / handlers (CQRS command & query handlers)
- `App\Infrastructure\*` — adapters (Doctrine repositories, HTTP clients, Messenger)
- `App\Controller\*` — presentation (HTTP controllers)

Install and run:

```sh
composer require --dev qossmic/deptrac-shim
vendor/bin/deptrac analyse --config-file=deptrac.yaml --report-json=reports/raw/deptrac.json
scripts/collectors/deptrac.sh --input reports/raw/deptrac.json
```

Symfony specifics: keep Doctrine entities in `Domain` only if they are persistence-
ignorant; if they carry ORM mapping attributes, many teams move them to
`Infrastructure` or split a mapping layer to avoid Domain→Doctrine coupling.
Controllers should depend on Application handlers (via the message bus), never on
Infrastructure repositories directly.

## 171. Laravel architecture guide

For a Laravel app with code under `app/`, wire Deptrac via
[`profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml). The default
layout assumes:

- `App\Domain\*` — domain layer (pure business rules)
- `App\Application\*` — use cases / handlers
- `App\Infrastructure\*` — adapters (Eloquent repositories, queues, external HTTP)
- `App\Http\*` — presentation (controllers, requests, middleware)

Install and run:

```sh
composer require --dev qossmic/deptrac-shim
vendor/bin/deptrac analyse --config-file=deptrac.yaml --report-json=reports/raw/deptrac.json
scripts/collectors/deptrac.sh --input reports/raw/deptrac.json
```

Laravel specifics: the default skeleton scatters logic across `app/Http`,
`app/Models`, and service providers, so Clean-Architecture layering is opt-in. Wrap
Eloquent behind repository interfaces declared in `Domain`/`Application` and
implemented in `Infrastructure`. Treat Facades as presentation/infrastructure glue;
calling them from `Domain` is a boundary smell Deptrac will flag once `App\Domain`
is mapped.

---

## 172. Module-boundary example

Module (a.k.a. bounded-context / vertical-slice) boundaries stop one feature module
from reaching into another's internals. Map each module as a layer and allow only a
published interface:

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

**Violation:** `App\Catalog\PriceSync` references `App\Billing\Internal\Ledger`.
Deptrac reports a Catalog→Billing edge that is not allowed (only `BillingApi` is),
contributing `1` to `architecture_violations`. **Fix:** route the call through
`App\Billing\Api\*`, or promote the needed capability into the published API.

## 173. Layer-boundary example

Layer boundaries enforce inward-only dependencies in a layered/Clean Architecture.
Using the v0.1.24 fixture ruleset (`Domain` ← `Application` ← `Presentation`, with
`Infrastructure` allowed to see Domain+Application):

```
Presentation ──> Application ──> Domain
       Infrastructure ──> Domain, Application
```

**Violation (from `deptrac-violations.json`):** `App\Domain\Order\Order` imports
`App\Infrastructure\Persistence\DoctrineOrderRepository`. Domain has ruleset `~`
(may depend on nothing internal), so a Domain→Infrastructure edge is illegal. **Fix:**
declare an `OrderRepository` interface in `Domain`, implement it in
`Infrastructure`, and inject it — the dependency now points inward.

## 174. CQRS boundary example

In CQRS, commands (writes) and queries (reads) are separate paths. Boundaries keep
the write model from leaking into the read model and keep handlers off the transport
layer:

```yaml
layers:
  - name: Command
    collectors: [{ type: classNameRegex, value: '#^App\\Application\\Command\\.*#' }]
  - name: Query
    collectors: [{ type: classNameRegex, value: '#^App\\Application\\Query\\.*#' }]
  - name: Domain
    collectors: [{ type: classNameRegex, value: '#^App\\Domain\\.*#' }]
ruleset:
  Command:
    - Domain        # command handlers mutate the domain model
  Query:
    - Domain        # read models project from domain (or a dedicated read store)
  Domain: ~
  # Command and Query are NOT allowed to depend on each other.
```

**Violation:** `App\Application\Query\OrderSummaryHandler` depends on
`App\Application\Command\PlaceOrderHandler` (a query reaching into the write path).
Deptrac reports a Query→Command edge that the ruleset omits, adding `1` to
`architecture_violations`. **Fix:** have the query read from its own read model /
projection rather than invoking a command handler.

---

## 175. False-positive triage

Architecture findings are usually real, but these patterns produce noise:

- **Unmapped namespace.** A class that matches no layer collector shows as
  *uncovered*, which can mask or distort edges. Add a layer (or a catch-all) so
  coverage is explicit — do not silence by deleting the layer.
- **Shared kernel / value objects.** Cross-cutting primitives (Money, Uuid, Result)
  trip layer rules. Model them as an explicit `SharedKernel` layer that every layer
  is allowed to depend on, rather than punching per-class holes.
- **Framework base classes.** Extending a framework controller or command base can
  pull in an unexpected vendor edge; restrict layers to your own `App\*` namespaces
  (as the profiles do) so vendor code is out of scope.
- **Interfaces vs. implementations.** A "violation" pointing at an interface in the
  right layer is usually a mapping bug, not a real breach — confirm the regex bounds
  before suppressing.

Triage rule: confirm the edge is genuinely allowed-by-design before suppressing.
Never blanket-suppress to turn a `fail` green.

## 176. Accepted-risk guidance

When a violation is real but intentionally accepted (e.g., a pragmatic shortcut with
a remediation date), record it explicitly rather than hiding it:

- Use Deptrac's `skip_violations` to list the **specific** class pairs that are
  knowingly accepted — never an empty-but-permissive catch-all. The collector still
  reports remaining violations honestly.
- Pair each accepted item with a Sentinel Shield exception entry (owner, reason,
  expiry) so the `expired_exceptions` count surfaces it once the accepted window
  lapses. An accepted risk is time-boxed, not permanent.
- Document the decision in the PR/ADR. An accepted architectural risk is a
  documented trade-off, not silence.

Accepted risk reduces the actionable count; it must never zero out a count that
represents an un-triaged breach.

## 177. Strict-mode criteria

Treat architecture checks as **blocking** (any `architecture_violations > 0` fails
the gate) only when **all** of the following hold:

- Deptrac `deptrac.yaml` (or the architecture-test suite) is configured and the
  layer graph is **already clean** at adoption — you are protecting a known-good
  baseline, not discovering debt.
- Layer collectors cover the codebase with no significant *uncovered* surface.
- `skip_violations` is empty or contains only documented, time-boxed accepted items.
- The collector runs on a real report (never on an absent one); `unavailable` is
  treated as a gate failure to investigate, not a pass.

Until a baseline is clean, run in observe mode (collect counts, do not block) and
burn the graph down first.

## 178. Regulated-mode criteria

In regulated contexts (where architectural integrity is an auditable control),
strict mode plus evidence requirements apply:

- Every run produces a retained `reports/raw/deptrac.json` (or architecture report)
  as audit evidence, with the resulting `architecture_violations` count recorded.
- No `unavailable` outcomes are tolerated on protected paths — if the analyser did
  not run, the gate fails and the gap is logged; a missing scan is a finding.
- Accepted risks require an approved exception with owner, justification, and expiry;
  expired exceptions block (`expired_exceptions`).
- Ruleset and `skip_violations` changes are reviewed like code (PR + ADR) so
  loosening a boundary is auditable.

Regulated mode = strict gating + immutable evidence + reviewed exceptions. Honesty
is mandatory: fake-clean on an un-run analyser is an audit failure.

## 179. Profile recommendations note

Start from the shipped profiles and adapt — do not hand-roll from scratch:

- Symfony → [`profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml)
  (`src/`, `App\Controller\*` presentation).
- Laravel → [`profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml)
  (`app/`, `App\Http\*` presentation).

Both ship the same inward-only layered ruleset (`Domain` ← `Application` ←
`Presentation`; `Infrastructure` → Domain+Application). Adjust the `classNameRegex`
collectors to your actual namespaces, add `SharedKernel` / module layers as needed
(see §172, §174), and keep `skip_violations` explicit. Begin in observe mode, reach
a clean graph, then promote to strict (§177).

## 180. Maturity note

Per [`product-status.md`](product-status.md), Deptrac and the generic
architecture-tests check are **experimental** and **only-if-configured**, and
Deptrac is among the **not-yet-live-validated** tools on the main-branch gate. The
v0.1.24 fixtures and this document exercise and explain the collector *count
mappings*; they are **not** evidence of a live consumer run. Promotion to
`supported` requires a real, cited Deptrac/architecture run on a repository that
actually defines architecture layers, with the resulting report retained. Until
then: configure deliberately, run in observe mode first, and **never emit a clean
result when nothing was analysed** — absence is `unavailable`, not `pass`.
