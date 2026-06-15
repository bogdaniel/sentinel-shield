# Strict-Mode Readiness

> **Purpose.** Strict mode turns Sentinel Shield from a migration aid into a production
> release requirement. This guide defines what must be **true before you flip a project
> to `gates.mode: strict`**, names the gates that are too immature to trust as hard
> blockers by default, and gives a concrete pre-flight checklist.
>
> **Source of truth.** Maturity claims here follow
> [`product-status.md`](product-status.md) (canonical). Where any statement disagrees with
> product-status, product-status wins. Gate-category and summary-key mappings come from
> [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md); severity→gate mapping
> from [`severity-policy.md`](severity-policy.md); accepted-risk governance from
> [`accepted-risk-suppression.md`](accepted-risk-suppression.md) and
> [`exception-policy.md`](exception-policy.md).
>
> **Not a v1.0 claim.** Sentinel Shield is production-ready as a release-gate **engine**
> (resolver/enforcer/summary-builder/install/sync/self-test are self-gated). It is **not**
> a turnkey "all scanners proven" product. Several scanner integrations are
> `supported`/`experimental` and should run advisory before you let them block.

---

## 1. What strict mode actually gates

Strict is computed by [`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh)
(`default_for "strict"`). Relative to `baseline`, strict **adds these as hard blockers**:

- `medium_vulnerabilities` — medium-severity findings now block (per
  [`severity-policy.md`](severity-policy.md): Medium blocks in strict/regulated).
- `missing_sbom` — an SBOM (Syft) must be present.
- `style_violations` — Pint / PHP-CS-Fixer / PHPCS style gate (`✗/✓/✓`).
- `iac_violations` — Checkov / Conftest / Terrascan (**only meaningful if the project
  has IaC**; otherwise the runners report `unavailable` — no fake clean).
- `container_image_violations` — Dockle (requires a built image).
- `third_party_install_script_risk`, `third_party_network_behavior` — the
  higher-confidence third-party supply-chain signals.

Strict **keeps these NON-blocking** (resolver returns `false`):

- `missing_release_evidence` — regulated-only by default.
- `third_party_suspicious_code`, `third_party_obfuscation` — the noisier third-party
  signals stay advisory until regulated.
- `dast_findings` — DAST is manual/regulated-only.
- `repository_health_warnings` — OpenSSF Scorecard is regulated-only.
- `ai_review_findings` — AI review is **never gating by default**, in any mode.

Everything already blocking in `baseline` stays blocking: `secrets`,
`critical_vulnerabilities`, `high_vulnerabilities`, `architecture_violations`,
`type_errors`, `test_failures`, `unsafe_docker`, `unsafe_github_actions`,
`php_syntax_errors`, `dependency_policy_violations`, `expired_exceptions`.

---

## 2. Preconditions — what must be TRUE before enabling strict

1. **Baseline is green and stable.** The project has been running `baseline` long enough
   that the PR-fast gate (`sentinel-shield-pr-fast.yml`, `proven`) passes consistently and
   no new critical/high is entering. Do not jump from `report-only` straight to strict.
2. **The new strict blockers are clean (or accept-risked).** `medium_vulnerabilities`,
   `style_violations`, and (if applicable) `iac_violations` / `container_image_violations`
   must either be zero or covered by an approved, unexpired accepted-risk record — **not**
   silently suppressed. See §4.
3. **Style/type gates are actually configured.** `style_violations` only means something
   if the project runs Pint / PHP-CS-Fixer / PHPCS (or the JS equivalent) and `type_errors`
   if PHPStan/Larastan/Psalm/`tsc --noEmit` is wired. If a gate has no emitter for your
   stack, decide deliberately rather than discovering it at release time.
4. **IaC gates are meaningful only if you have IaC.** Checkov/Conftest/Terrascan
   (`iac_violations`) are `experimental` and have **no consumer with IaC live-validated**.
   If the project has no Terraform/K8s/Dockerfile policy surface, these runners correctly
   report `unavailable`; if it does, run them advisory first (§3).
5. **Container-image gate has a built image.** `container_image_violations` (Dockle)
   requires a built image in CI. If you do not build an image in the gated pipeline, this
   gate is inert — confirm that is intentional.
6. **Main-gate scanners are live-validated OR explicitly accepted as advisory.** Per
   product-status, the live-validated main-gate set is **CodeQL, OSV-Scanner, Trivy-fs,
   Syft SBOM** (run 27214865086) plus **Grype** and **Dockle** (run 27239206382), and
   **Semgrep 1.165.0** is consumer-verified. Anything not on that list (see §3) should run
   advisory until you have a cited consumer run.
7. **Tool images/actions are pinned.** No tool image/action is digest-pinned by default;
   the consumer must pin before production
   ([`pinned-tool-references.md`](pinned-tool-references.md),
   [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).
8. **No real, unresolved finding is being suppressed to pass.** Suppression is only
   legitimate through the accepted-risk path (owner + reason + expiry). A scanner
   suppression without an exception record is itself a finding
   ([`exception-policy.md`](exception-policy.md)). `secrets` is never suppressible.

---

## 3. Gates too immature to trust as hard blockers by default

Per [`product-status.md`](product-status.md) and
[`production-readiness-audit.md`](production-readiness-audit.md), the following are **not**
yet trustworthy enough to be silent strict blockers on day one. **Run them advisory first,
review their real output, then tighten** (set the gate to block once you trust the
severity for your project).

| Gate / tool | Summary key | Maturity (canonical) | Why advisory first |
| --- | --- | --- | --- |
| OSV-Scanner | `high_vulnerabilities` | `experimental` (live-validated run, **coarse severity**) | Counts all OSV vulns as `high` unless normalized; tune per project. |
| CodeQL | `high/medium_vulnerabilities` | `experimental` (live-validated run, **coarse severity**) | SARIF `level→severity` (error→high, warning→medium), not CVSS. |
| Grype | `*_vulnerabilities` | `proven` (run 27239206382) but severity best-effort | Live-validated; still confirm severity mapping on your deps. |
| OWASP Dependency-Check | `*_vulnerabilities` | **`live-validated`** (local v0.1.27, 9,289 deps; CI v0.1.30 + transitive run 27573703800, 9,179 deps) — **coarse severity** | Live-validated locally + in CI with the NVD key. Severity mapping is best-effort (npm `moderate`→medium); confirm thresholds on real findings before gating. |
| Dockle (`container_image_violations`) | `container_image_violations` | `proven` (run 27239206382) | Live-validated; needs a built image — inert if you don't build one. |
| Checkov / Conftest / Terrascan (`iac_violations`) | `iac_violations` | `experimental` — **only if configured** | No consumer with IaC validated; only meaningful if you have IaC. |
| Deptrac (`architecture_violations`) | `architecture_violations` | `supported` — not live-validated | Live-validate on a consumer that ships a `deptrac.yaml`. |
| Trivy (image), TruffleHog, OpenSSF Scorecard | various | `experimental` / nightly | Nightly/coarse; not strict blockers. |
| DAST (ZAP/Nuclei) | `dast_findings` | `manual` | Manual + allowlisted; regulated-only. Never a strict gate. |
| AI review (Claude Code Security Review / Kuzushi) | `ai_review_findings` | `non-gating` | Non-deterministic; never blocks by default, any mode. |

**Promotion rule.** A main-gate tool is "trusted to block" only after a **real cited
consumer run** (raw report + reviewed severity) is recorded in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). The harness running a tool is
not sufficient.

---

## 4. Accepted-risk governance under strict

- Use [`accepted-risk-suppression.md`](accepted-risk-suppression.md) /
  [`exception-policy.md`](exception-policy.md). A Markdown draft does nothing; only an
  **approved, unexpired, owner-bound JSON record** suppresses, and only for a suppressible
  gate. The raw count is preserved and the suppression is reported.
- Finding-scoped suppression is implemented for `unsafe_docker` only; other count gates
  support broad `scope: gate` suppression (reported as broad).
- Every accepted risk needs an **expiry** and a **review date**; `expired_exceptions`
  blocks in every mode, so lapsed risks fail the build by design.
- `secrets` is never suppressible.

---

## 5. Pre-flight checklist (strict)

Tick every box before setting `gates.mode: strict`:

- [ ] Project ran `baseline` and the PR-fast gate is consistently green.
- [ ] `critical_vulnerabilities` / `high_vulnerabilities` = 0 (or accept-risked, unexpired).
- [ ] `medium_vulnerabilities` reviewed: zero, or each medium accept-risked with expiry.
- [ ] `style_violations` gate configured (Pint/PHP-CS-Fixer/PHPCS or JS equivalent) and clean/accept-risked.
- [ ] `type_errors` gate configured (PHPStan/Larastan/Psalm/`tsc --noEmit`) and green.
- [ ] `architecture_violations` (Deptrac) configured if the project asserts boundaries.
- [ ] IaC decision made: either no IaC (gate inert, intentional) or Checkov/Conftest/Terrascan run **advisory** first.
- [ ] Container-image decision made: image built in CI for Dockle, or `container_image_violations` confirmed inert.
- [ ] `missing_sbom` satisfied (Syft SBOM produced in the gated pipeline).
- [ ] Main-gate scanners not on the live-validated list are set to **advisory**, not hard-block.
- [ ] Coarse-severity tools (OSV/CodeQL/Grype/Dependency-Check) reviewed against real output before trusting.
- [ ] All tool images/actions pinned to digests/SHAs.
- [ ] No real finding is being suppressed without an approved, unexpired accepted-risk record.
- [ ] `expired_exceptions` is clean (no lapsed accepted risks).

When all of the above hold, set `gates.mode: strict` in `.sentinel-shield/profile.yaml`
and re-run `resolve-gates.sh` to confirm the resolved `fail_on` matrix. Tighten
advisory→blocking incrementally as each tool earns trust.

For the next tier (DAST configured, repo-health gating, audit-evidence retention), see
[`regulated-mode-readiness.md`](regulated-mode-readiness.md).
