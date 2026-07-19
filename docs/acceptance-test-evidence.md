# Acceptance Test Evidence — ATDD (v2.2.0)

Acceptance evidence answers: did acceptance-level tests execute, and did they pass?

## What this does and does not prove

Sentinel Shield does **not** replace product-owner acceptance.

A passing acceptance suite is evidence that the acceptance criteria *someone encoded as tests*
still hold. It is not a product owner saying "yes, this is what I wanted". Sentinel Shield does
not understand business intent automatically: it cannot tell whether the encoded criteria match
the real ones, whether they are complete, or whether the feature is worth shipping.

What it does prevent is the cheap failure mode — an acceptance suite that silently stopped
running, or reports green after executing nothing.

## The contract

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

Mapping:

```txt
tests                        -> acceptance_test_count
failures                     -> acceptance_test_failures
missing_acceptance_evidence  -> missing_acceptance_evidence
```

Allowed statuses: `pass`, `findings`, `unavailable`, `not-configured`, `execution-error`,
`disabled`, `not-applicable`. An unknown status fails closed as `execution-error`.

## Rules

- **Failing acceptance tests fail the gate.** `acceptance_test_failures` blocks from baseline
  upward: evidence that exists and reports failures is actionable today.
- **Missing acceptance evidence only fails when expected** by policy or profile
  (`testing_discipline.atdd.enabled` + `require_acceptance_evidence`, or a `required` ATDD
  producer). A project that never adopted acceptance testing is not failed for its absence.
- **`status: execution-error` counts as missing acceptance evidence.** The suite was supposed
  to run and produced nothing readable — that is an absence of evidence, not a pass.
- **Never a fake pass.** A runner whose binary is missing writes `unavailable`; a missing config
  writes `not-configured`. It never writes `tests: 0, failures: 0` from a run that did not
  happen.

## Documented choice: `tests: 0`

**A report with `tests: 0` is treated as MISSING acceptance evidence, not as a clean pass.**

Rationale: a suite that executed zero tests proves nothing. Treating it as green would make the
easiest way to pass the gate "break the test runner so it collects nothing" — precisely the
outcome this gate exists to catch. It is recorded as `missing_acceptance_evidence: true`, which
then blocks only where that evidence was expected.

Consequence worth knowing: if you legitimately have no acceptance tests yet, do not wire a
producer that emits an empty report. Leave ATDD off (the default) until the suite exists. Then
`missing_acceptance_evidence` is never expected and never fires.

The same rule applies to BDD: a behavior-spec producer reporting zero specs and zero scenarios
is missing evidence, not clean.

## Failures vs absence are separate facts

```txt
acceptance_test_failures     -> the suite ran and something is broken
missing_acceptance_evidence  -> the suite did not run, or ran nothing
```

A suite that never ran contributes `0` to `acceptance_test_failures` — it is caught by
`missing_acceptance_evidence` instead. Keeping these distinct means "we skipped it" can never
be mistaken for "it passed", and a red suite is never reported as an infrastructure problem.

## Producers

| Tool | Runner | Adapter |
| --- | --- | --- |
| Playwright | `scripts/runners/playwright.sh` | `playwright-json-to-acceptance-tests.mjs` |
| Cypress | `scripts/runners/cypress.sh` | `junit-to-acceptance-tests.mjs` |
| Behat (acceptance suite) | `scripts/runners/behat-acceptance.sh` | `junit-to-acceptance-tests.php` |
| Cucumber.js (acceptance) | `scripts/runners/cucumber-acceptance.sh` | inline |
| Anything emitting JUnit | — | `junit-to-acceptance-tests.{php,mjs}` |

JUnit `errors` are counted as **failures**: from an acceptance point of view, a scenario that
blew up is a scenario that did not pass. Playwright's `flaky` outcome is reported separately and
not counted as a failure — it passed on retry — so a flaky suite does not silently turn the
gate red.

## Scheduling

Browser acceptance suites are slow. The shipped profiles run them on main and on a schedule,
not on every PR:

```txt
acceptance-tests:   pr false, main true, scheduled true
```

Do not make slow browser acceptance suites mandatory for every PR unless the profile or policy
explicitly requires it.

## Related

- [`testing-discipline-governance.md`](testing-discipline-governance.md)
- [`bdd-atdd-evidence.md`](bdd-atdd-evidence.md)
