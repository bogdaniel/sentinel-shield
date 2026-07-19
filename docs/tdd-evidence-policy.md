# TDD Evidence Policy (v2.2.0)

The TDD proxy answers one narrow, observable question:

> Did production behavior change while no test, spec, feature or acceptance file changed in the
> same diff?

That is evidence. It is not proof of test-driven development.

## Why there is no such thing as a TDD gate

**TDD cannot be proven from final code.** TDD is a workflow — it constrains the *order* in
which a developer writes a test and the code that satisfies it. The artifact Sentinel Shield
inspects is a final snapshot plus a diff, and neither records that order.

Concretely, all of the following look identical to any static tool:

- a test written first, then the implementation (real TDD);
- an implementation written first, then a test bolted on to satisfy the gate;
- a test generated after the fact from the implementation's behavior.

So Sentinel Shield enforces TDD evidence proxies, not developer intent. The proxies it ships:

| Proxy | Gate | What it observes |
| --- | --- | --- |
| Production change without test change | `production_change_without_test_change` | A behavior change arrived with no test change |
| Changed-line coverage | `changed_lines_coverage_violations` | The lines you just wrote are exercised |
| Missing / empty test evidence | `missing_test_evidence`, `empty_test_suite` | A suite exists and actually ran |
| Mutation testing | `mutation_score_violations` | The tests would notice if the code broke |
| Focused-test guards | `focused_test_violations` | No `.only` left behind, silently skipping the suite |

Together these make undisciplined testing *expensive and visible*. None of them makes it
impossible, and Sentinel Shield does not pretend otherwise.

## How the proxy computes a violation

`scripts/runners/test-change-evidence.sh` reads the git diff and classifies every changed file.

**Base ref detection order** (first that resolves wins):

```txt
$SENTINEL_SHIELD_DIFF_BASE
origin/main
origin/master
main
master
HEAD~1
```

The diff is taken against the **merge base** of that ref and `HEAD`, so unrelated commits that
landed on the base branch meanwhile are not attributed to this change.

**Classification order** — test wins over ignore, ignore wins over production:

| Class | Default patterns |
| --- | --- |
| Test | `tests/**`, `test/**`, `spec/**`, `__tests__/**`, `*.test.*`, `*.spec.*`, `*.feature`, `features/**`, `e2e/**`, `playwright/**`, `cypress/**` |
| Ignored | `docs/**`, `README*`, `CHANGELOG*`, `.github/**`, `config/**`, `database/migrations/**`, `public/build/**`, `dist/**`, `build/**`, `coverage/**`, `reports/**`, `vendor/**`, `node_modules/**` |
| Production | `app/**`, `src/**`, `packages/**`, `lib/**`, `server/**`, `client/**` |

Test beats production deliberately: `src/domain/order.test.ts` is a test, not a production
change. A file matching none of the three lists is recorded as **ignored** — only *declared*
production paths can produce a violation, so an unmapped tree never manufactures a false one.
Widen `testing_discipline.tdd.production_paths` for a non-standard layout.

**Rules:**

```txt
production files changed + no test/spec/feature/acceptance file changed  -> count 1
only docs/config/CI changed                                              -> count 0
production and tests changed                                             -> count 0
diff cannot be computed                                                  -> missing_test_change_evidence = true
```

One violation per diff, not one per file: the finding is "this change carries no test
evidence", which is a single reviewable fact.

## Never a fake pass

If git is absent, the directory is not a work tree, or no base ref resolves, the runner writes
`status: unavailable` and `missing_test_change_evidence: true`. It never reports zero
violations from a computation that did not happen. In strict/regulated that missing evidence
blocks — "we could not check" must not read as "there is nothing wrong".

## Configuring it

```yaml
testing_discipline:
  tdd:
    enabled: true
    require_test_change_for_production_change: true
    production_paths:
      - app
      - src
      - packages
    test_paths:
      - tests
      - spec
      - __tests__
    ignore_paths:
      - docs
      - .github
      - config
      - database/migrations
```

A list here **replaces** the built-in list for that class. A present-but-empty list fails closed
(exit 2) rather than silently classifying everything as ignorable. See
[`templates/testing-discipline-policy.example.yaml`](../templates/testing-discipline-policy.example.yaml).

## Legitimate exceptions

Some production changes genuinely carry no test change: regenerated clients, vendored code, a
pure rename. Those are what [`test-discipline-waivers.md`](test-discipline-waivers.md) is for —
a waiver with a reason and an expiry, never a silent suppression.

## Related

- [`testing-discipline-governance.md`](testing-discipline-governance.md)
- [`test-discipline-waivers.md`](test-discipline-waivers.md)
- [`engineering-quality-gates.md`](engineering-quality-gates.md) — coverage, mutation, diff-coverage
