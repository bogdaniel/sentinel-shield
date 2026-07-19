# BDD and ATDD Evidence (v2.2.0)

Two separate channels, two separate contracts, two independently-resolved gates:

- **BDD** — executable specifications. Do behavior scenarios exist, and did they run?
- **ATDD** — acceptance evidence. Did acceptance-level tests execute, and did they pass?

They are deliberately not merged. A project can have rich Gherkin and no browser suite, or a
Playwright suite and no Gherkin at all.

## What this does and does not prove

Sentinel Shield does **not** guarantee BDD quality, and does **not** replace product-owner
acceptance.

Counting scenarios measures that behavior descriptions exist and executed. It says nothing
about whether they describe behavior anyone actually wants — that judgement belongs to the
people who wrote them and the product owner who accepted the work. Sentinel Shield does not
understand business intent automatically.

What the gates give you is narrower and honest: an executable specification suite cannot
quietly disappear, rot into a permanent skip, or report green after running nothing.

## Opt-in by design

**Libraries are not forced to carry BDD/ATDD by default.** BDD/ATDD evidence is only required
when configured, or when an app profile enables it in strict/regulated mode.

Both flags must be on before behavior-spec evidence is *expected*:

```yaml
testing_discipline:
  bdd:
    enabled: true
    require_behavior_specs: true
    spec_paths:
      - features
      - specs
      - tests/Feature

  atdd:
    enabled: true
    require_acceptance_evidence: true
    acceptance_paths:
      - tests/Acceptance
      - e2e
      - playwright
      - cypress
```

Alternatively a profile may declare a BDD/ATDD producer as `required`. The shipped profiles
declare them as `optional`, so nothing is demanded until a project asks for it. A
`php-library` profile carries `behat` as `optional` and no ATDD producer at all.

## The BDD contract

```json
{
  "tool": "behavior-specs",
  "status": "pass",
  "spec_count": 12,
  "scenario_count": 34,
  "orphan_behavior_specifications": 0,
  "missing_behavior_specification": false,
  "failures": []
}
```

Mapping:

```txt
spec_count + scenario_count     -> behavior_spec_count            (informational)
orphan_behavior_specifications  -> orphan_behavior_specifications (gate, regulated)
missing_behavior_specification  -> missing_behavior_specification (gate, app profiles)
```

Allowed statuses:

```txt
pass
findings
unavailable
not-configured
execution-error
disabled
not-applicable
```

An unknown status fails closed as `execution-error`.

**A producer that ran and declared zero specs and zero scenarios is treated as missing behavior
specification**, not as a clean pass. "0 specs, all green" is exactly the fake pass this
feature exists to prevent.

### Orphan specifications

`orphan_behavior_specifications` counts features with no matching implementation or test
evidence — a scenario describing behavior nobody built. Most producers cannot determine this:
Cucumber's JSON and Behat's JUnit carry no spec-to-implementation map. Those producers report
`0`, which is a truthful *"this producer cannot determine it"*, not a clean result. The gate is
regulated-only for that reason.

## The ATDD contract

See [`acceptance-test-evidence.md`](acceptance-test-evidence.md) for the full treatment,
including the documented `tests: 0` behavior.

```json
{
  "tool": "acceptance-tests",
  "status": "findings",
  "tests": 48,
  "failures": 2,
  "skipped": 1,
  "missing_acceptance_evidence": false
}
```

```txt
tests                        -> acceptance_test_count        (informational)
failures                     -> acceptance_test_failures     (gate, from baseline)
missing_acceptance_evidence  -> missing_acceptance_evidence  (gate, app profiles)
```

## Producers

| Tool | Channel | Runner | Adapter |
| --- | --- | --- | --- |
| Behat | BDD | `scripts/runners/behat.sh` | `behat-junit-to-behavior-specs.php` |
| Cucumber.js | BDD | `scripts/runners/cucumber-js.sh` | `cucumber-json-to-behavior-specs.mjs` |
| Behat (acceptance suite) | ATDD | `scripts/runners/behat-acceptance.sh` | `junit-to-acceptance-tests.php` |
| Cucumber.js (acceptance) | ATDD | `scripts/runners/cucumber-acceptance.sh` | inline |
| Playwright | ATDD | `scripts/runners/playwright.sh` | `playwright-json-to-acceptance-tests.mjs` |
| Cypress | ATDD | `scripts/runners/cypress.sh` | `junit-to-acceptance-tests.mjs` |

Any tool that writes either contract works — the collectors never care which produced it. A
Pest feature suite or a short script of your own is a first-class producer.

## Scheduling

BDD scenario suites are usually fast enough for PRs. Browser acceptance suites usually are not:

```txt
behavior-specs:     PR true if configured
acceptance-tests:   main true, scheduled true; PR only when fast
Playwright/Cypress: main true, scheduled true
```

Slow browser acceptance suites are never mandatory on every PR unless a profile or policy
explicitly requires it.

## Related

- [`testing-discipline-governance.md`](testing-discipline-governance.md)
- [`acceptance-test-evidence.md`](acceptance-test-evidence.md)
- [`tdd-evidence-policy.md`](tdd-evidence-policy.md)
