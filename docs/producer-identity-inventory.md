# Producer identity inventory — the nine engineering-quality runner paths

**Scope:** identity only. Exit semantics, completion semantics, and scope/configuration
binding are the *normative* producer inventory, which is separate work and comes after the
identity split lands. This document exists to answer one question before any code changes:

> When an execution record says which producer ran, what is "the producer"?

**Status:** RESOLVED — the identity split has landed. Kept as the record of what was
inventoried and why, and as the contract `tests/prod/303` and `tests/prod/304` assert. Derived from `scripts/runners/*.sh`
and `TOOL_TABLE` in `scripts/build-security-summary.sh` at master `99054cc4`.

---

## Why this exists

`ne_execution_verify` takes one identity argument and requires exact equality with the
record's `.producer.tool`. The collectors pass `$TOOL`, which `--tool-name` sets — and
`build-security-summary.sh` invokes them with the **emitted channel name**:

```text
sh coverage.sh --input php-coverage.json --tool-name php_coverage
```

So a record written by `scripts/runners/php-coverage.sh` — which can only name itself — is
refused:

```text
execution record names tool 'php-coverage', not 'php_coverage'
```

`--tool-name` was overloaded: it set both the summary channel and the provenance identity.
That overload was the defect. The obvious repair — teaching runners the builder's alias —
reverses ownership: a runner knows what ran; it must not know how a downstream summary
builder chooses to name or merge its channel.

**Resolved.** Collectors now take two independent parameters, and the builder passes both
because it already holds both:

```text
--tool-name    "$emit"   the CHANNEL      presentation, renamable, shareable
--producer-key "$key"    the PRODUCER     verified identity, stamped into producer.tool
```

`PRODUCER` is established from the collector's canonical identity **before any argument is
parsed**, and no collector assigns it from the `--tool-name` branch — asserted structurally by
`tests/prod/304`, because argument ORDER is not a security property. The builder happens to
pass `--producer-key` second, which would mask a channel-writes-producer regression in every
dynamic test; the structural assertion is what catches it.

`ne_envelope` was repaired in the same change: it stamps `producer.tool`, so fixing only
verification would have left evidence carrying the wrong identity.

---

## The inventory

| runner script | backend actually executed | producer key (`tkey`) | native report | collector | emitted channel |
| --- | --- | --- | --- | --- | --- |
| `infection.sh` | Infection | `php-mutation` | `php-mutation.json` | `mutation.sh` | `php_mutation` |
| `stryker.sh` | Stryker | `js-mutation` | `js-mutation.json` | `mutation.sh` | `js_mutation` |
| `phpmd-complexity.sh` | PHPMD | `php-complexity` | `php-complexity.json` | `complexity.sh` | `php_complexity` |
| `phpcpd.sh` | phpcpd | `php-duplication` | `php-duplication.json` | `duplication.sh` | `php_duplication` |
| `jscpd.sh` | jscpd | `js-duplication` | `js-duplication.json` | `duplication.sh` | `js_duplication` |
| `knip.sh` | **knip _or_ ts-prune** | `js-dead-code` | `js-dead-code.json` | `dead-code.sh` | `js_dead_code` |
| `php-coverage.sh` | **pest _or_ phpunit** | `php-coverage` | `php-coverage.json` | `coverage.sh` | `php_coverage` |
| `js-coverage.sh` | package-manager coverage script | `js-coverage` | `js-coverage.json` | `coverage.sh` | `js_coverage` |
| `php-diff-coverage.sh` | **pest _or_ phpunit** | `php-diff-coverage` | `php-diff-coverage.json` | `diff-coverage.sh` | `php_diff_coverage` |

---

## Three findings

### 1. It is a three-way distinction, not two — for six of the nine

The prerequisite was framed as *producer identity vs channel identity*. The inventory shows a
third axis: **the runner script name is not the producer key**, except for the three
`*-coverage` runners.

```text
infection.sh   →  runs Infection  →  produces tkey php-mutation  →  channel php_mutation
   script            backend              producer key                 channel
```

"The runner names itself" is therefore ambiguous. `infection.sh` naming itself `infection`
would produce a record no builder can match to `php-mutation` without a second alias table —
recreating the overload one layer down.

**The producer key is the `tkey`.** It is what the builder already iterates, independently of
`emit`, and it is stable across presentation changes.

### 2. Two runners choose their backend at runtime, and the choice is not cosmetic

`knip.sh` runs knip when `node_modules/.bin/knip` exists and otherwise falls back to
ts-prune. These are different tools with **different counting semantics**:

- knip sums every issue category (`.files` plus every `.issues[]` entry)
- ts-prune counts output lines, excluding `(used in module)` re-exports

Two numbers under one producer key that are not comparable to each other. `php-coverage.sh`
and `php-diff-coverage.sh` similarly select pest or phpunit.

A record naming only `js-dead-code` cannot say which tool produced the count, so a
knip→ts-prune switch — which can happen from one CI run to the next purely by dependency
installation — would be invisible. **The backend belongs in the record**, as provenance
rather than as the verified identity: verification binds on the producer key, and the backend
is what an operator needs in order to interpret the numbers.

### 3. Many-to-one channels already exist

Two **distinct producer keys** emit one channel:

```text
php-style      ─┐
                ├─>  php_style
php-cs-fixer   ─┘
```

If channel identity were used for provenance, those two producers would be **indistinguishable
in the evidence** — the exact opposite of what execution provenance is for.

`coverage.sh` is a different and weaker property: it serves `coverage`, `php-coverage` and
`js-coverage`, but each emits its own channel (`coverage`, `php_coverage`, `js_coverage`). That
is collector **fan-in**, not channel sharing, and it does not on its own establish the
many-to-one case. The first draft of this section cited it as if it did, and `tests/prod/303`
asserted the fan-in count accordingly — an assertion that would have passed even if no two
producers ever shared a channel. Both now assert `php_style`.

---

## The invariant this establishes

```text
Presentation normalization may merge or rename channels.
It must never rewrite execution identity.
```

Which implies, for the prerequisite:

| identity | value | owned by | used for |
| --- | --- | --- | --- |
| producer key | `php-coverage`, `php-mutation`, `js-dead-code` | the runner / the tool table | execution-record verification |
| backend | `pest`, `phpunit`, `knip`, `ts-prune`, `Infection` | the runner, at run time | interpreting the numbers; a change must be visible |
| channel | `php_coverage`, `php_mutation`, `js_dead_code` | the builder | summary aggregation and policy presentation |

`--producer-name` carries the **producer key**. It must not default to `$TOOL` after
`--tool-name` is processed, because that silently recreates the overload; when it is absent,
the producer defaults to the collector's own canonical producer identity.

---

## What this document does NOT settle

- **Exit-code and completion semantics.** PHPMD documents non-zero as the normal findings
  case; Infection runs with `--min-msi=0` precisely so Sentinel decides the threshold; the
  coverage runners keep the test-runner exit separate while still accepting a finalized
  Clover report. That is the normative inventory, and it comes after this.
- **Scope and configuration binding** per producer.
- **Whether `coverage` (the generic key) should remain** alongside the per-stack keys.
