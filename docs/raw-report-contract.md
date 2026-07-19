# Raw Report Compatibility Contract (v0.1.13)

Every collector reads `reports/raw/<name>.json`. **Missing/empty input → status `unavailable`,
counts 0, exit 0** (never fake-clean). **Invalid JSON → exit 2** (hard error). Collectors emit
a normalized object `{tool,status,summary{...},tool_report}` merged by `build-security-summary.sh`.

| Raw path | Producer | Expected shape (key fields) | Collector | Summary key | Missing | Invalid | Fixture |
|---|---|---|---|---|---|---|---|
| gitleaks.json | Gitleaks | array / `{findings}` | gitleaks.sh | secrets | unavailable | exit 2 | templates/raw |
| semgrep.json | Semgrep | `{results:[{extra.severity}]}` | semgrep.sh | crit/high/med vulns | unavailable | exit 2 | templates/raw |
| trivy.json | Trivy | `{Results[].Vulnerabilities[].Severity}` | trivy.sh | *_vulnerabilities | unavailable | exit 2 | templates/raw |
| composer-audit.json | composer audit | `{advisories}` | composer-audit.sh | *_vulnerabilities | unavailable | exit 2 | templates/raw |
| npm-audit.json | npm audit | `{vulnerabilities}` | npm-audit.sh | *_vulnerabilities | unavailable | exit 2 | templates/raw |
| phpstan.json | laravel-phpstan.sh | `{totals.file_errors}` | phpstan.sh | type_errors | unavailable | exit 2 | templates/raw |
| psalm.json | Psalm | array of issues | psalm.sh | type_errors | unavailable | exit 2 | scanner-matrix |
| tests.json | phpunit/vitest/jest adapter | `{failures,errors}` | tests.sh | test_failures | unavailable | exit 2 | templates/raw |
| eslint.json | ESLint --format json | `[{errorCount,messages}]` | eslint.sh | type_errors/med/high | unavailable | exit 2 | templates/raw |
| typescript.json | tsc collector | `{errors}` | typescript.sh | type_errors | unavailable | exit 2 | templates/raw |
| deptrac.json | Deptrac | native `{report.violations}`/`{Report.Violations}`/`{violations}` or normalized contract | deptrac.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| php-arkitect.json | runners/php-arkitect.sh | normalized architecture contract | php-arkitect.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| php-architecture-tests.json | runners/php-architecture-tests.sh | normalized architecture contract | php-architecture-tests.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| dependency-cruiser.json | dependency-cruiser | native `{summary:{violations[],ruleSetUsed.forbidden[]}}` or normalized contract | dependency-cruiser.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| eslint-boundaries.json | ESLint boundary rules | native ESLint JSON array or normalized contract | eslint-boundaries.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| js-architecture-tests.json | runners/js-architecture-tests.sh | normalized architecture contract | js-architecture-tests.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| hadolint.json | run-hadolint.sh | array `[{code,file,level}]` | hadolint.sh | unsafe_docker | unavailable | exit 2 | self-test |
| docker-base-digest.json | audit-docker-base-digest.sh | `[{rule_id:SS_DOCKER_BASE_DIGEST}]` | docker-base-digest.sh | unsafe_docker | unavailable | exit 2 | self-test |
| github-actions-pins.json | audit-github-actions-pins.sh | `{findings}` | github-actions-pins.sh | unsafe_github_actions | unavailable | exit 2 | self-test |
| actionlint.json / zizmor.json | actionlint/zizmor | native | actionlint.sh/zizmor.sh | unsafe_github_actions | unavailable | exit 2 | self-test |
| codeql.json | CodeQL (SARIF) | `{runs[].results[].level}` | codeql.sh | high/med vulns | unavailable | exit 2 | scanner-matrix |
| php-syntax.json | runners/php-syntax.sh | `{errors,files}` | php-syntax.sh | php_syntax_errors | unavailable | exit 2 | scanner-matrix |
| php-style.json | Pint/PHP-CS-Fixer | `{files:[…]}` | php-style.sh | style_violations | unavailable | exit 2 | scanner-matrix |
| osv-scanner.json | OSV-Scanner | `{results[].packages[].vulnerabilities}` | osv-scanner.sh | high_vulnerabilities | unavailable | exit 2 | scanner-matrix |
| grype.json | Grype | `{matches[].vulnerability.severity}` | grype.sh | *_vulnerabilities | unavailable | exit 2 | scanner-matrix |
| dependency-check.json | OWASP DC | `{dependencies[].vulnerabilities[].severity}` | dependency-check.sh | *_vulnerabilities | unavailable | exit 2 | scanner-matrix |
| scorecard.json | OpenSSF Scorecard | `{checks[].score}` | scorecard.sh | repository_health_warnings | unavailable | exit 2 | scanner-matrix |
| trufflehog.json | TruffleHog | array `[{Verified}]` | trufflehog.sh | secrets | unavailable | exit 2 | scanner-matrix |
| checkov.json | Checkov | `{summary.failed}`/`{results.failed_checks}` | checkov.sh | iac_violations | unavailable | exit 2 | scanner-matrix |
| conftest.json | Conftest | `[{failures}]` | conftest.sh | iac_violations | unavailable | exit 2 | scanner-matrix |
| terrascan.json | Terrascan | `{results.violations}` | terrascan.sh | iac_violations | unavailable | exit 2 | scanner-matrix |
| dockle.json | Dockle | `{details[].level}` | dockle.sh | container_image_violations | unavailable | exit 2 | scanner-matrix |
| zap.json / zap-full.json | OWASP ZAP | `{site[].alerts[].riskcode}` | zap.sh | dast_findings | unavailable | exit 2 | scanner-matrix |
| nuclei.json | Nuclei | array `[{info.severity}]` | nuclei.sh | dast_findings | unavailable | exit 2 | scanner-matrix |
| ai-security-review.json | Claude Code Sec Review | `{findings:[…]}` | ai-security-review.sh | ai_review_findings (non-gating) | unavailable | exit 2 | scanner-matrix |
| dependency-policy.json | audits/dependency-policy.sh | `{count,violations[]}` | dependency-policy.sh | dependency_policy_violations | unavailable | exit 2 | feature-completion |
| architecture-tests.json | runners/architecture-tests.sh | `{violations:N}` / normalized architecture contract | architecture-tests.sh | architecture_violations | unavailable | exit 2 | 280-architecture-governance |
| test-change-evidence.json | runners/test-change-evidence.sh | normalized testing-discipline contract | test-change-evidence.sh | production_change_without_test_change, expired_exceptions | unavailable | exit 2 | 290-testing-discipline-governance |
| behat-specs.json | Behat (via adapter) | normalized behavior-specs contract | behavior-specs.sh | behavior_spec_count, orphan_behavior_specifications | unavailable | exit 2 | 290-testing-discipline-governance |
| cucumber-specs.json | Cucumber.js (via adapter) | normalized behavior-specs contract | behavior-specs.sh | behavior_spec_count, orphan_behavior_specifications | unavailable | exit 2 | 290-testing-discipline-governance |
| behavior-specs.json | custom/manual producer | normalized behavior-specs contract | behavior-specs.sh | behavior_spec_count, orphan_behavior_specifications | unavailable | exit 2 | 290-testing-discipline-governance |
| playwright-acceptance.json | Playwright (via adapter) | normalized acceptance-tests contract | acceptance-tests.sh | acceptance_test_count, acceptance_test_failures | unavailable | exit 2 | 290-testing-discipline-governance |
| cypress-acceptance.json | Cypress (via adapter) | normalized acceptance-tests contract | acceptance-tests.sh | acceptance_test_count, acceptance_test_failures | unavailable | exit 2 | 290-testing-discipline-governance |
| behat-acceptance.json | Behat acceptance suite (via adapter) | normalized acceptance-tests contract | acceptance-tests.sh | acceptance_test_count, acceptance_test_failures | unavailable | exit 2 | 290-testing-discipline-governance |
| cucumber-acceptance.json | Cucumber.js acceptance run | normalized acceptance-tests contract | acceptance-tests.sh | acceptance_test_count, acceptance_test_failures | unavailable | exit 2 | 290-testing-discipline-governance |
| acceptance-tests.json | custom/manual producer | normalized acceptance-tests contract | acceptance-tests.sh | acceptance_test_count, acceptance_test_failures | unavailable | exit 2 | 290-testing-discipline-governance |
| kuzushi.json | Kuzushi | `{findings:[…]}` | kuzushi.sh | ai_review_findings (non-gating) | unavailable | exit 2 | scanner-matrix |
| coverage.json (php-/js-coverage.json) | php-coverage.sh / js-coverage.sh | `{line_percent,violations,regression}` | coverage.sh | coverage_threshold_violations / coverage_regression | unavailable | exit 2 | 270-quality-gates |
| mutation.json (php-/js-mutation.json) | infection.sh / stryker.sh | `{score_percent,violations}` | mutation.sh | mutation_score_violations | unavailable | exit 2 | 270-quality-gates |
| complexity.json (php-/js-complexity.json) | phpmd-complexity.sh | `{max_complexity,violations}` | complexity.sh | complexity_violations | unavailable | exit 2 | 270-quality-gates |
| duplication.json (php-/js-duplication.json) | phpcpd.sh / jscpd.sh | `{duplication_percent,violations}` | duplication.sh | duplication_violations | unavailable | exit 2 | 270-quality-gates |
| dead-code.json (php-/js-dead-code.json) | knip.sh / external | `{dead_code_count,violations}` | dead-code.sh | dead_code_violations | unavailable | exit 2 | 270-quality-gates |
| diff-coverage.json (php-/js-diff-coverage.json) | php-diff-coverage.sh (git diff × Clover) / external JS | `{changed_lines_coverage_percent,violations}` | diff-coverage.sh | changed_lines_coverage_violations | unavailable | exit 2 | 270-quality-gates |
| focused-tests.json | focused-tests.sh (grep) | `{focused_test_violations,skipped_test_marker_violations}` | focused-tests.sh | focused_test_violations / skipped_test_marker_violations | unavailable | exit 2 | 270-quality-gates |
| debug-code.json | debug-code.sh (grep) | `{debug_code_violations}` | debug-code.sh | debug_code_violations | unavailable | exit 2 | 270-quality-gates |
| source-size.json | source-size.sh (wc -l) | `{large_file_violations,max_file_lines,max_function_lines}` | source-size.sh | large_file_violations / large_function_violations | unavailable | exit 2 | 270-quality-gates |

