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
| deptrac.json | Deptrac | `{Report.Violations}` | deptrac.sh | architecture_violations | unavailable | exit 2 | templates/raw |
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
| architecture-tests.json | runners/architecture-tests.sh | `{violations:N}` | architecture-tests.sh | architecture_violations | unavailable | exit 2 | feature-completion |
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
