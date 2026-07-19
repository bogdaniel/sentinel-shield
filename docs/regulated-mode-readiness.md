# Regulated-Mode Readiness

> **Purpose.** Regulated mode is the compliance-heavy tier: it makes **release evidence
> and SBOM mandatory** and turns on the repo-health and DAST gates that strict leaves
> advisory. This guide defines what must be **true before you flip a project to
> `gates.mode: regulated`**, names the gates that remain too immature to trust as silent
> blockers, and gives a concrete pre-flight checklist.
>
> **Regulated requires everything strict requires, PLUS the items in §2.** Read
> [`strict-mode-readiness.md`](strict-mode-readiness.md) first.
>
> **Source of truth.** Maturity claims follow [`product-status.md`](product-status.md)
> (canonical; it wins on any disagreement). Gate→key mappings from
> [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md); severity→gate from
> [`severity-policy.md`](severity-policy.md); governance from
> [`accepted-risk-suppression.md`](accepted-risk-suppression.md) and
> [`exception-policy.md`](exception-policy.md); DAST from
> [`dast-policy.md`](dast-policy.md); AI review from
> [`ai-review-policy.md`](ai-review-policy.md).
>
> **Not a v1.0 claim.** Sentinel Shield is production-ready as a release-gate **engine**,
> not a turnkey all-scanners-proven product. Several integrations are
> `experimental`/`manual` and must run advisory before they block — even in regulated.

---

## 1. What regulated mode adds over strict

