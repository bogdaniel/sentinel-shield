# Enterprise Scanner Matrix

> **v0.1.16 — canonical maturity lives elsewhere.** The single source of truth for a tool's
> maturity label (`proven` / `supported` / `experimental` / `manual` / `template-only` /
> `non-gating` / `not-ready`) is [`product-status.md`](product-status.md). This matrix maps tools
> to gate categories and summary keys; if a label here disagrees with product-status, product-status
> wins. **Proven today:** the core PR-fast set (Gitleaks, curated app-Semgrep, PHPStan, PHPUnit,
> composer audit, php-syntax, Hadolint, base-digest, GH-pins, Trivy-fs) plus php-style, TypeScript,
> and the dependency-policy detector (zenchron run 27170148123). Everything else is
> supported/experimental/manual/template-only/non-gating.
>
> **v0.1.17 — branch-safe validation.** The MAIN-category tools below can now be run from any
> branch/PR with [`scripts/run-main-gate-validation.sh`](../scripts/run-main-gate-validation.sh)
> (no `workflow_dispatch`, no merge-first), producing the same raw reports. This unblocks live
> validation; it does **not** by itself promote any tool to `proven` — that still needs a cited
> consumer run. See [`main-gate-validation-strategy.md`](main-gate-validation-strategy.md).

> **v0.1.13 maturity note (read first).** v0.1.12 added scanner *breadth*; the integrations
> are NOT equally mature. See [`production-readiness-audit.md`](production-readiness-audit.md)
> for the brutally-honest per-tool A–F status. **Maturity labels:**
> **proven** (validated on a real consumer / full fixture) ·
> **supported** (runner/collector/self-test exists, no live consumer yet) ·
> **experimental** (noisy/limited parser — e.g. OSV/CodeQL severity is coarse) ·
> **template-only** (workflow/docs exist, not executed by default) ·
> **manual** (needs explicit target/approval — DAST) ·
> **non-gating** (report-only unless explicitly enabled — AI review).
> Proven today: the original core (Gitleaks, app-Semgrep, PHPStan, PHPUnit, composer audit,
> Hadolint, base-digest, GH-pins, Trivy-fs) via the zenchron pilot. Most v0.1.12 additions are
> **supported/experimental**, not proven.


Status of every tool in the Sentinel Shield scanner matrix. **Honesty:** "Integration"
means the Sentinel Shield side — a **collector** that normalizes the tool's raw report into
a summary key, a **gate**, and a **self-test**. The scanner binaries themselves run in CI
(workflow templates) or locally; Sentinel Shield does not bundle them. A row marked
*collector ✓* is a fully-wired, self-tested integration even though the tool is external.

Legend — **Gate category:** PR = PR fast gate · MAIN = main-branch gate · NIGHT =
scheduled/nightly · MANUAL = controlled/manual (DAST/AI). **Blocking** = which modes gate it
by default (see `resolve-gates.sh`).

