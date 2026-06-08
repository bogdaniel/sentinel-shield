# Production Readiness Audit (v0.1.13)

Brutally honest status of every tool. **A tool is only "proven-live" if it ran in real CI
(the zenchron-tools pilot) or is exercised by a deterministic self-test fixture with stable
output handling.** Most v0.1.12 additions are **fixture-validated, not live-validated**.

## Classification
- **A. proven-live** — ran green in a real consumer CI (zenchron-tools) OR full deterministic fixture + stable parser.
- **B. implemented-but-fixture-only** — collector + self-test fixture (deterministic), no live consumer run yet.
- **C. collector-only** — collector exists, covered only by generic tests; parser not hardened.
- **D. template-only** — workflow/docs exist; not executed by default.
- **E. documented-only** — declared/reserved; no default emitter.
- **F. not production-ready** — manual/non-deterministic; do not rely on as a gate.

| Tool | Status | Runner | Collector | Workflow | Raw contract | Self-test fixture | Live CI | Pinned | Gate cat | Limitations / next action |
|---|---|---|---|---|---|---|---|---|---|---|
| Gitleaks | **A** | action | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | action tag→pin | PR | proven; pin action SHA in consumer |
| Semgrep (app) | **A** | image/action | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | image:latest→pin | PR | pin semgrep image digest before prod |
| PHPStan/Larastan | **A** | ✓ runner | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven (robust runner v0.1.10) |
| PHPUnit tests | **A** | adapter | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven |
| composer audit | **A** | native | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven |
| Hadolint | **A** | ✓ runner | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven (multi-Dockerfile) |
| Docker base digest | **A** | ✓ audit | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven |
| GH Actions pin audit | **A** | ✓ audit | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | n/a | PR | proven |
| Trivy (fs) | **A** | action | ✓ | ✓ | ✓ | ✓ | ✓ (zenchron) | action tag→pin | MAIN | proven; pin action |
| npm audit | **B** | native | ✓ | ✓ | ✓ | ✓ | partial | n/a | PR | run on a Node consumer to confirm |
| ESLint | **B** | action/native | ✓ | ✓ | ✓ | ✓ | no | n/a | PR | mapping conservative; live-validate |
| TypeScript --noEmit | **B** | native | ✓ | ✓ | ✓ | ✓ | no | n/a | PR | live-validate on React consumer |
| Vitest/Jest | **B** | adapters | ✓ | ✓ | ✓ | ✓ | no | n/a | PR | adapters fixture-tested only |
| Deptrac | **B** | native | ✓ | ✓ | ✓ | ✓ | no | n/a | PR/MAIN | live-validate |
| Syft (SBOM) | **B** | action | (evidence) | ✓ | ✓ | ✓ | no | action tag→pin | MAIN | evidence presence only |
| Psalm | **B** | native | ✓ | — | ✓ | ✓ | no | n/a | PR | maps→type_errors; opt-in |
| PHP syntax (php -l) | **B** | ✓ runner | ✓ | template | ✓ | ✓ | no | n/a | PR | runner real; live-validate |
| Pint/PHP-CS-Fixer | **B** | native | ✓ | template | ✓ | ✓ | no | n/a | PR | style→strict+ |
| third-party Semgrep | **B** | image | ✓ | ✓ | ✓ | ✓ | no | image→pin | MAIN | separate channel |
| CodeQL | **C** | action | ✓ | template | ✓ | ✓ | no | action tag→pin | MAIN | **SARIF level→severity is coarse**; needs real SARIF |
| OSV-Scanner | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | action tag→pin | MAIN | **severity coarse (all→high)**; refine parser |
| Grype | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | action→pin | MAIN/NIGHT | severity-mapped; live-validate |
| OWASP Dependency-Check | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | MAIN | slow; live-validate |
| OpenSSF Scorecard | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | action→pin | NIGHT | needs repo token in CI |
| TruffleHog | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | NIGHT | verified-only count; live-validate |
| Checkov | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | MAIN | IaC only |
| Conftest/OPA | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | MAIN | policies exist; live-validate |
| Terrascan | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | MAIN | IaC only |
| Dockle | **C** | ✓ audit | ✓ | template | ✓ | ✓ | no | image→pin | NIGHT | needs built image |
| Trivy (image) | **C** | action | ✓ (reuse) | template | ✓ | ✓ | no | action→pin | NIGHT | needs image ref |
| actionlint | **C/advisory** | image | ✓ | ✓ (advisory) | ✓ | partial | advisory | image:latest→pin | PR | advisory in self-test |
| zizmor | **C/advisory** | pipx | ✓ | ✓ (advisory) | ✓ | partial | advisory | n/a | PR | advisory; best-effort |
| ci-self-test workflows | **A** | — | — | ✓ | — | ✓ | ✓ (this repo) | **actions SHA-pinned** | — | blocking gate; pinned v0.1.13 |
| 5 consumer workflow templates | **D** | — | — | ✓ | — | workflow-sanity | no | tag (template-only) | varies | execute on a consumer to promote |
| OWASP ZAP baseline | **D/F** | ✓ runner (guard) | ✓ | ✓ | ✓ | ✓ (guard+collector) | no | action→pin | MANUAL | passive; manual+allowlist only |
| OWASP ZAP full | **F** | ✓ runner (guard) | ✓ (reuse) | ✓ | ✓ | guard | no | action→pin | MANUAL | active/intrusive; approval req'd |
| Nuclei | **F** | ✓ runner (guard) | ✓ | ✓ | ✓ | ✓ (guard+collector) | no | image→pin | MANUAL | manual+allowlist; not a default gate |
| Claude Code Security Review | **F** | — | ✓ | ✓ | ✓ | ✓ (collector) | no | n/a | AI/MANUAL | non-deterministic; **non-gating** |
| Kuzushi | **F** | — | ✓ | ✓ | ✓ | ✓ (collector) | no | n/a | AI/MANUAL | assistive; non-gating |
| dependency_policy_violations | **E** | — | — (reserved) | — | ✓ (key) | gate-tested | no | n/a | MAIN | no default emitter; wire a policy tool |

## Honest summary
- **Proven-live (A): the original core** (gitleaks, app-Semgrep, PHPStan, PHPUnit, composer audit, Hadolint, base-digest, GH-pins, Trivy-fs) — validated on the zenchron-tools pilot — **plus this repo's own ci-self-test**.
- **Everything added in v0.1.12 is B/C/D/F**: collector + deterministic self-test fixture, but **not yet live-validated** against a real consumer. The Sentinel Shield *integration* (collector → key → gate) is tested; the *scanner binary execution* and severity fidelity are not.
- **DAST (ZAP/Nuclei) and AI review are not production gates** — manual/allowlisted and non-deterministic respectively.
- **No tool's scanner binary is bundled.** Image/action digests must be pinned by the consumer before production (see [pinned-tool-references.md](pinned-tool-references.md)).

**Sentinel Shield is production-ready as a release-gate ENGINE** (resolver/enforcer/builder/install/sync/self-test are A-grade, fixture- and self-gated). **It is NOT a turnkey "all 30 scanners proven" product** — most scanner integrations are supported/experimental and require a live consumer run + digest pinning to promote to proven.
