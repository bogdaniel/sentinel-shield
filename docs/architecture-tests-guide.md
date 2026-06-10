# Architecture-Tests Guide (v0.1.25)

How to wire any architecture-boundary test suite into Sentinel Shield through the
generic `architecture-tests` collector: the raw JSON contract, worked fixtures with
**real** collector output, framework-specific producers (Laravel / Symfony / Node),
how to read a failure, the criteria for strict and regulated profiles, and an honest
statement of maturity.

This is the **producer-agnostic** companion to
[`architecture-deptrac-realism.md`](architecture-deptrac-realism.md) (which is
Deptrac-specific). Deptrac is one producer; this guide covers the case where you
bring **your own** architecture-test runner and emit the raw contract yourself.

> **Maturity — be honest (see §120).** The `architecture-tests` collector is
> **only-if-configured** and **not live-validated**. Its count→`architecture_violations`
> mapping is deterministic and exercised by fixtures (so the *collector* is
> `supported` in the sense of "deterministic, fixture-backed"), but **no pilot
> consumer ships an architecture-test suite**, so the end-to-end capability stays
> **experimental / not-yet-proven**. Nothing here is promoted on the strength of
> fixtures alone. **Never emit a clean result when nothing was analysed** — absent
> input must surface as `unavailable`, not `pass`.

---

## Raw contract (§114)

Sentinel Shield does **not** run your architecture suite. Your runner is the
*producer*; it decides what counts as a violation and writes a raw JSON file. The
collector (`scripts/collectors/architecture-tests.sh`) is the *consumer* and reads:

```
N = (.violations // .failures // 0)
    | (if type == "array" then length else . end)
    | floor
```

Two accepted shapes:

| Shape | Example | How `N` is derived |
|---|---|---|
| **Canonical** — integer count | `{"violations": 3}` | `.violations` is read directly |
| **Fallback** — list of failures | `{"failures": [ {…}, {…} ], "tests": 12}` | `.violations` absent → `.failures` array → length |

Precedence rule: **`.violations` wins whenever it is present, even when it is `0`.**
A producer that emits both `{"violations": 2, "failures": [ …5 items… ]}` counts as
`2` (the explicit number), not `5`. If neither key is present the count is `0`
(`pass`) — so only omit both keys when you genuinely mean "no violations." Extra
keys (`tests`, `passed`, per-failure `rule`/`from`/`to`/`message`) are ignored by
the collector but are exactly what a human triager reads.

A nonzero count ⇒ `status = "fail"`; zero ⇒ `status = "pass"`; a **missing or empty
input file** ⇒ `status = "unavailable"` (exit 0); **invalid JSON** ⇒ exit 2.

### Schema (informal)

```jsonc
{
  "tool": "architecture-tests",   // optional, advisory
  "tests": 12,                     // optional: total assertions run
  "passed": 10,                    // optional: assertions that passed
  "violations": 2,                 // canonical count (integer). Wins if present.
  "failures": [                    // optional detail; counted only if `violations` absent
    {
      "rule": "domain-must-not-depend-on-infrastructure",
      "from": "App\\Domain\\Order\\Order",
      "to":   "App\\Infrastructure\\Persistence\\DoctrineOrderRepository",
      "message": "Domain depends on Infrastructure"
    }
  ]
}
```

---

## Summary mapping (§115)

The collector folds its count into the canonical Sentinel Shield collector summary
under one key:

| Raw input | Collector `status` | `summary.architecture_violations` |
|---|---|---|
| `{"violations": 0}` (or `{"failures": []}`) | `pass` | `0` |
| `{"violations": 3}` | `fail` | `3` |
| `{"violations": 2, …passing tests…}` | `fail` | `2` |
| `{"failures": [a, b]}` (no `.violations`) | `fail` | `2` |
| missing / empty file | `unavailable` | (not emitted) |

`architecture_violations` is the **only** summary field this collector sets; every
other field stays `0`. Downstream policy aggregates `architecture_violations`
alongside Deptrac's contribution (Deptrac maps to the same field), so a project
running both producers sums their counts.

---

## Collector test expectations (§105)

Fixtures live in [`tests/fixtures/architecture-v025/`](../tests/fixtures/architecture-v025/).
The values below are the **real** output of running the collector on each fixture
(`status` + `summary.architecture_violations`), captured during v0.1.25 development.