| Tool | Before v0.1.12 | After v0.1.12 | Gate cat | Raw report | Collector | Summary key | Blocks (baseline/strict/regulated) | Default on? | Needs secret/target? | Safe for PR? | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Gitleaks | done | done | PR | gitleaks.json | gitleaks.sh | secrets | ✓/✓/✓ (never suppressible) | yes | no | yes | existing |
| TruffleHog | missing | **collector ✓** | NIGHT | trufflehog.json | trufflehog.sh | secrets | ✓/✓/✓ | nightly | no | deep=nightly | verified-only count |
| Semgrep (app) | done | done | PR | semgrep.json | semgrep.sh | critical/high/medium_vulnerabilities | ✓/✓/✓ | yes | no | yes | existing |
| Semgrep (third-party) | done | done | MAIN | third-party-semgrep.json | third-party-semgrep.sh | third_party_* | strict+/regulated | yes | no | yes | existing |
| CodeQL | partial (workflow only) | **collector ✓** | MAIN | codeql.json (SARIF) | codeql.sh | high/medium_vulnerabilities | ✓(high)/✓/✓ | main | no | heavy→main | SARIF level→severity (coarse) |
| PHPStan/Larastan | done | done | PR | phpstan.json | phpstan.sh | type_errors | ✓/✓/✓ | yes | no | yes | existing runner |
| Psalm | partial | **collector ✓** (existing) | PR | psalm.json | psalm.sh | type_errors | ✓/✓/✓ | opt-in | no | yes | maps to type_errors |
| PHP syntax (php -l) | missing | **collector+runner ✓** | PR | php-syntax.json | php-syntax.sh | php_syntax_errors | ✓/✓/✓ | yes | no | yes | runner: scripts/runners/php-syntax.sh |
| Pint / PHP-CS-Fixer / PHPCS | partial | **collector ✓** | PR | php-style.json | php-style.sh | style_violations | ✗/✓/✓ | yes | no | yes | style → strict+ |
| composer audit | done | done | PR | composer-audit.json | composer-audit.sh | *_vulnerabilities | ✓/✓/✓ | yes | no | yes | existing |
| npm audit | done | done | PR | npm-audit.json | npm-audit.sh | *_vulnerabilities | ✓/✓/✓ | yes | no | yes | existing |
| OSV-Scanner | missing | **collector+audit ✓** | MAIN | osv-scanner.json | osv-scanner.sh | high_vulnerabilities | ✓/✓/✓ | main | no | heavy→main | severity coarse (all→high); see limitations |
| Grype | missing | **collector+audit ✓** | MAIN/NIGHT | grype.json | grype.sh | critical/high/medium_vulnerabilities | ✓/✓/✓ | main | no | heavy→main | severity-mapped |
| OWASP Dependency-Check | missing | **collector+audit ✓** | MAIN | dependency-check.json | dependency-check.sh | critical/high/medium_vulnerabilities | ✓/✓/✓ | main | no | slow→main | severity-mapped |
| Trivy (fs) | done | done | MAIN | trivy.json | trivy.sh | *_vulnerabilities | ✓/✓/✓ | yes | no | yes | existing |
| Trivy (image) | partial | workflow (nightly) | NIGHT | trivy.json | trivy.sh | *_vulnerabilities | ✓/✓/✓ | nightly | needs image | no | reuses trivy collector |
| Syft (SBOM) | done | done | MAIN | sbom.spdx.json | (evidence) | missing_sbom | ✗/✓/✓ | yes | no | yes | existing |
| OpenSSF Scorecard | missing | **collector+audit ✓** | NIGHT | scorecard.json | scorecard.sh | repository_health_warnings | ✗/✗/✓ | nightly | repo token (CI) | no | regulated-only gate |
| actionlint | done | done | PR | actionlint.json | actionlint.sh | unsafe_github_actions | ✓/✓/✓ | yes | no | yes | existing |
| zizmor | done | done | PR | zizmor.json | zizmor.sh | unsafe_github_actions | ✓/✓/✓ | yes | no | yes | existing |
| GH Actions pin audit | done | done | PR | github-actions-pins.json | github-actions-pins.sh | unsafe_github_actions | ✓/✓/✓ | yes | no | yes | existing |
| Deptrac | done | done | PR/MAIN | deptrac.json | deptrac.sh | architecture_violations | ✓/✓/✓ | yes | no | yes | existing |
| Architecture tests | partial | maps→deptrac collector | MAIN | deptrac.json | deptrac.sh | architecture_violations | ✓/✓/✓ | opt-in | no | yes | run as project test → deptrac fmt |
| ESLint | done | done | PR | eslint.json | eslint.sh | type_errors/medium/high | ✓/✓/✓ | yes | no | yes | existing |
| TypeScript --noEmit | done | done | PR | typescript.json | typescript.sh | type_errors | ✓/✓/✓ | yes | no | yes | existing |
| Hadolint | done | done | PR | hadolint.json | hadolint.sh | unsafe_docker | ✓/✓/✓ (finding-scoped) | yes | no | yes | existing |
| Docker base digest | done | done | PR | docker-base-digest.json | docker-base-digest.sh | unsafe_docker | ✓/✓/✓ | yes | no | yes | existing |
| Dockle | missing | **collector+audit ✓** | NIGHT | dockle.json | dockle.sh | container_image_violations | ✗/✓/✓ | nightly | needs image | no | built-image checks |
| Checkov | missing | **collector+audit ✓** | MAIN | checkov.json | checkov.sh | iac_violations | ✗/✓/✓ | if IaC | no | yes | IaC |
| Conftest / OPA | partial | **collector+audit ✓** | MAIN | conftest.json | conftest.sh | iac_violations | ✗/✓/✓ | if IaC | no | yes | OPA/Rego policies exist |
| Terrascan | missing | **collector+audit ✓** | MAIN | terrascan.json | terrascan.sh | iac_violations | ✗/✓/✓ | if IaC | no | yes | IaC |
| OWASP ZAP baseline | partial (ci-zap) | **collector+runner (MANUAL) ✓** | MANUAL | zap.json | zap.sh | dast_findings | ✗/✗/✓ | **off** | **target+allowlist** | **no** | passive; fail-closed guard |
| OWASP ZAP full | missing | **collector+runner (MANUAL) ✓** | MANUAL | zap-full.json | zap.sh | dast_findings | ✗/✗/✓ | **off** | **target+allowlist** | **no** | active; approval required |
| Nuclei | missing | **collector+runner (MANUAL) ✓** | MANUAL | nuclei.json | nuclei.sh | dast_findings | ✗/✗/✓ | **off** | **target+allowlist** | **no** | controlled; allowlist |
| Claude Code Security Review | missing | **collector+template (assistive)** | MANUAL/AI | ai-security-review.json | ai-security-review.sh | ai_review_findings | **never default** | off | API key (CI) | advisory | non-gating unless explicitly enabled |
| Kuzushi | missing | **collector+template (assistive)** | MANUAL/AI | kuzushi.json | kuzushi.sh | ai_review_findings | **never default** | off | varies | advisory | investigation aid; non-gating |

