# Sentinel Shield — Documentation Hub

> The canonical map of Sentinel Shield's docs. If a new team can't adopt from here without asking the
> author, that's a bug — open an issue. Maturity labels defer to the single source of truth,
> [`product-status.md`](product-status.md). Stability/compatibility is in [`product-contract.md`](product-contract.md).

## Start here

| You want to… | Read |
|---|---|
| **Install & run in <30 min** | [`quickstart.md`](quickstart.md) |
| **Understand what Sentinel Shield is / isn't** | [`product-status.md`](product-status.md) §1–§2, [`product-contract.md`](product-contract.md) |
| **Roll out across real projects** | [`production-rollout.md`](production-rollout.md) |
| **Harden for enterprise/production** | [`enterprise-hardening.md`](enterprise-hardening.md) |
| **Debug a failure** | [`troubleshooting.md`](troubleshooting.md) · [`faq.md`](faq.md) |

## Which guide should I read? (by role)

- **New adopter** → [`quickstart.md`](quickstart.md) → [`consumer-onboarding.md`](consumer-onboarding.md) → [`gate-resolution.md`](gate-resolution.md) → [`accepted-risk-suppression.md`](accepted-risk-suppression.md).
- **Production adopter / platform lead** → [`production-rollout.md`](production-rollout.md) → [`multi-project-rollout.md`](multi-project-rollout.md) → [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md) → [`install-sync-guide.md`](install-sync-guide.md).
- **Security engineer** → [`strict-mode-readiness.md`](strict-mode-readiness.md) → [`severity-policy.md`](severity-policy.md) → [`accepted-risk-suppression.md`](accepted-risk-suppression.md) → [`exception-policy.md`](exception-policy.md) → [`dependency-check-runbook.md`](dependency-check-runbook.md).
- **Platform/DevSecOps engineer** → [`enterprise-hardening.md`](enterprise-hardening.md) → [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) → [`github-actions-security.md`](github-actions-security.md) → [`security-hygiene.md`](security-hygiene.md).
- **Maintainer (of Sentinel Shield itself)** → [`product-contract.md`](product-contract.md) → [`raw-report-contract.md`](raw-report-contract.md) → [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md) → [`roadmap.md`](roadmap.md).
- **Auditor / compliance reviewer** → [`main-gate-live-evidence.md`](main-gate-live-evidence.md) → [`v1-readiness.md`](v1-readiness.md) → [`product-readiness-checklist.md`](product-readiness-checklist.md) → [`production-readiness-audit.md`](production-readiness-audit.md).

## Canonical docs by topic

Tag legend: **[stable]** depend on it · **[advanced]** opt-in/enterprise · **[reference]** lookup ·
**[experimental]** not yet promoted · **[evidence]** an audit-trail / cited-run record.

### Getting started & adoption
- [`quickstart.md`](quickstart.md) — install & first run **[stable]**
- [`consumer-onboarding.md`](consumer-onboarding.md) — onboarding a consuming project **[stable]**
- [`production-rollout.md`](production-rollout.md) — pilot → staged → default, ownership model **[stable]**
- [`multi-project-rollout.md`](multi-project-rollout.md) — many consumers, one pinned ref **[stable]**
- [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md) — drop-in upgrade + "what v1.x does NOT mean" **[stable]**
- [`install-sync-guide.md`](install-sync-guide.md) / [`install-sync-quickstart.md`](install-sync-quickstart.md) — install/sync model **[stable]**

### Modes, gates & governance
- [`gate-resolution.md`](gate-resolution.md) — mode → gate flags → enforce **[stable]**
- [`severity-policy.md`](severity-policy.md) — severity → gate mapping **[stable]**
- [`strict-mode-readiness.md`](strict-mode-readiness.md) — strict opt-in pre-flight **[stable]**
- [`regulated-mode-readiness.md`](regulated-mode-readiness.md) — regulated (not default) **[advanced]**
- [`accepted-risk-suppression.md`](accepted-risk-suppression.md) / [`exception-policy.md`](exception-policy.md) — the only legitimate suppression path **[stable]**
- [`raw-report-contract.md`](raw-report-contract.md) — collector I/O contract **[reference]**

### Scanners, evidence & runbooks
- [`dependency-check-runbook.md`](dependency-check-runbook.md) — DC operation **[reference]**
- [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md) — committed vs transitive, cache/H2 **[reference]**
- [`main-gate-live-evidence.md`](main-gate-live-evidence.md) — cited live-validation runs **[evidence]**
- [`deptrac-evidence-guide.md`](deptrac-evidence-guide.md) — Deptrac promotion readiness **[experimental]**
- [`iac-evidence-guide.md`](iac-evidence-guide.md) — Checkov/Conftest/Terrascan readiness **[experimental]**
- [`iac-local-evidence-v140.md`](iac-local-evidence-v140.md) — real local IaC tool runs; diagnoses v1.3.0 blockers **[evidence]**
- [`iac-evidence-candidate-matrix.md`](iac-evidence-candidate-matrix.md) — scanner/surface suitability for the next promotion **[experimental]**
- [`deptrac-iac-promotion-plan.md`](deptrac-iac-promotion-plan.md) — promotion criteria **[experimental]**
- [`install-sync-scale-v140.md`](install-sync-scale-v140.md) — 8-profile install/sync re-validation **[evidence]**

### Enterprise / hardening
- [`enterprise-hardening.md`](enterprise-hardening.md) — hardened usage (opt-in) **[advanced]**
- [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) — tags → digests **[advanced]**
- [`security-hygiene.md`](security-hygiene.md) — secrets, NVD key rotation, retention **[stable]**
- [`github-actions-security.md`](github-actions-security.md) — Actions pinning/permissions **[advanced]**

### Contract, status & process
- [`product-contract.md`](product-contract.md) — STABLE surfaces + semver **[stable]**
- [`product-status.md`](product-status.md) — canonical maturity (source of truth) **[reference]**
- [`v1-readiness.md`](v1-readiness.md) — blocker table / release readiness **[reference]**
- [`roadmap.md`](roadmap.md) — maturity-ordered plan **[reference]**
- [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md) — tags, immutability **[reference]**
- [`sprint-v140-report.md`](sprint-v140-report.md) — v1.4.0 20-lane/800-task sprint ledger **[evidence]**

### Support
- [`troubleshooting.md`](troubleshooting.md) — symptom → cause → fix **[reference]**
- [`faq.md`](faq.md) — frequent questions **[reference]**

> **Audit-trail docs** (e.g. `*-v0.1.x.md`, `clean-strict-ci-evidence-v029.md`, `strict-ci-and-install-sync-evidence-v028.md`)
> record what was true at a point in time. They are an honest history, **not** current adoption docs —
> start from the canonical docs above and follow citations into the trail when you need the proof.
