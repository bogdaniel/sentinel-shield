# Engineering Quality Gates (v2.1)

Sentinel Shield gates four families of signal, kept in **separate counters** that are never
folded into one another:

| Family | Examples | Summary keys |
| --- | --- | --- |
| **Security** | secrets, vulnerabilities, third-party supply-chain, unsafe Docker/Actions, SBOM | `secrets`, `*_vulnerabilities`, `third_party_*`, `unsafe_*`, `missing_sbom` |
| **Engineering quality** | tests, coverage, coverage regression, mutation, complexity, duplication, dead code | `test_failures`, `coverage_threshold_violations`, `coverage_regression`, `mutation_score_violations`, `complexity_violations`, `duplication_violations`, `dead_code_violations` |
| **Architecture** | Deptrac + architecture tests | `architecture_violations` |
| **Release / evidence** | missing evidence, expired exceptions, required-tool failures, scanner coverage | `missing_release_evidence`, `expired_exceptions`, `required_tool_failures` |

This document covers the **engineering-quality** family added in v2.1. Coverage and mutation
metrics are quality signals — they are **not** security findings, and they are **not**
architecture. In particular:

- **A coverage regression is not a vulnerability.** It lands in `coverage_regression`, never in
  `*_vulnerabilities`.
- **Deptrac is not coverage.** Deptrac measures *architectural dependency direction* and maps to
  `architecture_violations`. It has nothing to do with how much code your tests exercise. The two
  are orthogonal: a project can have 100% coverage and still violate its layering rules.

## How they differ from security gates

Security gates answer "is this release *safe to ship*?" Quality gates answer "is this codebase
*maintainable and adequately tested*?" They are reported in different sections of the enforcement
report, use different counters, and have their own mode defaults. A missing security scanner fails
closed as a required-tool control; a missing quality tool is reported honestly as `unavailable`
and, for the recommended/optional policies used by default, does not block.

## The gates

| Gate (summary key) | Meaning |
| --- | --- |
| `coverage_threshold_violations` | Count of coverage thresholds breached (line/branch/method/class). |
| `coverage_regression` | 1 when coverage dropped vs the recorded baseline for any stack. |
| `mutation_score_violations` | Mutation score (MSI) below the configured minimum. |
| `complexity_violations` | Functions/methods over the complexity threshold. |
| `duplication_violations` | Duplicated-code percentage over the threshold. |
| `dead_code_violations` | Unused exports/files/symbols over policy. |
| `missing_coverage_evidence` | (boolean) An applicable coverage tool produced **no** valid report — strict/regulated fail on ABSENT coverage, not only on bad coverage. |

Informational metrics also travel in the summary (never gate directly): `coverage_line_percent`,
`coverage_branch_percent`, `coverage_method_percent`, `coverage_class_percent`,
`mutation_score_percent`, `complexity_max`, `complexity_average`, `duplication_percent`,
`dead_code_count`.

## Mode defaults

| Gate | report-only | baseline | strict | regulated |
| --- | ---: | ---: | ---: | ---: |
| `coverage_threshold_violations` | false | false | **true** | **true** |
| `coverage_regression` | false | false | **true** | **true** |
| `mutation_score_violations` | false | false | false | **true** |
| `complexity_violations` | false | false | **true** | **true** |
| `duplication_violations` | false | false | **true** | **true** |
| `dead_code_violations` | false | false | false | **true** |
| `missing_coverage_evidence` | false | false | **true** | **true** |

- **report-only** — collect and report quality metrics; nothing new blocks.
- **baseline** — quality metrics are visible but non-blocking (existing test/type/architecture/
  security gates behave as before). Migrate here first.
- **strict** — coverage threshold, coverage regression, complexity, and duplication block.
  Mutation and dead-code stay off (they are slow/noisy).
- **regulated** — everything strict blocks, plus mutation and dead-code.

Existing gate defaults (`test_failures`, `style_violations`, `type_errors`,
`architecture_violations`, security) are unchanged.

## How coverage is collected

1. A **runner** executes the test suite with coverage output:
   - PHP: [`scripts/runners/php-coverage.sh`](../scripts/runners/php-coverage.sh) runs
     `vendor/bin/pest --coverage-clover …` (or PHPUnit) and normalizes the Clover XML via
     [`scripts/adapters/clover-to-coverage-json.php`](../scripts/adapters/clover-to-coverage-json.php).
   - JS/TS: [`scripts/runners/js-coverage.sh`](../scripts/runners/js-coverage.sh) runs the
     project's `test:coverage`/`coverage` script and normalizes `coverage/coverage-summary.json`
     via [`scripts/adapters/istanbul-summary-to-coverage-json.mjs`](../scripts/adapters/istanbul-summary-to-coverage-json.mjs).
2. The runner applies the **thresholds** from `.sentinel-shield/quality-policy.yaml` and compares
   against a **baseline** file if configured, producing `reports/raw/php-coverage.json` /
   `reports/raw/js-coverage.json`.
3. The `coverage` collector maps that into `coverage_threshold_violations` /`coverage_regression`
   plus the informational percentages.
4. `build-security-summary.sh` merges collectors into `security-summary.json`; `enforce-gates.sh`
   judges it against the resolved gate flags.

**Coverage driver:** PHP coverage needs Xdebug or PCOV; JS needs a coverage-capable reporter
(Istanbul `json-summary`). When the driver/reporter is absent the runner leaves the report
**absent** (status `unavailable`) — it never writes a fake-clean 0.