## Dependency-policy note
OSV / Grype / Dependency-Check map to the existing **severity** vuln keys
(`critical/high/medium_vulnerabilities`), consistent with Trivy/composer/npm. The
`dependency_policy_violations` key + gate exist for an explicit dependency-policy tool
(license/version/allowlist breaches) and have **no default emitter** in v0.1.12 — they are
declared, gated in baseline+, and reserved. See [`dependency-policy.md`](dependency-policy.md).

## Limitations (honest)
- **Severity parsing is best-effort.** OSV-Scanner output severity is coarse — the collector
  counts all OSV vulnerabilities as `high` unless a normalized `{critical,high,medium}` is
  supplied. CodeQL maps SARIF `level` (error→high, warning→medium), not CVSS. Tune per project.
- **Collectors normalize; they do not run the scanners.** The binaries run via the workflow
  templates (`templates/workflows/`) or `scripts/audits/*` wrappers (which no-op when the
  binary is absent — never a fake clean report).
- **Finding-scoped accepted-risk** remains implemented **only for `unsafe_docker`**. New count
  gates support broad `scope:"gate"` suppression only (reported as broad). `secrets` is never
  suppressible. See [`accepted-risk-suppression.md`](accepted-risk-suppression.md).
- **DAST/Nuclei never scan arbitrary targets** — require `SENTINEL_SHIELD_DAST_TARGET_URL` +
  `SENTINEL_SHIELD_DAST_ALLOWED_HOST`; missing target → skip, host mismatch → fail closed.
  See [`dast-policy.md`](dast-policy.md).
- **AI review is assistive, non-deterministic, and non-gating by default** — even in regulated
  mode — unless the profile explicitly sets `gates.fail_on.ai_review_findings: true`. See
  [`ai-review-policy.md`](ai-review-policy.md).

## v0.1.18 — main-gate promotions (cited)
**CodeQL, OSV-Scanner, Trivy-fs, Syft SBOM** are now **live-validated** (zenchron run 27214865086;
artifacts in [`main-gate-live-evidence.md`](main-gate-live-evidence.md)). Grype, OWASP
Dependency-Check, Dockle, Deptrac, Checkov/Conftest/Terrascan remain **experimental/not-configured**
(no live evidence). ZAP/Nuclei manual; AI review non-gating.

## v0.1.19 — main-gate execution hardening
Grype (SBOM-first/fs/container), Dependency-Check (disabled-default; nightly), Dockle (image-gated)
have hardened execution paths + env vars, but are **NOT promoted** (no live consumer artifact).
Semgrep 1.165.0 fixture-verified (0 parser errors), not consumer-verified. See
[`main-gate-execution-hardening-v0.1.19.md`](main-gate-execution-hardening-v0.1.19.md) and
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). DAST/Nuclei/AI unchanged (manual/non-gating).