Regulated is computed by [`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh)
(`default_for "regulated"`): **every gate blocks except `ai_review_findings`.** Relative
to `strict`, regulated **promotes these from advisory to hard blockers**:

- `missing_release_evidence` — release/audit evidence becomes **mandatory**.
- `third_party_suspicious_code`, `third_party_obfuscation` — the noisier third-party
  supply-chain signals now block (in addition to the two strict already blocks).
- `dast_findings` — DAST (OWASP ZAP / Nuclei) findings gate **only here, only if a target
  + allowlist + approval are configured** ([`dast-policy.md`](dast-policy.md)).
- `repository_health_warnings` — OpenSSF Scorecard / repo-health gates here (`✗/✗/✓`).

Regulated also completes the **engineering-quality gates (v2.1)** — an unreleased, additive engine
capability (**not** part of `v2.0.1`/`v2.0.0`, **not** a new release claim; latest release remains
`v2.0.1`). On top of the four quality gates strict already blocks (coverage threshold, coverage
regression, complexity, duplication), regulated **additionally enables** `mutation_score_violations`
and `dead_code_violations` — so all six quality gates block in regulated, in a **separate counter
channel** from security. These are **not** accepted-risk-suppressible. See
[`engineering-quality-gates.md`](engineering-quality-gates.md).

Regulated also completes **Architecture Governance v2 (v2.1)** — an unreleased, additive engine
capability (**not** part of `v2.0.1`/`v2.0.0`, **not** a new release claim; latest release remains
`v2.0.1`). Sentinel Shield enforces architecture governance through normalized architecture evidence.
Deptrac is the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are JS/TS
producers. Custom architecture tests can also emit the same contract. Regulated keeps the strict
behavior — `architecture_violations` (summed across all producers) and `missing_architecture_evidence`
both block, so absent/unavailable/errored expected evidence fails — and **adds one requirement**: the
raw architecture evidence artifacts (`reports/raw/*.json` from each producer) must be **retained** with
the release evidence. See [`architecture-governance.md`](architecture-governance.md).

> **Evidence honesty.** Architecture governance is supported by engine tests and fixtures. Do not
> claim real consumer proof until a real Laravel/Symfony/Node consumer validation exists. Architecture
> tools detect dependency-boundary violations, not the quality of domain modeling itself.

Regulated **still keeps `ai_review_findings` NON-gating** — AI review never blocks by
default in any mode unless the profile explicitly sets
`gates.fail_on.ai_review_findings: true` ([`ai-review-policy.md`](ai-review-policy.md)).

---

## 2. Preconditions — everything strict requires, PLUS

Start from the [strict pre-flight checklist](strict-mode-readiness.md#5-pre-flight-checklist-strict).
Then add:

1. **DAST configured correctly, or accepted as inert.** Because `dast_findings` blocks in
   regulated, you must either (a) configure DAST safely, or (b) confirm it stays skipped.
   Per [`dast-policy.md`](dast-policy.md), the guard enforces:
   - **Target + allowlist required.** `SENTINEL_SHIELD_DAST_TARGET_URL` and
     `SENTINEL_SHIELD_DAST_ALLOWED_HOST` must be set; host mismatch **fails closed**.
   - **Written approval** via [`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md)
     (and the Nuclei allowlist template). ZAP **full** is active/intrusive — separate
     approval, staging only. Never scan production without written approval.
   - No target → the runner SKIPS (exit 0), so the gate is inert by design until you opt in.
2. **OpenSSF Scorecard / repo-health gating is acceptable.** `repository_health_warnings`
   blocks here. Scorecard is `experimental` and needs a repo token in CI. Decide that
   repo-health *should* gate releases for this project, and run it **advisory first** to
   review real findings before letting it block (§3).
3. **Audit-evidence retention is in place.** `missing_release_evidence` and `missing_sbom`
   are mandatory in regulated. Ensure the gated pipeline produces and **retains** the SBOM
   (Syft), the resolved-gates artifacts, the `security-summary.json`, and the release
   evidence per your compliance retention period. **This includes the raw architecture evidence
   artifacts** — the `reports/raw/*.json` emitted by each architecture producer (Deptrac, PHPArkitect,
   dependency-cruiser, ESLint boundaries, custom architecture tests). See
   [`raw-report-contract.md`](raw-report-contract.md),
   [`security-summary-schema.md`](security-summary-schema.md) and
   [`architecture-governance.md`](architecture-governance.md).
4. **AI review stays non-gating unless explicitly enabled.** Keep
   `ai_review_findings: false` (the default). Only set it `true` deliberately for
   high-assurance flows, knowing AI output is non-deterministic and can hallucinate
   ([`ai-review-policy.md`](ai-review-policy.md)).
5. **Accepted-risk governance with expiry and approval authority.** In regulated, severity
   downgrades must be approved and recorded as exceptions
   ([`severity-policy.md`](severity-policy.md) §Assigning severity). Every accepted risk
   needs an owner, reason, mitigation, **expiry**, review date, and an approver whose role
   matches the severity ([`exception-policy.md`](exception-policy.md)). `expired_exceptions`
   blocks, so lapsed risks fail the build automatically.

---

## 3. Gates too immature to trust as hard blockers by default

Regulated turns *everything* (except AI) on by default — which means the
coarse/experimental and manual tools below become blockers. Per
[`product-status.md`](product-status.md) and
[`production-readiness-audit.md`](production-readiness-audit.md), **run these advisory
first, review real output, then tighten:**

| Gate / tool | Summary key | Maturity (canonical) | Why advisory first |
| --- | --- | --- | --- |
| OSV-Scanner | `high_vulnerabilities` | `experimental` — coarse severity | All OSV vulns counted `high` unless normalized. |
| CodeQL | `high/medium_vulnerabilities` | `experimental` — coarse severity | SARIF `level→severity`, not CVSS. |
| OWASP Dependency-Check | `*_vulnerabilities` | `experimental` — **attempted, NOT live-validated** | No real artifact; cold NVD exceeds CI budget. Run **nightly** with warm cache, advisory, before gating. |
| Checkov / Conftest / Terrascan | `iac_violations` | `experimental` — **only if configured** | No consumer with IaC validated; meaningful only with IaC. |
| Deptrac | `architecture_violations` | `supported` — not live-validated | Live-validate on a consumer with `deptrac.yaml`. |
| Architecture evidence (Deptrac / PHPArkitect / dependency-cruiser / ESLint boundaries / custom architecture tests) | `missing_architecture_evidence` | v2.1 unreleased — engine-tested + fixture-tested, **no real consumer validation** | Absent/unavailable/errored evidence blocks here, and the raw reports must be retained. Wire producers in report-only/baseline, tighten through strict, then regulate. |
| OpenSSF Scorecard | `repository_health_warnings` | `experimental` — regulated-only gate | Needs repo token; review real warnings before blocking. |
| Trivy (image) | `*_vulnerabilities` | `experimental`/nightly | Needs an image ref; nightly home. |
| TruffleHog | `secrets` | `experimental`/nightly | Verified-only count; live-validate. |
| Third-party Semgrep signals | `third_party_*` | `supported`/`experimental` | `suspicious_code`/`obfuscation` are the noisier signals regulated newly blocks — triage-tune first. |
| DAST (ZAP / Nuclei) | `dast_findings` | `manual` — never validated end-to-end | Manual + allowlisted + approved. Gate only after a controlled staging run; **fail-closed** by design. |
| AI review (Claude Code Security Review / Kuzushi) | `ai_review_findings` | `non-gating` | Non-deterministic; stays non-gating unless explicitly enabled. |

**Promotion rule.** A tool is "trusted to block" only after a **real cited consumer run**
(raw report + reviewed severity) recorded in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). Live-validated so far: CodeQL,
OSV-Scanner, Trivy-fs, Syft SBOM, Grype, Dockle, plus consumer-verified Semgrep 1.165.0.

---

## 4. Pre-flight checklist (regulated)

Complete the [strict checklist](strict-mode-readiness.md#5-pre-flight-checklist-strict)
first, then tick every box below before setting `gates.mode: regulated`:

- [ ] All strict preconditions satisfied and the project has run strict cleanly.
- [ ] DAST decision made: either configured with **target + allowlist + written approval**
      (staging, fail-closed verified), or confirmed inert (no target → skips).
- [ ] Nuclei (if used) has a completed target allowlist template.
- [ ] OpenSSF Scorecard / repo-health run **advisory first**, real warnings reviewed, then accepted as a gate.
- [ ] `missing_release_evidence` satisfied: release evidence produced and **retained** per compliance retention.
- [ ] `missing_sbom` satisfied: SBOM (Syft) produced and retained.
- [ ] Audit-evidence retention configured (SBOM, resolved gates, `security-summary.json`, evidence).
- [ ] `missing_architecture_evidence` satisfied: every applicable architecture producer emits evidence,
      or the project opts out honestly in `.sentinel-shield/architecture-policy.yaml`.
- [ ] Raw architecture reports (`reports/raw/*.json` per producer) **retained** with the release evidence.
- [ ] Third-party signals (`suspicious_code`, `obfuscation`) triaged; new regulated blockers clean or accept-risked.
- [ ] Coarse-severity tools (OSV/CodeQL/Grype/Dependency-Check) reviewed against real output before trusting.
- [ ] OWASP Dependency-Check, if used, runs **nightly with a warm NVD cache** — advisory until live-validated.
- [ ] AI review left **non-gating** (`ai_review_findings: false`) unless a documented decision enables it.
- [ ] Accepted-risk governance enforced: every risk owner-bound, approved at the right role, with expiry + review date.
- [ ] `expired_exceptions` clean (no lapsed accepted risks).
- [ ] All tool images/actions pinned to digests/SHAs
      ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).

When every box is ticked, set `gates.mode: regulated` and re-run
[`resolve-gates.sh`](../scripts/resolve-gates.sh) to confirm the resolved `fail_on` matrix
(all `true` except `ai_review_findings`). Tighten advisory→blocking incrementally as each
experimental/manual tool earns a cited live run.

## Testing Discipline Governance (v2.2.0)

Sentinel Shield enforces test-first discipline through evidence:
production-change-without-test-change detection, changed-line coverage, missing/empty test
evidence, mutation testing, focused-test guards, BDD specification evidence, and ATDD
acceptance-test evidence.

Sentinel Shield does **not** claim that it proves true TDD, that it guarantees BDD quality,
that it replaces product-owner acceptance, or that it understands business intent
automatically. TDD cannot be proven from final code — it is a workflow, and a final snapshot
does not record the order its lines were written.

BDD/ATDD evidence is only required when configured or when an app profile enables it in
strict/regulated mode. Libraries are not forced to carry BDD/ATDD by default.

Full reference: [`testing-discipline-governance.md`](testing-discipline-governance.md).
