# CI Runtime Budget (v0.1.13)

Keep Sentinel Shield fast enough to use. Tool placement by gate maps directly to the workflow
templates (templates/workflows/sentinel-shield-{pr-fast,main,scheduled,dast}.yml).

| Gate | Target wall-clock | Runs on | Scanners |
|---|---|---|---|
| **PR fast** | **< 10–15 min** | every PR | php -l, PHPStan, Psalm, Pint/PHP-CS-Fixer, ESLint, tsc --noEmit, Semgrep(app), Gitleaks, composer audit, npm audit, actionlint, zizmor, GH-pin audit, base-digest, Hadolint, unit/feature tests |
| **Main** | **< 20–30 min** | push to main/master | CodeQL, OSV-Scanner, Trivy fs, OWASP Dependency-Check, Grype, Deptrac, architecture tests, Syft SBOM, Checkov/Conftest/Terrascan (if IaC) |
| **Nightly** | heavier (no PR impact) | schedule | Trivy image, Grype SBOM, OpenSSF Scorecard, TruffleHog deep, Dockle, optional ZAP baseline / Nuclei on staging |
| **Manual DAST** | explicit only | workflow_dispatch | ZAP baseline/full, Nuclei (target+allowlist; fail-closed) |
| **AI review** | explicit/opt-in | dispatch or label | Claude Code Security Review, Kuzushi (assistive, non-gating) |

## Why this split
- **Deterministic + fast → PR.** Anything that needs network DBs, image builds, or minutes of
  analysis (CodeQL, Dependency-Check, image scans) moves to **main** or **nightly** so PRs stay
  under ~15 min.
- **Heavy/slow → nightly**, report-only; triage into PR/main gates or accepted-risks.
- **Target-scanning (DAST) → manual only**, never on the PR path.
- **Non-deterministic (AI) → opt-in, non-gating.**

If a PR-fast tool routinely exceeds budget, demote it to main or cache aggressively. Do not let
the PR gate creep past ~15 min — slow gates get bypassed.

## v0.1.19 — main-gate execution hardening
Grype (SBOM-first/fs/container), Dependency-Check (disabled-default; nightly), Dockle (image-gated)
have hardened execution paths + env vars, but are **NOT promoted** (no live consumer artifact).
Semgrep 1.165.0 fixture-verified (0 parser errors), not consumer-verified. See
[`main-gate-execution-hardening-v0.1.19.md`](main-gate-execution-hardening-v0.1.19.md) and
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). DAST/Nuclei/AI unchanged (manual/non-gating).