| Fixture | Raw | Command | `status` | `architecture_violations` |
|---|---|---|---|---|
| `clean.json` | `violations: 0`, `failures: []` | `sh scripts/collectors/architecture-tests.sh --input tests/fixtures/architecture-v025/clean.json` | `pass` | **0** |
| `violations.json` | `violations: 3` + 3 failure rows | `sh scripts/collectors/architecture-tests.sh --input tests/fixtures/architecture-v025/violations.json` | `fail` | **3** |
| `mixed.json` | `tests: 10, passed: 8, violations: 2` | `sh scripts/collectors/architecture-tests.sh --input tests/fixtures/architecture-v025/mixed.json` | `fail` | **2** |

`mixed.json` models a partial pass: ten assertions ran, eight passed, two failed —
the collector reports `2` because `architecture_violations` counts breaches, not
total tests. These three counts `(0, 3, 2)` are the contract the self-test harness
should assert against (§118).

> **Verified locally (v0.1.25).** Running the collector on the three fixtures
> produced `architecture_violations`: clean → `0` (`pass`); violations → `3`
> (`fail`); mixed → `2` (`fail`). The bundled producer
> (`example-producer.sh`, §106/§109) emits `violations: 2` and likewise maps to
> `2` (`fail`). These are fixture round-trips, **not** evidence of a live consumer
> run.

---

## Custom architecture-test producers (§107)

Any tool that can emit `{"violations": N}` (or a `failures` array) is a valid
producer. The pattern is always:

1. Run your architecture assertions (in CI, after the build).
2. Serialise the result to `reports/raw/architecture-tests.json` in the raw contract.
3. Call the collector:
   `sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json`.

A minimal reference producer ships at
[`tests/fixtures/architecture-v025/example-producer.sh`](../tests/fixtures/architecture-v025/example-producer.sh):
it writes a deterministic `violations: 2` report to stdout so the full
producer→collector path is reproducible without installing any architecture runner.

```sh
sh tests/fixtures/architecture-v025/example-producer.sh > reports/raw/architecture-tests.json
sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json
# → status: fail, architecture_violations: 2
```

Replace the producer body with whatever your real runner emits. The collector does
not care how you decided what a violation is — only that you report a count.

### Choosing the count vs the failures array

- Emit **`{"violations": N}`** when your runner already aggregates a number (most
  do). It is unambiguous and the explicit-count path.
- Emit **`{"failures": [...]}`** (no `violations`) when it is more natural to emit
  per-rule failure objects and let the collector count them. Useful when you want
  the failure detail and the count to stay in sync automatically.
- **Do not** emit `{"violations": 0}` to paper over a suite that did not run. If the
  suite could not run, write **no file** (or an empty file) so the collector reports
  `unavailable` — see §111 and §120.

---

## Laravel example (§108)

For a Laravel app (code under `app/`), a common producer is **PHPArkitect** or a
PHPUnit rule set. Layers typically map to `App\Domain\*`, `App\Application\*`,
`App\Infrastructure\*`, `App\Http\*`. Example rules:

- `App\Domain\*` must not depend on `App\Infrastructure\*` or `Illuminate\*`
  (domain stays framework-free; calling a Facade from `Domain` is a violation).
- `App\Http\*` (controllers) must not reach `App\Infrastructure\*` directly — go
  through `App\Application\*` handlers.
- Wrap Eloquent behind repository interfaces declared in `Domain`/`Application`.

PHPArkitect emits its own format; bridge it to the contract, e.g.:

```sh
vendor/bin/phparkitect check --format=json > /tmp/arkitect.json || true
jq '{violations: ([.errors // [] | length] | add)}' /tmp/arkitect.json \
  > reports/raw/architecture-tests.json
sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json
```

(Deptrac is the other Laravel option — see
[`profiles/laravel/deptrac.yaml`](../profiles/laravel/deptrac.yaml) and
`architecture-deptrac-realism.md` §171.)

## Symfony example (§109)

For a Symfony app (code under `src/`), use a PHPUnit/PHPArkitect rule set or a
custom test against `App\Domain\*`, `App\Application\*`, `App\Infrastructure\*`,
`App\Controller\*`. The bundled
[`example-producer.sh`](../tests/fixtures/architecture-v025/example-producer.sh)
already models two Symfony-shaped failures (Domain→Infrastructure and
Presentation→Infrastructure) and is the runnable reference for this section:

```sh
sh tests/fixtures/architecture-v025/example-producer.sh > reports/raw/architecture-tests.json
sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json
# → architecture_violations: 2, status: fail
```

