# Testing Discipline Governance (v2.2.0)

Sentinel Shield enforces test-first discipline through evidence:
production-change-without-test-change detection, changed-line coverage,
missing/empty test evidence, mutation testing, focused-test guards,
BDD specification evidence, and ATDD acceptance-test evidence.

```txt
TDD evidence proxies
BDD executable specifications
ATDD acceptance evidence
```

The gate is producer-agnostic: anything that can emit the normalized reports can feed it —
Behat, Cucumber.js, Playwright, Cypress, a Pest feature suite, or a 20-line script of your own.

## What this does and does not prove

**TDD cannot be proven from final code.** TDD is a workflow — a discipline about the *order* in
which code is written. A final code snapshot does not record that order. Neither a green
coverage report nor a passing suite distinguishes a test written first from one written a week
later to satisfy a gate.

So Sentinel Shield enforces TDD evidence proxies, not developer intent.

Sentinel Shield does **not** claim:

- that it proves true TDD;
- that it guarantees BDD quality;
- that it replaces product-owner acceptance;
- that it understands business intent automatically.

A green testing-discipline gate means "the evidence we asked for exists, and what it reports is
clean". Whether the tests are *good* tests, and whether the scenarios describe behavior anyone
wants, remains a human judgement.

BDD/ATDD evidence is only required when configured or when an app profile enables it in
strict/regulated mode. **Libraries are not forced to carry BDD/ATDD by default.**

Evidence status of the feature itself: **testing discipline governance is supported by engine
tests and fixtures** (`tests/prod/290-testing-discipline-governance.sh`). Do not claim real
consumer proof until a real Laravel/Symfony/Node consumer validation exists.

## Summary keys

| Key | Type | Meaning |
| --- | --- | --- |
| `production_change_without_test_change` | integer gate | Production-change groups where source/application behavior changed without any matching test/spec/feature/acceptance change. **A proxy, not proof.** |
| `missing_test_change_evidence` | boolean gate | True when Sentinel Shield could not compute changed-file evidence for a PR/diff where the profile expects it (no git work tree, no resolvable diff base, unreadable report). |
| `behavior_spec_count` | informational | BDD behavior specs/scenarios detected or executed (`spec_count + scenario_count`), summed across producers. |
| `missing_behavior_specification` | boolean gate | True when behavior-specification evidence is **expected** but absent/unavailable/errored — or a producer ran and declared zero specs and zero scenarios. |
| `orphan_behavior_specifications` | integer gate | Behavior specs/features with no matching implementation/test evidence, **when the producer can determine it**. Producers that cannot report `0`. |
| `acceptance_test_count` | informational | Acceptance-level tests/scenarios executed, summed across producers. |
| `acceptance_test_failures` | integer gate | Failing acceptance tests/scenarios, summed across producers. |
| `missing_acceptance_evidence` | boolean gate | True when acceptance evidence is **expected** but absent/unavailable/errored, or a report exists with `tests: 0`. |

All eight are optional and additive: an older summary that omits them stays valid, and an
absent key reads as `0` / `false`. Testing-discipline findings are their own channel and are
**never** folded into vulnerability counters.

## Mode defaults

| Gate | report-only | baseline | strict | regulated |
| --- | ---: | ---: | ---: | ---: |
| `production_change_without_test_change` | false | false | true | true |
| `missing_test_change_evidence` | false | false | true | true |
| `missing_behavior_specification` | false | false | true for app profiles | true for app profiles |
| `orphan_behavior_specifications` | false | false | false | true |
| `acceptance_test_failures` | false | true when evidence exists | true | true |
| `missing_acceptance_evidence` | false | false | true for app profiles | true for app profiles |

```txt
baseline:
  If acceptance evidence exists and tests fail, fail.
  The TDD proxy and the BDD/ATDD evidence gates stay visible but non-blocking,
  so an adopting project can wire producers up first.

strict:
  Production change without a test change blocks.
  Changed-file evidence that could not be computed blocks.
  Application profiles must also produce BDD/ATDD evidence they opted into.

regulated:
  Adds orphan behavior specifications.
```

