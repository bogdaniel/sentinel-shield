# Severity Normalization Spec (v1.8.0 — A05)

How Sentinel Shield maps each scanner's severity vocabulary onto the normalized summary keys. This is
**best-effort** and documented honestly; tune per project. Guarded by `self-test v180-completion`.

## Normalized summary keys

`critical_vulnerabilities`, `high_vulnerabilities`, `medium_vulnerabilities` (severity-graded);
plus count keys that are **not** CVSS-graded: `iac_violations`, `architecture_violations`,
`type_errors`, `style_violations`, `unsafe_docker`, `unsafe_github_actions`, `secrets`,
`container_image_violations`, `dast_findings`, `ai_review_findings`, `repository_health_warnings`.

## Canonical severity mapping

| Source vocabulary | → normalized |
|---|---|
| `CRITICAL` | `critical_vulnerabilities` |
| `HIGH` | `high_vulnerabilities` |
| `MEDIUM` / **`MODERATE`** (npm) | `medium_vulnerabilities` |
| `LOW` / `INFO` / `UNKNOWN` | not gated by default (advisory; review) |

> **npm `MODERATE` → `medium`** is explicit (v0.1.27 fix): dropping it would hide real CVEs from the
> strict `medium` gate. Guarded by `self-test`.

## Per-scanner mapping + caveats

| Scanner | Mapping | Caveat |
|---|---|---|
| composer audit / npm audit | native severity → `*_vulnerabilities` (npm `MODERATE`→medium) | npm online analyzer may rate-limit (partial) |
| **OWASP Dependency-Check** | exact `.severity` STRING match → `critical/high/medium` | **no CVSS score is parsed** — the collector matches the severity label verbatim, so a non-standard label (e.g. from RetireJS) is not bucketed. An earlier revision described CVSS bucketing that does not exist. |
| Trivy (fs/image) | native → `*_vulnerabilities` | fs-mode is the validated path |
| Grype | native → `critical/high/medium` | severity-mapped from match severity |
| OSV-Scanner | **all → `high`** unless a normalized `{critical,high,medium}` is supplied | coarse — triage per project |
| CodeQL | SARIF `level` (error→high, warning→medium) | not CVSS; JS/TS validated |
| Semgrep | rule severity → `*_vulnerabilities` | curated SS rules; INFO→medium visible-for-triage |
| **Checkov** | finding count → `iac_violations` | **count, not graded**; IaC stays `ci-validated (evidence-fixture)`, NOT live-validated |
| **Terrascan** | violation count → `iac_violations` | **count, not graded**; same IaC maturity caveat |
| **Conftest** | failure count → `iac_violations` | **count, not graded**; same IaC maturity caveat |
| Deptrac | violation count → `architecture_violations` | **binary** severity (count), not graded |
| ZAP / Nuclei | **filtered** finding count → `dast_findings` | ZAP counts `riskcode >= 2`; Nuclei keeps `critical/high/medium` only. So `dast_findings: 0` means "no Medium+ finding", NOT "no findings". Manual/non-default; never auto-run. |
| Claude Code review / Kuzushi | finding count → `ai_review_findings` | **non-gating**, non-deterministic |

## Unknown / unmapped severity

A severity the collector doesn't recognize is **never silently dropped into `pass`**: it is counted
into the safest available bucket or surfaced as advisory. A scanner that did not run maps to
`unavailable` (not a fake clean). Collectors exit `2` on malformed input (no guessing).

## Notes

- IaC severity caveats here do **not** change IaC maturity — see
  [`scanner-maturity-policy.md`](scanner-maturity-policy.md).
- Cross-checks: [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md),
  [`severity-policy.md`](severity-policy.md).