The `tests.json` collector additionally emits informational `test_count` + the `skipped_tests` counter
(and the profile builder derives the `missing_test_evidence`/`empty_test_suite` booleans). The
grep/`wc -l`-based runners (focused-tests, debug-code, source-size) are always available, so a clean
scan is a real `pass`; `source-size` holds `large_function_violations`/`max_function_lines` at `0`
(large-function is best-effort/external) but accepts an externally-normalized value.

Engineering-quality raw reports (v2.1) are a **separate channel** from security. In combined
profiles the per-stack aliases (`php-coverage.json`, `js-coverage.json`, …) both feed the same
summary counter: violations SUM across stacks, coverage percentages take the MINIMUM (the weakest
stack drives the gate), and `coverage_regression` is 1 if ANY stack regressed. See
[`engineering-quality-gates.md`](engineering-quality-gates.md).

All collectors are exercised by `scripts/self-test.sh` (`scanner-matrix` for v0.1.12 tools,
named suites for the mature core). Severity fidelity caveats: see production-readiness-audit.md.

## v2.1 — normalized architecture raw contract

Sentinel Shield enforces architecture governance through **normalized architecture evidence**.
Deptrac is the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are JS/TS
producers. Custom architecture tests can also emit the same contract. Architecture raw reports are a
**separate channel** from security and are never folded into vulnerability counters. Full reference:
[`architecture-governance.md`](architecture-governance.md).