**App profiles** are `laravel`, `symfony`, `node`, `react`, `laravel-react-docker`,
`node-react`, `hardened-enterprise`, plus any profile whose `project.type` is an application
type. A `php-library` reaching `regulated` is still never asked for Gherkin or a browser suite.
Any project can opt in explicitly:

```yaml
gates:
  fail_on:
    missing_behavior_specification: true
```

## When is evidence "expected"?

`missing_*` becomes true **only** when that evidence was expected. Two independent sources,
either sufficient:

1. the **profile** declares a `required` producer in that category (`testing-discipline`,
   `bdd`, `atdd`); or
2. the project's **policy** requires it — `testing_discipline.bdd.enabled` plus
   `require_behavior_specs` (and the ATDD equivalent).

By default profiles ship BDD/ATDD producers as `optional`, so nothing is demanded from a
project that never opted in. The TDD proxy ships as `required` because it needs no project
tooling at all — only a git history.

Policy can also switch a channel off honestly: `testing_discipline.enabled: false`, or the
per-channel `enabled` flag. An absent policy means TDD on, BDD/ATDD off.

## Resolver flags

```env
SENTINEL_SHIELD_FAIL_ON_PRODUCTION_CHANGE_WITHOUT_TEST_CHANGE=
SENTINEL_SHIELD_FAIL_ON_MISSING_TEST_CHANGE_EVIDENCE=
SENTINEL_SHIELD_FAIL_ON_MISSING_BEHAVIOR_SPECIFICATION=
SENTINEL_SHIELD_FAIL_ON_ORPHAN_BEHAVIOR_SPECIFICATIONS=
SENTINEL_SHIELD_FAIL_ON_ACCEPTANCE_TEST_FAILURES=
SENTINEL_SHIELD_FAIL_ON_MISSING_ACCEPTANCE_EVIDENCE=
```

## Producers

| Channel | Runner | Report | Adapter |
| --- | --- | --- | --- |
| TDD proxy | `scripts/runners/test-change-evidence.sh` | `reports/raw/test-change-evidence.json` | — (reads git directly) |
| BDD (PHP) | `scripts/runners/behat.sh` | `reports/raw/behavior-specs.json` | `behat-junit-to-behavior-specs.php` |
| BDD (JS) | `scripts/runners/cucumber-js.sh` | `reports/raw/behavior-specs.json` | `cucumber-json-to-behavior-specs.mjs` |
| ATDD (browser) | `scripts/runners/playwright.sh`, `cypress.sh` | `reports/raw/acceptance-tests.json` | `playwright-json-to-acceptance-tests.mjs`, `junit-to-acceptance-tests.mjs` |
| ATDD (PHP) | `scripts/runners/behat-acceptance.sh` | `reports/raw/acceptance-tests.json` | `junit-to-acceptance-tests.php` |
| ATDD (JS Gherkin) | `scripts/runners/cucumber-acceptance.sh` | `reports/raw/acceptance-tests.json` | — (inline mapping) |

Every producer reports honestly: a binary that is absent is `unavailable`, a missing config is
`not-configured`, a run that produced nothing readable is `execution-error`. **None of them
ever fakes a clean result.** An unknown status fails closed as `execution-error`.

## Execution scheduling

```txt
test-change-evidence: PR true, main true
behavior-specs:       PR true if configured
acceptance-tests:     main true, scheduled true (PR only if fast)
Playwright/Cypress:   main true, scheduled true
```

Slow browser acceptance suites are **not** mandatory on every PR unless the profile or policy
explicitly requires it.

## Related

- [`tdd-evidence-policy.md`](tdd-evidence-policy.md) — the TDD proxy in detail
- [`bdd-atdd-evidence.md`](bdd-atdd-evidence.md) — BDD/ATDD contracts and opt-in
- [`acceptance-test-evidence.md`](acceptance-test-evidence.md) — ATDD specifics, including `tests: 0`
- [`test-discipline-waivers.md`](test-discipline-waivers.md) — waiving the TDD proxy honestly
- [`architecture-governance.md`](architecture-governance.md) — the v2.1.0 sibling feature
