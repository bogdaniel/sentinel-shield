# Sentinel Shield Documentation Index

A new team should be able to understand Sentinel Shield from this page without reading files at
random. Docs are grouped by purpose. **Start with the four product docs**, then go to the area you
need.

## Start here
- [`product-status.md`](product-status.md) — **canonical maturity** (what is proven vs not). Read first.
- [`product-boundaries.md`](product-boundaries.md) — what the product owns vs what a project owns.
- [`../README.md`](../README.md) — top-level overview, quick start, engine walkthrough.
- [`../SECURITY-STANDARD.md`](../SECURITY-STANDARD.md) — the secure-coding / operational standard.
- [`../RELEASE-GATES.md`](../RELEASE-GATES.md) — when a release is allowed to ship.

## Adoption
- [`profile-driven-adoption.md`](profile-driven-adoption.md) — one-command install/sync model.
- [`install-sync-status.md`](install-sync-status.md) — per-stack install/sync coverage + gaps.
- [`adoption-guide.md`](adoption-guide.md) — the five-phase report-only → regulated migration.
- [`project-readiness-checklist.md`](project-readiness-checklist.md) — per-project go-live checklist.
- [`pilot-consumers.md`](pilot-consumers.md) — zenchron-tools as pilot evidence (not a product target).

## Release gates (engine)
- [`gate-resolution.md`](gate-resolution.md) — resolver: mode → fail-on flags.
- [`security-summary-schema.md`](security-summary-schema.md) — the `security-summary.json` contract.
- [`raw-report-contract.md`](raw-report-contract.md) — raw report → collector → summary.
- [`scanner-normalization.md`](scanner-normalization.md) / [`node-react-normalization.md`](node-react-normalization.md) — severity mappings.
- [`severity-policy.md`](severity-policy.md) — how severity is decided.

## Scanner matrix
- [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md) — every tool, gate category, summary key.
- [`production-readiness-audit.md`](production-readiness-audit.md) — per-tool A–F readiness grades.
- [`main-gate-validation-strategy.md`](main-gate-validation-strategy.md) — branch-safe main-gate
  validation via `run-main-gate-validation.sh` (solves the `workflow_dispatch` blocker).
- [`tooling/scanner-enablement.md`](tooling/scanner-enablement.md) — which tools per stack + how to enable.
- [`workflow-template-inventory.md`](workflow-template-inventory.md) — the six workflow templates.
- [`semgrep-scoping.md`](semgrep-scoping.md) — SAST scope; curated rules, never `--config=auto`.
- [`third-party-supply-chain-scan.md`](third-party-supply-chain-scan.md) — supply-chain channel.

## Profiles
- [`../profiles/`](../profiles/) — per-stack tool configs + `profile.manifest.json` files.
- [`static-analysis-policy.md`](static-analysis-policy.md), [`style-policy.md`](style-policy.md),
  [`architecture-policy.md`](architecture-policy.md), [`dependency-policy.md`](dependency-policy.md).
- [`architecture-governance.md`](architecture-governance.md) — normalized architecture evidence
  across PHP and JS/TS producers (Deptrac, PHPArkitect, dependency-cruiser, ESLint boundaries,
  custom architecture tests), the `missing_architecture_evidence` gate, and the policy file.

## Accepted risks
- [`accepted-risk-suppression.md`](accepted-risk-suppression.md) — finding-scoped suppression rules.
- [`exception-policy.md`](exception-policy.md) — formal exception requirements.

## Runners / collectors
- [`consolidation-v0.1.9.md`](consolidation-v0.1.9.md) — what was upstreamed from the pilot.
- [`../scripts/runners/`](../scripts/runners/), [`../scripts/adapters/`](../scripts/adapters/),
  [`../scripts/audits/`](../scripts/audits/), [`../scripts/collectors/`](../scripts/collectors/).

## DAST / manual scans
- [`dast-policy.md`](dast-policy.md) — manual, allowlisted, fail-closed.
- [`scheduled-scans.md`](scheduled-scans.md) — nightly deep scans.

## AI review
- [`ai-review-policy.md`](ai-review-policy.md) — assistive, non-gating doctrine.

## Governance
- [`architecture-boundaries.md`](architecture-boundaries.md), [`secure-coding-standard.md`](secure-coding-standard.md),
  [`docker-security-standard.md`](docker-security-standard.md), [`github-actions-security.md`](github-actions-security.md),
  [`iac-security-policy.md`](iac-security-policy.md).
- [`remediation/`](remediation/) — generic remediation guides.

## Production readiness
- [`product-readiness-checklist.md`](product-readiness-checklist.md) — product-level readiness status.
- [`pinned-tool-references.md`](pinned-tool-references.md) — pin actions/images before production.
- [`ci-runtime-budget.md`](ci-runtime-budget.md) — PR-fast vs main vs nightly runtime split.
- [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md) — how to cut a release.
- [`workflow-template-validation.md`](workflow-template-validation.md) — self-test of the templates.

## Roadmap
- [`roadmap.md`](roadmap.md) — maturity-phased roadmap (Phase 3 live-validation is the frontier).

---

**Version notes** (newest first): `feature-completion-v0.1.14.md`, `consolidation-v0.1.9.md`. The
authoritative status is always [`product-status.md`](product-status.md).
</content>
