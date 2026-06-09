# Main-Gate Live Evidence Registry

Canonical record of main-gate scanner integrations validated against a **real consumer** with
**downloaded artifact evidence**. A tool is promoted only when a real `reports/raw/*` artifact
exists, is valid, and its collector parsed it. No entry here is added from fixtures alone.

| Tool | Consumer | Workflow / Run ID | Artifact (size, validity) | Summary mapping | Promoted maturity | Known limitations | Next validation target |
|---|---|---|---|---|---|---|---|
| CodeQL (js/ts) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/codeql.json` (669 KB SARIF, valid) | 0 critical / 0 high / **11 medium** (SARIF `level→severity`) | **live-validated** | severity from SARIF `level`, not CVSS (coarse); JS/TS only (no PHP CodeQL in this run) | add PHP/`php` language; triage the 11 medium |
| OSV-Scanner | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/osv-scanner.json` (7.5 KB, valid) | **1 high** | **live-validated** | severity coarse (all→high unless normalized) | refine severity mapping; triage the 1 high |
| Trivy (filesystem) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/raw/trivy.json` (308 KB, valid) | 0/0/0 (clean) | **live-validated** | fs-mode only; image-mode still unproven | run a Trivy image scan with a built image |
| Syft (SBOM) | bogdaniel/zenchron-tools | sentinel-shield-main-validation / **27214865086** | `reports/sbom.spdx.json` (964 KB SPDX, valid) | evidence: `missing_sbom=false` | **live-validated** | presence/validity only (not a vuln gate) | feed SBOM to Grype (SBOM-scan mode) |
| Grype | — | — | — | critical/high/medium_vulnerabilities | **NOT promoted** (experimental) | binary absent on runner; wrapper reported `unavailable` (no fake) | install via action/container; see main-gate-tool-installation.md |
| OWASP Dependency-Check | — | — | — | critical/high/medium_vulnerabilities | **NOT promoted** (experimental) | binary absent; slow | container-backed run on a consumer |
| Dockle | — | — | — | container_image_violations | **NOT promoted** (experimental) | needs a built image | run after an image build |
| Deptrac | — | — | — | architecture_violations | **NOT promoted** (not-configured) | no `deptrac.yaml` in the pilot | validate on a project with defined layers |
| Checkov / Conftest / Terrascan | — | — | — | iac_violations | **NOT promoted** (not-applicable) | no IaC files in the pilot | validate on a repo with `*.tf`/k8s |
| ZAP / Nuclei / Claude Code / Kuzushi | — | — | — | dast_findings / ai_review_findings | **NOT promoted** (manual / non-gating) | not enabled (target allowlist + approval / non-deterministic) | dedicated approval-gated pass |

## Baseline evidence (release gate working)
| Consumer | Workflow / Run ID | Result | Interpretation |
|---|---|---|---|
| bogdaniel/zenchron-tools | sentinel-shield (baseline) / **27214863297** | **FAIL** on `critical_vulnerabilities=2` (npm: `shell-quote` via `concurrently@9.2.1`) | **Correct gate behavior** — a real npm critical blocked the gate. Consuming-project dependency fix (separate PR). NOT a Sentinel Shield bug; NOT suppressed; NOT accepted-risk. |

This registry is the source of truth for "what is live-validated." `product-status.md`,
`production-readiness-audit.md`, and `enterprise-scanner-matrix.md` defer to it.

## Semgrep image verification (v0.1.19 — FIXTURE, not live)
| Image | Method | Fixture | Parser errors | Findings | Status |
|---|---|---|---|---|---|
| **semgrep/semgrep:1.165.0** (output `.version`=1.165.0, via Docker) | `scripts/verify-semgrep-image.sh` | `tests/fixtures/semgrep/php-modern` (readonly/enum/attributes/match/promotion/typed) | **0** (`errors: []`) | 0 (15 rules) | **fixture-verified** |

This is a **fixture** result — it proves 1.165.0 parses modern PHP syntax that 1.90.0 failed on
(118 errors on the pilot). It is **NOT** a live consumer validation: re-run on zenchron-tools'
real `Modules/**/app` to confirm the 118 errors actually drop, then cite that run here. The
prior 1.90.0 evidence (118 parser errors) stands as the contrast.

## v0.1.20 — main-gate execution-path live evidence (zenchron run 27239206382)
Consumer **bogdaniel/zenchron-tools**, workflow `sentinel-shield-main-gate-evidence`, **run 27239206382** (success). All artifacts downloaded + collectors verified.

| Tool | Artifact (valid) | Collector → summary key | Promotion | Limitations |
|---|---|---|---|---|
| **Semgrep 1.165.0** (real app code) | `semgrep.json` 108 KB, `.version`=1.165.0 | semgrep.sh → 0 crit / 0 high / **25 medium** | **fixture-verified → CONSUMER-VERIFIED**: **0 parser errors** on real `Modules/**/app` (vs **118** on 1.90.0). 25 INFO findings → medium, **visible for triage (not suppressed)**. | curated SS rules only; medium findings need project triage |
| **Grype (SBOM-first)** | `grype.json` 5.3 KB, valid | grype.sh → 0/0/0 (0 matches) | **supported/experimental → LIVE-VALIDATED**: ran `grype sbom:` off the Syft SBOM (969 KB), collector parses severities to `*_vulnerabilities` | 0 matches this run (SBOM scope); container executor (anchore/grype:v0.114.0, tag — pin by digest) |
| **Dockle** (built `base` image stage) | `dockle.json` 955 B, valid | dockle.sh → `container_image_violations`=1 | **supported/experimental → LIVE-VALIDATED**: scanned a real built image stage; 4 details (1 WARN + 3 INFO) → 1 violation | scanned the `base` stage only (fast), not the full prod image; goodwithtech/dockle:v0.4.15 (tag — pin by digest) |
| **OWASP Dependency-Check** | — (no artifact) | — | **ATTEMPTED, NOT live-validated** | cold NVD download exceeds CI budget; the detached container ignored a step timeout. Run on a dedicated **nightly** job with a warm cache (see [`tooling/main-gate-tool-installation.md`](tooling/main-gate-tool-installation.md)). NOT faked, NOT promoted. |

**Headline:** the v0.1.18 Semgrep 1.165.0 fixture verification is now **confirmed on real consumer code** — the 118 PartialParsing errors are **gone (0)**. No Sentinel Shield bug surfaced; every wrapper/collector behaved correctly on real artifacts.