Every architecture producer writes `reports/raw/<producer>.json` in this shape (or a native shape the
matching collector understands):

```json
{
  "tool": "architecture",
  "status": "pass",
  "violations": 0,
  "rule_count": 12,
  "context_count": 4,
  "failures": []
}
```

Each `failures[]` entry carries the crossed boundary:

```json
{
  "rule": "domain-must-not-depend-on-infrastructure",
  "from": "App\\Domain\\Order\\Order",
  "to": "App\\Infrastructure\\Persistence\\DoctrineOrderRepository",
  "message": "Domain layer depends on Infrastructure"
}
```

Allowed **raw-report** statuses: `pass`, `findings`, `unavailable`, `not-configured`,
`execution-error`, `disabled`, `not-applicable`. (The **collector** it feeds emits `fail` rather
than `findings` when it maps violations — the vocabulary every other finding-mapping collector in
this table uses. The builder treats the two identically; see
[`architecture-governance.md`](architecture-governance.md#two-status-surfaces-do-not-conflate-them).)
Rules the engine enforces:

- `pass` + `violations: 0` = the suite ran clean; `findings` + `violations > 0` = it ran and found
  violations. Only those two count as evidence.
- `unavailable`, `not-configured`, `execution-error`, `disabled`, `not-applicable` are **preserved**,
  never collapsed into a clean pass.
- An unknown status **fails closed** as `execution-error`; a missing/empty raw report becomes
  `unavailable`; invalid JSON exits 2.
- An unknown **native** tool shape must NOT become `pass` — it becomes `execution-error`.

The normalized contract is implemented once in `scripts/collectors/architecture.sh`; the per-producer
collectors above are entry points over it, exactly as `php-coverage`/`js-coverage` share
`collectors/coverage.sh`. The `eslint-boundaries` collector counts **only** boundary rules
(`boundaries/*`, `import/no-restricted-paths`, `no-restricted-imports`) — general ESLint findings map
to their own summary keys via `eslint.json` and are never double-counted as architecture violations.

Producers feed `architecture_violations` (**summed**) plus the informational
`architecture_rule_count` (summed), `architecture_tool_count` (producers with valid evidence), and
`architecture_context_count` (**maximum** across producers — they describe the same codebase, so
summing would double-count). With `--profile`, an applicable producer that emitted no valid evidence
sets `missing_architecture_evidence`. All of these keys are optional/additive: an older summary that
omits them stays valid, and an absent key reads as `0`/`false`.

> Architecture tools detect dependency-boundary violations, not the quality of domain modeling
> itself. Architecture governance is supported by engine tests and fixtures
> (`280-architecture-governance`). Do not claim real consumer proof until a real
> Laravel/Symfony/Node consumer validation exists.

## Main-gate validation harness output (v0.1.17)

[`scripts/run-main-gate-validation.sh`](../scripts/run-main-gate-validation.sh) produces the **same**
raw paths above (it just runs the deterministic main-gate wrappers from any branch). It additionally
writes one **descriptive** (not collector-consumed) file:

| Path | Producer | Shape | Consumed by |
|---|---|---|---|
| main-gate-validation-tools.json | run-main-gate-validation.sh | `{version, target, output_dir, tools:{<tool>:{status,reason,report}}}` where status ∈ `pass\|fail\|unavailable\|skipped` | humans / CI (not the summary builder) |

The summary builder ignores files outside its tool table, so this descriptor coexists with the raw
reports in the same `reports/raw/` directory. Note the **filename mapping**: `--tool trivy-fs` writes
`trivy.json` (matching the `trivy` collector) and `--tool syft` writes the SBOM to
`<reports>/sbom.spdx.json` (where the builder reads it), not into `raw/`. Exercised by the
`main-gate-harness` self-test suite.

## v0.1.18 — main-gate live-validated raw reports
`codeql.json`, `osv-scanner.json`, `trivy.json`, `sbom.spdx.json` are now produced + parsed
against a real consumer (zenchron run 27214865086) — see
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). Missing/invalid behavior unchanged
(unavailable / exit 2).

## v0.1.21 — Dependency-Check collector contract (unchanged mapping)
`scripts/collectors/dependency-check.sh` is **unchanged** in v0.1.21 (no severity remap). Restated
for the record:
- **Input:** `reports/raw/dependency-check.json` — OWASP DC native JSON
  (`{dependencies[].vulnerabilities[].severity}`) **or** a normalized `{critical,high,medium}` object.
- **Severity mapping:** native `severity` is upper-cased and bucketed — `CRITICAL →
  critical_vulnerabilities`, `HIGH → high_vulnerabilities`, `MEDIUM → medium_vulnerabilities`
  (best-effort; severities outside these three are not counted). Consistent with OSV/Grype/Trivy.
- **Summary keys emitted:** `critical_vulnerabilities`, `high_vulnerabilities`,
  `medium_vulnerabilities` (all other contract keys default 0 via `ss_emit_collector`).
- **Status:** any bucket > 0 → `fail`; all zero → `pass`.
- **Missing/empty input → `unavailable`, exit 0. Invalid JSON → exit 2** (via `ss_collector_guard`).
  The hardened audit wrapper guarantees a non-zero-exit-but-valid-JSON report is preserved for this
  collector to parse, and discards partial/invalid output so it surfaces as `unavailable`, never
  fake-clean. See [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md).

## v0.1.19 — main-gate execution notes
- `grype.json`: produced from **SBOM** (`grype sbom:<spdx>`) by default, or **fs** (`grype dir:.`)
  when `SENTINEL_SHIELD_GRYPE_MODE=fs`. Same collector/severity mapping either way.
- `dependency-check.json`: only when `SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled` (slow; cached).
- `dockle.json`: only when `SENTINEL_SHIELD_IMAGE` is set (built image).
- `semgrep-image-verify.json` (+ `.log`): output of `scripts/verify-semgrep-image.sh` — a Semgrep
  run over a modern-PHP fixture; `.errors[]` with `PartialParsing`/`Syntax` = parser failures.
  Not a gated report; a tooling-verification artifact.

## v2.2.0 — normalized testing-discipline raw contracts

Sentinel Shield enforces test-first discipline through **evidence**:
production-change-without-test-change detection, changed-line coverage, missing/empty test
evidence, mutation testing, focused-test guards, BDD specification evidence, and ATDD
acceptance-test evidence. These are a **separate channel** from security and are never folded
into vulnerability counters. Full reference:
[`testing-discipline-governance.md`](testing-discipline-governance.md).

TDD cannot be proven from final code — these contracts carry PROXIES and EVIDENCE, not proof of
developer workflow.

### `test-change-evidence.json` (TDD proxy)

```json
{
  "tool": "test-change-evidence",
  "status": "findings",
  "production_changed_files": 3,
  "test_changed_files": 0,
  "production_change_without_test_change": 1,
  "missing_test_change_evidence": false,
  "expired_waivers": 0,
  "files": { "production": ["src/domain/order.ts"], "tests": [], "ignored": ["README.md"] }
}
```

- `production_change_without_test_change` → the gate of the same name (one violation per diff).
- `expired_waivers` → `expired_exceptions` (an expired waiver is an expired exception, and
  blocks in every mode).
- `missing_test_change_evidence` lives in the collector's `tool_report`, not the summary — the
  BUILDER decides whether that evidence was expected.

### behavior-specs contract (BDD)

Written to `behat-specs.json` / `cucumber-specs.json` per producer (or `behavior-specs.json` for a custom producer):

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

`spec_count + scenario_count → behavior_spec_count`. A producer that ran and declared **zero**
specs and zero scenarios is recorded as missing evidence, never as a clean pass.

### acceptance-tests contract (ATDD)

Written to `playwright-acceptance.json` / `cypress-acceptance.json` / `behat-acceptance.json` / `cucumber-acceptance.json` per producer (or `acceptance-tests.json` for a custom producer):

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

`tests → acceptance_test_count`, `failures → acceptance_test_failures`. **A report with
`tests: 0` is treated as MISSING acceptance evidence**, not a clean pass — a suite that ran
nothing proves nothing.

### Shared rules

Allowed statuses for all three: `pass`, `findings`, `unavailable`, `not-configured`,
`execution-error`, `disabled`, `not-applicable`. An **unknown status fails closed as
`execution-error`**; an unrecognized shape fails closed; a missing/empty report is
`unavailable`; invalid JSON exits 2. A malformed gating count is never coerced to a clean `0`.

### Producer raw report paths are distinct

The `acceptance-tests` and `behavior-specs` **contracts are generic** — every producer emits the
same shape, and the collector never cares which tool produced it. But each producer writes its
**own raw report path**, because a shared path means the producer that runs last silently
destroys the earlier producer's evidence before the collector ever sees it:

| Producer | Raw report | Collector emit-name |
| --- | --- | --- |
| Behat (specs) | `reports/raw/behat-specs.json` | `behat_specs` |
| Cucumber.js (specs) | `reports/raw/cucumber-specs.json` | `cucumber_specs` |
| Playwright | `reports/raw/playwright-acceptance.json` | `playwright_acceptance` |
| Cypress | `reports/raw/cypress-acceptance.json` | `cypress_acceptance` |
| Behat (acceptance) | `reports/raw/behat-acceptance.json` | `behat_acceptance` |
| Cucumber.js (acceptance) | `reports/raw/cucumber-acceptance.json` | `cucumber_acceptance` |
| custom / manual | `reports/raw/acceptance-tests.json`, `reports/raw/behavior-specs.json` | `acceptance_tests`, `behavior_specs` |

**Multiple ATDD (and BDD) producers aggregate.** `acceptance_test_count` and
`acceptance_test_failures` are SUMMED across producers, as is `behavior_spec_count`; the
`missing_*` booleans are OR-ed. Running Playwright *and* Cypress is a supported, correct setup —
they no longer overwrite each other, and their results add up.

The generic `acceptance-tests.json` / `behavior-specs.json` paths remain supported for a
**custom or manual** producer emitting the contract directly. No shipped profile claims those
paths, so a hand-rolled producer can never collide with a profile-declared one.

**Missing evidence is derived only when the channel is expected** — see the expectation rules
above. TDD cannot be proven from final code; BDD quality and product-owner acceptance are not
guaranteed by Sentinel Shield.
