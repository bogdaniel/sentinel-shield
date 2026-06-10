# Collector Fixture Library — v0.1.24 (all-collectors regression coverage)

One valid sample raw report per collector in `scripts/collectors/`, each shaped to match
that collector's real `jq` mapping (verified by reading the collector before authoring the
fixture). Each fixture carries a representative NON-zero finding so the captain's self-test can
assert the exact mapped count. `ai-security-review`, `kuzushi`, and `scorecard` map to `warn`
(non-gating / advisory); all others map to `fail` when findings are present.

Run a single collector:

```sh
sh scripts/collectors/<name>.sh --input tests/fixtures/collectors-v024/<name>.json
```

All 34 collectors were executed against their fixture; none errored (every run exit 0,
emitted a normalized `{tool,status,summary,tool_report}` object). Validated with:

```sh
python3 -c "import json,glob;[json.load(open(f)) for f in glob.glob('tests/fixtures/collectors-v024/*.json')];print(len(glob.glob('tests/fixtures/collectors-v024/*.json')),'fixtures valid')"
# -> 34 fixtures valid
```

| Collector | Fixture | Status | Summary key(s) | Count(s) |
|---|---|---|---|---|
| actionlint | actionlint.json | fail | unsafe_github_actions | 2 |
| ai-security-review | ai-security-review.json | warn | ai_review_findings | 2 |
| architecture-tests | architecture-tests.json | fail | architecture_violations | 2 |
| checkov | checkov.json | fail | iac_violations | 2 |
| codeql | codeql.json | fail | high_vulnerabilities / medium_vulnerabilities | 2 / 1 |
| composer-audit | composer-audit.json | fail | critical / high / medium_vulnerabilities | 1 / 1 / 1 |
| conftest | conftest.json | fail | iac_violations | 3 |
| dependency-check | dependency-check.json | fail | critical / high / medium_vulnerabilities | 1 / 1 / 1 |
| dependency-policy | dependency-policy.json | fail | dependency_policy_violations | 2 |
| deptrac | deptrac.json | fail | architecture_violations | 2 |
| docker-base-digest | docker-base-digest.json | fail | unsafe_docker | 2 |
| dockle | dockle.json | fail | container_image_violations | 2 |
| eslint | eslint.json | fail | type_errors / medium_vulnerabilities / high_vulnerabilities | 3 / 2 / 2 |
| github-actions-pins | github-actions-pins.json | fail | unsafe_github_actions | 3 |
| gitleaks | gitleaks.json | fail | secrets | 2 |
| grype | grype.json | fail | critical / high / medium_vulnerabilities | 1 / 1 / 2 |
| hadolint | hadolint.json | fail | unsafe_docker | 2 |
| kuzushi | kuzushi.json | warn | ai_review_findings | 1 |
| npm-audit | npm-audit.json | fail | critical / high / medium_vulnerabilities | 1 / 3 / 2 |
| nuclei | nuclei.json | fail | dast_findings | 3 |
| osv-scanner | osv-scanner.json | fail | high_vulnerabilities | 2 |
| php-style | php-style.json | fail | style_violations | 3 |
| php-syntax | php-syntax.json | fail | php_syntax_errors | 2 |
| phpstan | phpstan.json | fail | type_errors | 4 |
| psalm | psalm.json | fail | type_errors | 2 |
| scorecard | scorecard.json | warn | repository_health_warnings | 3 |
| semgrep | semgrep.json | fail | critical / high / medium_vulnerabilities | 1 / 1 / 1 |
| terrascan | terrascan.json | fail | iac_violations | 2 |
| tests | tests.json | fail | test_failures | 4 |
| trivy | trivy.json | fail | critical / high / medium_vulnerabilities | 1 / 2 / 1 |
| trufflehog | trufflehog.json | fail | secrets | 2 |
| typescript | typescript.json | fail | type_errors | 5 |
| zap | zap.json | fail | dast_findings | 3 |
| zizmor | zizmor.json | fail | unsafe_github_actions | 2 |

## Mapping notes (why each count is what it is)

- **semgrep**: ERROR→critical, WARNING→high, INFO→medium (1/1/1).
- **codeql**: SARIF `level` error→high (2), warning→medium (1); critical always 0.
- **osv-scanner**: native shape buckets every vuln into high (2); critical/medium 0.
- **phpstan**: `.totals.file_errors (3) + .totals.errors (1)` = 4.
- **eslint**: errorCount sum (3) → type_errors; warningCount sum (2) → medium; `security/`
  + `no-unsanitized/` severity-2 messages (2) → high (a security error is intentionally
  counted in both type_errors and high_vulnerabilities).
- **hadolint / dockle**: only error+warning (hadolint) / FATAL+WARN (dockle) are counted;
  info/style ignored — fixtures include one ignored row to prove the filter.
- **zap**: only alerts with `riskcode >= 2` (3 of 4) are counted.
- **nuclei**: only critical/high/medium severities (3 of 4) are counted; info ignored.
- **scorecard**: checks with `0 <= score < 5` (3) → warnings; `score == -1` and `score >= 5`
  excluded. Status is `warn`, not `fail`.
- **trufflehog**: counts items where `Verified == true` (2); the `Verified: false` row is excluded.
- **docker-base-digest / github-actions-pins**: producers emit a top-level JSON array of
  findings; collector counts array length.
- **deptrac**: native `.Report.Violations` (number) = 2.

## Skipped collectors

None. All 34 collectors in `scripts/collectors/` have a stable single-file JSON input and a
fixture here. (`scripts/collectors/third-party-semgrep.sh` exists but was not in the assigned
collector list and is not part of this fixture library.)