Symfony specifics: keep Doctrine entities in `Domain` only if persistence-ignorant;
controllers should depend on Application handlers via the message bus, never on
Infrastructure repositories directly. (Deptrac alternative:
[`profiles/symfony/deptrac.yaml`](../profiles/symfony/deptrac.yaml),
`architecture-deptrac-realism.md` §170.)

## Node example (§110)

For a Node/TypeScript app, **dependency-cruiser** is a natural producer. Define
forbidden edges in `.dependency-cruiser.js` (e.g. `src/domain` must not import
`src/infra`), run it as JSON, and reduce to the contract:

```sh
npx depcruise src --output-type json > /tmp/depcruise.json
# dependency-cruiser puts rule breaches under .summary.violations (array)
jq '{violations: (.summary.violations | length)}' /tmp/depcruise.json \
  > reports/raw/architecture-tests.json
sh scripts/collectors/architecture-tests.sh --input reports/raw/architecture-tests.json
```

Alternatively, emit the `failures` array directly and let the collector count it:

```sh
jq '{failures: .summary.violations}' /tmp/depcruise.json \
  > reports/raw/architecture-tests.json
```

Both forms yield the same `architecture_violations`. ESLint
`import/no-restricted-paths`, `eslint-plugin-boundaries`, or a custom Jest test that
asserts on the module graph are equally valid producers — reduce whatever they emit
to a count or a `failures` list.

---

## Reading a failure (§111)

When the collector reports `status: fail` with `architecture_violations: N`:

1. **Open the raw file**, not just the summary. The count is in `.violations`; the
   *why* is in `.failures[]` (`rule`, `from`, `to`, `message`). The collector
   intentionally discards detail — the raw report is your audit trail.
2. **Read each edge as `from → to`.** It names a dependency that crosses a boundary
   the wrong way (e.g. `App\Domain\Order\Order → App\Infrastructure\…` = an
   inner layer reaching outward).
3. **Fix inward, not by relaxing the rule.** The standard remedy is dependency
   inversion: declare an interface in the inner layer, implement it in the outer
   layer, inject it. Suppressing the rule hides the coupling; it does not remove it.
4. **`fail` means the suite ran and found breaches.** It does **not** mean the suite
   was skipped. A skipped/absent suite is `unavailable` (count not emitted), never a
   silent `pass`. If you see `unavailable`, your producer did not write a report —
   fix the pipeline before trusting any architecture verdict.
5. **`mixed`-style reports** (some pass, some fail) still surface as a single `fail`
   with the failing count; the passing assertions do not offset it.

---

## Strict-profile criteria (§112)

A **strict** profile should treat architecture boundaries as gating:

- Require `architecture_violations == 0` to pass (no allowance budget).
- Run in **observe mode first**, reach a clean graph, *then* promote to gating — do
  not flip a noisy suite straight to blocking.
- Keep any temporary suppressions **explicit and expiring** (tie them to the
  exceptions mechanism so they surface as `expired_exceptions` when stale), not as
  silently lowered rules.
- Require the raw report artifact to be **retained** in CI so every `fail` is
  auditable after the fact.
- The producer must emit `unavailable` (no file) rather than `{"violations":0}` when
  it cannot run — a strict gate must distinguish "clean" from "did not analyse."

## Regulated-profile criteria (§113)

For **regulated** contexts (audited / compliance-bound), add to the strict criteria:

- **Evidence retention:** persist the raw `architecture-tests.json` (and any
  producer logs) as build artifacts for the audit window; a count with no retained
  report is not auditable evidence.
- **Documented ruleset provenance:** the boundary rules (which layers, which
  forbidden edges) must be version-controlled and reviewed, not ad hoc.
- **No fake-clean:** an `unavailable` result must **fail the gate or raise an
  alert**, never be treated as `pass`. Absence of analysis is a finding in a
  regulated context.
- **Honest maturity disclosure:** because this capability is not live-validated
  (§120), a regulated adopter must record that architecture-tests is currently a
  *configured, observe-then-gate* control, not a proven one, until a cited consumer
  run exists.

---

## Profile recommendation (§116)

| Profile posture | Recommendation |
|---|---|
| **Baseline / default** | Architecture-tests **off** unless a suite is configured. Absent suite ⇒ `unavailable`, never injected as a fake `pass`. |
| **Opt-in (most teams)** | Add a producer, run in **observe mode** (non-gating) until the graph is clean, then promote. |
| **Strict** | Gating at `architecture_violations == 0`; explicit/expiring suppressions; retained artifacts (§112). |
| **Regulated** | Strict + evidence retention + provenance + `unavailable`-is-a-finding (§113). |

