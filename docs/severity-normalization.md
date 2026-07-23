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
| `LOW` / `INFO` | reported as informational; **never gated** |
| `UNKNOWN` / absent | counted as `medium_vulnerabilities` — an unclassifiable vulnerability is still a vulnerability |

> **npm `MODERATE` → `medium`** is explicit (v0.1.27 fix): dropping it would hide real CVEs from the
> strict `medium` gate. Guarded by `self-test`.

## Per-scanner mapping + caveats

| Scanner | Mapping | Caveat |
|---|---|---|
| composer audit / npm audit | native severity → `*_vulnerabilities` (npm `MODERATE`→medium) | an advisory carrying **no** `severity` is counted as medium, not dropped; npm online analyzer may rate-limit (partial) |
| **OWASP Dependency-Check** | exact `.severity` STRING match → `critical/high/medium` | **no CVSS score is parsed** — the collector matches the severity label verbatim (`MODERATE`→medium), so a non-standard label (e.g. from RetireJS) is not bucketed. An earlier revision described CVSS bucketing that does not exist. |
| Trivy (fs/image) | `Vulnerabilities[]`→`*_vulnerabilities`; `Misconfigurations[]`→`iac_violations`; `Secrets[]`→`secrets` | three separate channels — a misconfiguration is not a vulnerability; fs-mode is the validated path |
| Grype | native → `critical/high/medium` | severity-mapped from match severity |
| OSV-Scanner | `database_specific.severity` → `critical/high/medium`; when unlabelled, the CVSS vector is classified by impact metrics (all-high → critical, any high impact → high, else medium) | a high/critical vector is never downgraded to medium; a vulnerability with no severity signal at all still counts as medium, never dropped |
| CodeQL | `security-severity` (>=9 critical, >=7 high) else effective SARIF `level` (error→high, warning/note→medium) | the level is resolved from the RULE's `defaultConfiguration` when the result omits it |
| Semgrep | `CRITICAL`→critical, `ERROR`/`HIGH`→high, `WARNING`/`MEDIUM`→medium | `INFO`/`LOW` are informational and **never gate** (docs/severity-policy.md) |
| **Checkov** | failed-check count → `iac_violations` (per-framework ARRAY output is summed) | **count, not graded**; IaC stays `ci-validated (evidence-fixture)`, NOT live-validated |
| **Terrascan** | violation count → `iac_violations` | **count, not graded**; same IaC maturity caveat |
| **Conftest** | failure count → `iac_violations` | **count, not graded**; same IaC maturity caveat |
| Deptrac | violation count → `architecture_violations` | **binary** severity (count), not graded |
| ZAP / Nuclei | **filtered** finding count → `dast_findings` | ZAP counts `riskcode >= 2`; Nuclei keeps `critical/high/medium` only. So `dast_findings: 0` means "no Medium+ finding", NOT "no findings". Manual/non-default; never auto-run. |
| Claude Code review / Kuzushi | finding count → `ai_review_findings` | **non-gating**, non-deterministic |

## Unknown / unmapped severity

A severity the collector does not recognize is **never silently dropped into `pass`**: it is
counted into the safest available bucket (medium) or surfaced as advisory. A scanner that did not
run maps to `unavailable` (not a fake clean). Collectors exit `2` on malformed input (no guessing).

Until the audit's collector fixes landed this paragraph was **not true** of several collectors —
`osv-scanner` collapsed every severity into `high` with `critical` hardcoded to 0, `codeql` could
never emit a critical at all, and `composer-audit` returned zero for advisories that carried no
`severity` field. Those are corrected above; the statement now describes the code.

## Channel separation

Quality findings are never folded into vulnerability counters, and vice-versa
(`scripts/enforce-gates.sh`). Two collectors used to violate this and no longer do:

- **ESLint** mapped every lint WARNING to `medium_vulnerabilities` (blocking in strict), so 50
  unused-variable warnings failed a release gate as "50 medium vulnerabilities". Lint findings are
  `type_errors`; only `security/` and `no-unsanitized/` rule hits are `high_vulnerabilities`. Those
  security findings were additionally **double-counted** into both keys, because they are a subset
  of `errorCount` — they are now subtracted from the lint count.
- **TruffleHog** dropped findings explicitly marked `Verified: false`. TruffleHog reports unverified
  findings by default and non-verifiable custom detectors *always* do, so real leaked credentials
  contributed nothing to a gate that blocks in every mode. All findings are counted; the
  verified/unverified split is reported for triage.

### Known remaining mismatch

**actionlint** maps its finding count to `unsafe_github_actions`, the same key as `zizmor` and
`github-actions-pins`. actionlint reports YAML/shellcheck/expression **lint** errors, so a style
error blocks as an "unsafe GitHub Action" from baseline up. This is deliberately **not** changed
here: unlike every other item in this pass it fails *safe* (over-blocking, not under-blocking), and
routing it correctly needs a workflow-lint summary key that does not exist yet — a schema change,
not a mapping fix.

## Notes

- IaC severity caveats here do **not** change IaC maturity — see
  [`scanner-maturity-policy.md`](scanner-maturity-policy.md).
- Cross-checks: [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md),
  [`severity-policy.md`](severity-policy.md).
