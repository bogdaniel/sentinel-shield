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
| kuzushi.json | Kuzushi | `{findings:[…]}` | kuzushi.sh | ai_review_findings (non-gating) | unavailable | exit 2 | scanner-matrix |

All collectors are exercised by `scripts/self-test.sh` (`scanner-matrix` for v0.1.12 tools,
named suites for the mature core). Severity fidelity caveats: see production-readiness-audit.md.
