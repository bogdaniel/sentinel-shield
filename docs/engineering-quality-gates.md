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
| `changed_lines_coverage_violations` | New/changed-line (diff) coverage below `quality.coverage.changed_lines_min`, summed across stacks. |
| `skipped_tests` | Count of skipped tests. |
| `focused_test_violations` | Focused markers (`describe.only`/`it.only`/`test.only`/`->only()`). |
| `skipped_test_marker_violations` | Skip markers (`markTestSkipped`/`markTestIncomplete`/`it.skip`/`xit`/`xdescribe`). |
| `debug_code_violations` | Debug residue (`dd`/`dump`/`var_dump`/`print_r`/`ray`/`die`/`exit`; `debugger`/`console.log`/`console.debug`). |
| `large_file_violations` | Files over `quality.maintainability.max_file_lines`. |
| `large_function_violations` | Functions over `quality.maintainability.max_function_lines` (best-effort/external — see below). |
| `missing_coverage_evidence` | (boolean) An applicable coverage tool produced **no** valid report — strict/regulated fail on ABSENT coverage, not only on bad coverage. |
| `missing_test_evidence` | (boolean) An APPLICABLE test stack produced **no** valid test report (profile-aware; `--profile` only; absent→`false`). |
| `empty_test_suite` | (boolean) An applicable test report exists but ran **zero** tests (profile-aware). |

Informational metrics also travel in the summary (never gate directly): `coverage_line_percent`,
`coverage_branch_percent`, `coverage_method_percent`, `coverage_class_percent`,
`mutation_score_percent`, `complexity_max`, `complexity_average`, `duplication_percent`,
`dead_code_count`, `changed_lines_coverage_percent` (aggregate = **minimum** across stacks),
`test_count` (**sum**), `max_file_lines` (**maximum**), `max_function_lines` (**maximum**).

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
| `changed_lines_coverage_violations` | false | **true** | **true** | **true** |
| `missing_test_evidence` | false | **true** | **true** | **true** |
| `empty_test_suite` | false | **true** | **true** | **true** |
| `debug_code_violations` | false | **true** | **true** | **true** |
| `focused_test_violations` | **true** | **true** | **true** | **true** |
| `skipped_test_marker_violations` | false | false | **true** | **true** |
| `large_file_violations` | false | false | **true** | **true** |
| `large_function_violations` | false | false | **true** | **true** |
| `skipped_tests` | false | false | false | **true** |

- **report-only** — collect and report quality metrics; nothing new blocks — **except**
  `focused_test_violations`, which blocks in every mode (a `.only()` left in the suite silently
  disables the rest of the tests).
- **baseline** — quality metrics are visible but non-blocking (existing test/type/architecture/
  security gates behave as before). Migrate here first. Baseline additionally blocks the
  high-confidence signals `changed_lines_coverage_violations`, `missing_test_evidence`,
  `empty_test_suite`, and `debug_code_violations` (plus `focused_test_violations`).
- **strict** — coverage threshold, coverage regression, complexity, and duplication block, plus
  `skipped_test_marker_violations`, `large_file_violations`, and `large_function_violations`.
  Mutation, dead-code, and `skipped_tests` stay off (they are slow/noisy).
- **regulated** — everything strict blocks, plus mutation, dead-code, and `skipped_tests`.

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

## Changed-lines (diff) coverage

Whole-project coverage can stay green while a PR adds untested lines. The **diff-coverage** signal
scores only the **new/changed** lines and gates them against `quality.coverage.changed_lines_min`
(0..100) — falling below it sets `changed_lines_coverage_violations`. PHP is produced deterministically
by [`scripts/runners/php-diff-coverage.sh`](../scripts/runners/php-diff-coverage.sh) (a `git diff`
intersected with per-line Clover coverage via
[`scripts/adapters/clover-diff-to-coverage-json.php`](../scripts/adapters/clover-diff-to-coverage-json.php)),
written to `reports/raw/diff-coverage.json` (per-stack alias `php-diff-coverage.json`). JS diff
coverage is **external/normalized input** — there is no bundled JS runner; drop a normalized
`reports/raw/js-diff-coverage.json`. The informational `changed_lines_coverage_percent` aggregates as
the **minimum** across stacks (the weakest stack drives the gate); `changed_lines_coverage_violations`
is the **sum**. Default mode: report-only false, baseline/strict/regulated **true**.