**Strict/regulated require coverage to actually run.** Because the coverage tools are
`recommended`, an absent coverage report would otherwise leave the violation/regression counters at
`0` and let strict pass with *no coverage at all*. To prevent that, `build-security-summary.sh --profile`
sets `missing_coverage_evidence: true` whenever the profile declares an **applicable** coverage tool
(`php-coverage`/`js-coverage`) that produced no valid report. In strict/regulated that boolean gate
fails the build — so "no coverage evidence" is a real failure, not a silent pass. In combined
profiles each applicable stack must produce its own coverage report. (The gate only has teeth when
the summary is built with `--profile`; a profile-less/older summary omits the key, which reads as
`false` for back-compat.)

## How coverage regression works

Record a baseline (a small JSON with `line_percent`/`branch_percent`), point
`quality.coverage.baseline_file` at it, and set `quality.coverage.fail_on_decrease: true`. On each
run the adapter compares the current line/branch percentages to the baseline; any decrease sets
`regression: true`, which the collector maps to `coverage_regression = 1`. Refresh the baseline
deliberately (e.g. after an intentional, reviewed drop) — it is a project-owned file.

### Combined-profile aggregation

In combined profiles (Laravel + React, hardened-enterprise) PHP and JS coverage are **independent**:
`reports/raw/php-coverage.json` and `reports/raw/js-coverage.json` never overwrite each other, and
one stack can never satisfy the other. The builder aggregates them:

- `coverage_threshold_violations` = **sum** of per-stack violations.
- `coverage_regression` = **1 if any** stack regressed.
- `coverage_line_percent` / `coverage_branch_percent` = **minimum** across applicable stacks — the
  weakest-covered stack drives the gate. Per-stack detail stays visible under `.tools.php_coverage`
  / `.tools.js_coverage`.

## How mutation testing works

Mutation testing injects small faults and checks whether tests catch them; the mutation score
indicator (MSI) is the percentage caught. Runners: [`infection.sh`](../scripts/runners/infection.sh)
(PHP Infection) and [`stryker.sh`](../scripts/runners/stryker.sh) (StrykerJS). Below
`quality.mutation.min_score` sets `mutation_score_violations = 1`. Mutation testing is **slow**, so
it is optional/scheduled by default and only gates in **regulated** mode.

## Complexity, duplication, dead code

- **Complexity** — [`phpmd-complexity.sh`](../scripts/runners/phpmd-complexity.sh) (PHPMD codesize).
  JS complexity is optional/external (drop a normalized `reports/raw/js-complexity.json`).
- **Duplication** — [`phpcpd.sh`](../scripts/runners/phpcpd.sh) (PHPCPD) /
  [`jscpd.sh`](../scripts/runners/jscpd.sh) (jscpd).
- **Dead code** — [`knip.sh`](../scripts/runners/knip.sh) (knip, then ts-prune). PHP dead-code is
  optional/external until a tool is wired (drop a normalized `reports/raw/php-dead-code.json`).

Each runner leaves its report **absent** when its tool is not installed — never a fake-clean 0.

## Quality policy configuration

Thresholds live in `.sentinel-shield/quality-policy.yaml` (copy from
[`templates/quality-policy.example.yaml`](../templates/quality-policy.example.yaml); schema:
[`schemas/quality-policy.schema.json`](../schemas/quality-policy.schema.json)). Whether a gate
*blocks* is decided by the adoption mode + `gates.fail_on` in `.sentinel-shield/profile.yaml`; this
file only holds the numeric thresholds and baseline pointers:

```yaml
quality:
  coverage:
    enabled: true
    line_min: 80
    branch_min: 60
    fail_on_decrease: true
    baseline_file: reports/quality/coverage-baseline.json
  mutation:
    enabled: false
    min_score: 70
  complexity:
    enabled: true
    max_cyclomatic_complexity: 10
  duplication:
    enabled: true
    max_percentage: 5
  dead_code:
    enabled: false
```

**Fail closed:** when this file is present but malformed (unparseable YAML, a non-numeric threshold,
a non-boolean flag) the runners exit `2`. It is never silently ignored. An **absent** policy is
fine — runners fall back to the documented built-in defaults above.

## How to override gates

Every gate is overridable per project in `.sentinel-shield/profile.yaml`:

```yaml
gates:
  mode: strict
  fail_on:
    coverage_threshold_violations: true
    coverage_regression: true
    mutation_score_violations: false   # opt out of mutation gating even in regulated
```

Invalid (non-boolean) override values fail closed (exit `2`). Quality gates are **not** suppressible
via accepted-risk records — a quality regression is loud by design. To stop blocking on one, set its
`fail_on` flag to `false` or drop to a lower mode.

## Report-only → strict promotion

1. **report-only / baseline** — install the runners, let coverage/complexity/duplication report.
   Nothing new blocks; read the numbers in the enforcement report.
2. Record a coverage **baseline** and set realistic `line_min`/`branch_min`.
3. **strict** — coverage threshold/regression, complexity, and duplication now block. Fix or
   consciously lower a threshold.
4. **regulated** — enable mutation and dead-code once the pipeline can absorb the time cost.

See also [`gate-resolution.md`](gate-resolution.md), [`security-summary-schema.md`](security-summary-schema.md),
[`profile-tool-policy.md`](profile-tool-policy.md), [`raw-report-contract.md`](raw-report-contract.md).