Recommended adoption order: pick a producer (Deptrac for PHP layering;
dependency-cruiser/ESLint for Node; PHPArkitect for rule-style PHP) → wire it to the
raw contract → observe → gate. Do not enable gating on day one.

---

## Install / sync reference (§117)

The `architecture-tests` collector is shipped by Sentinel Shield and invoked from
the consuming project against `reports/raw/architecture-tests.json`. Onboarding and
updates follow the standard install/sync flow — see
[`install-sync-guide.md`](install-sync-guide.md) and
[`profile-driven-adoption.md`](profile-driven-adoption.md):

- The consumer checks Sentinel Shield out via `SENTINEL_SHIELD_REPOSITORY` /
  `SENTINEL_SHIELD_REF` and calls `scripts/collectors/architecture-tests.sh`; it
  does **not** copy collector logic by hand.
- `install-baseline.sh` is **dry-run by default** and writes only with `--apply`;
  `sync-baseline.sh` reconciles managed files on update.
- **Producing** the raw report (running your architecture suite) is the operator's
  responsibility — it is **not** a managed file. Wire it into your CI before the
  collector step. This is the manual step that remains yours.

---

## Self-test coverage note for the captain (§118)

For the self-test harness owner:

- The v0.1.25 fixtures `tests/fixtures/architecture-v025/{clean,violations,mixed}.json`
  exist specifically so the harness can assert the count mapping **without**
  installing any architecture runner.
- **Assertions to add/keep:** running the collector on these three fixtures must
  yield `architecture_violations` of **0 / 3 / 2** and `status` of
  **pass / fail / fail** respectively.
- The `mixed.json` case additionally proves that passing tests do not offset
  violations (10 tests, 8 passed → still `fail` at `2`).
- The `failures`-array fallback (count = array length when `.violations` is absent)
  is also part of the contract and worth a dedicated assertion; the bundled producer
  exercises the explicit-count path end-to-end.
- These are **fixture** assertions. They prove the collector arithmetic, **not** a
  live consumer run. Do not let a green self-test be read as live validation (§120).
- This guide and Lane F touch only `tests/fixtures/architecture-v025/**` and this
  doc — they do **not** modify `self-test.sh` or shared docs. The captain owns the
  harness wiring.

---

## Evidence checklist (§119)

Before claiming an architecture-tests result is trustworthy, confirm:

- [ ] The raw `reports/raw/architecture-tests.json` exists and is valid JSON.
- [ ] It was produced by an architecture suite that **actually ran** (not a stub /
      fake `{"violations":0}`).
- [ ] The collector was run on it and emitted `architecture_violations` + a
      `status` of `pass`/`fail` (not `unavailable`).
- [ ] On `fail`, the raw `failures[]` detail (rule/from/to) is present and retained.
- [ ] For strict/regulated: the report artifact is persisted and the ruleset is
      version-controlled (§112–§113).
- [ ] The maturity of the capability is disclosed honestly (§120) — fixtures and a
      green self-test are **not** a live consumer run.

---

## Honest maturity (§120)

- **Collector:** `supported` in the narrow sense — the count→`architecture_violations`
  mapping is deterministic and fixture-backed (`tests/fixtures/architecture-v025/`,
  verified counts 0/3/2 in §105). The collector arithmetic is proven.
- **End-to-end capability:** **experimental / only-if-configured / not
  live-validated.** No pilot consumer ships an architecture-test suite, so the
  contract has never been exercised by a real producer in a real repository. Per
  [`product-status.md`](product-status.md), the generic architecture check is
  **experimental** and **only-if-configured**, alongside Deptrac among the
  not-yet-live-validated tools.
- **What would promote it:** a real, cited architecture-test run on a repository that
  actually defines layers/boundaries, with the resulting raw report retained as
  evidence. Fixtures and a green self-test do **not** qualify — they exercise the
  collector, not a consumer.
- **The honest default:** configure deliberately, run in observe mode first, and
  **never emit a clean result when nothing was analysed** — absence is
  `unavailable`, not `pass`.

See also [`architecture-deptrac-realism.md`](architecture-deptrac-realism.md) §180
for the parallel statement on Deptrac.