## Test evidence & empty suites

Two boolean gates make "the tests actually ran" a first-class signal (both **profile-aware** — raised
only when the summary is built with `--profile`; absent reads as `false`):

- `missing_test_evidence` — an **applicable** test stack produced no valid test report.
- `empty_test_suite` — an applicable test report exists but ran **zero** tests.

The `tests` collector also emits informational `test_count` (total tests run, **summed** across stacks)
and the `skipped_tests` counter. **PHP and JS test evidence are independent**: PHP tests never satisfy
a JS requirement and vice-versa — a green PHP suite does not excuse a missing/empty JS suite (mirroring
the independent `php-tests`/`js-tests` groups and the independent coverage channels). Default mode for
both booleans: report-only false, baseline/strict/regulated **true**.

## Focused & skipped test markers

- `focused_test_violations` — focused markers (`describe.only`/`it.only`/`test.only`/`->only()`) that
  silently disable the rest of a suite. This gate **blocks in every mode, including report-only** — a
  stray `.only()` is never acceptable.
- `skipped_test_marker_violations` — skip markers (`markTestSkipped`/`markTestIncomplete`/`it.skip`/
  `xit`/`xdescribe`). Blocks in strict/regulated.
- `skipped_tests` — the runtime count of skipped tests (from the `tests` collector). A counter, gated
  only in **regulated**.

Focused/skip markers are scanned by [`scripts/runners/focused-tests.sh`](../scripts/runners/focused-tests.sh)
(grep-based, always-available) into `reports/raw/focused-tests.json`.

## Debug residue

`debug_code_violations` counts debug leftovers scanned by
[`scripts/runners/debug-code.sh`](../scripts/runners/debug-code.sh) (grep-based, always-available) into
`reports/raw/debug-code.json`: PHP `dd`/`dump`/`var_dump`/`print_r`/`ray`/`die`/`exit`; JS `debugger`/
`console.log`/`console.debug`. Default mode: report-only false, baseline/strict/regulated **true**.

## Maintainability size gates

- `large_file_violations` — files over `quality.maintainability.max_file_lines`.
- `large_function_violations` — functions over `quality.maintainability.max_function_lines`.

Both thresholds are integers ≥ 1 and gate in strict/regulated. The source scanner
[`scripts/runners/source-size.sh`](../scripts/runners/source-size.sh) (grep/`wc -l`-based, always
available) implements **large-FILE** detection fully (`wc -l` vs `max_file_lines`) into
`reports/raw/source-size.json`, plus informational `max_file_lines`/`max_function_lines`. **Large-FUNCTION
detection is deliberately best-effort/external for now**: a pure-shell scan cannot reliably count
per-function lines, so the runner holds `large_function_violations` (and `max_function_lines`) at `0`
rather than emit false positives. The gate and collector are fully wired and accept an
externally-normalized `source-size.json` from a real per-function counter when one is dropped in.

## Profile execution on PRs

The **fast** quality tools now run on pull requests (`execution.pr: true`) so quality regresses are
caught before merge, not only on `main`: `php-coverage`/`php-complexity`/`php-duplication` and
`js-coverage`/`js-duplication`, plus the new `php-diff-coverage`/`js-diff-coverage`, `focused-tests`,
`debug-code`, and `source-size`. The **slow** signals — mutation and dead-code — stay `pr: false`
(scheduled/main only). See [`profile-tool-policy.md`](profile-tool-policy.md).

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
    changed_lines_min: 80        # diff-coverage threshold for new/changed lines (0..100)
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
  maintainability:
    max_file_lines: 500          # large_file_violations threshold (integer >= 1)
    max_function_lines: 80       # large_function_violations threshold (integer >= 1; best-effort)
  dead_code:
    enabled: false
```

`quality.coverage.changed_lines_min` and the `quality.maintainability.*` thresholds are
optional/additive — an absent key falls back to the documented built-in defaults. A **malformed**
value (non-numeric threshold, `max_file_lines`/`max_function_lines` below 1) fails closed (exit `2`),
exactly like the other thresholds.

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
