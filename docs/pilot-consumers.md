# Pilot Consumers (v0.1.16)

Sentinel Shield is the product. Consuming projects are **evidence sources** — they prove (or
fail to prove) that an integration works in real CI. They are **not** product targets, and their
application findings are not Sentinel Shield's backlog.

## Pilot consumer: `bogdaniel/zenchron-tools`

- **Purpose:** validate Sentinel Shield in a real Laravel / React / Docker CI pipeline.
- **Not the purpose:** make zenchron-tools production-ready. Its own application findings are the
  project's concern, addressed only when they directly prove a Sentinel Shield bug.
- **Status:** a Laravel/React/Docker repository, not yet live, used as the first adoption pilot.

### Key evidence run

- Consumer: `bogdaniel/zenchron-tools`
- Workflow: `sentinel-shield-pr-fast-validation.yml`
- Run: **27170148123** (baseline run **27170126445**, PASS — no regression)

## What zenchron-tools proved (`proven`)

These integrations ran green (or produced real, cited findings) in the pilot CI:

- **Baseline gate** (resolver → enforcer, mode enforcement, PASS with no regression)
- **PHPStan/Larastan runner** (`scripts/runners/laravel-phpstan.sh`)
- **Test adapters** (PHPUnit → `tests.json`)
- **Hadolint** multi-Dockerfile discovery (`run-hadolint.sh`)
- **Finding-scoped accepted risks** (`unsafe_docker`)
- **GitHub Actions pin audit** (`audit-github-actions-pins.sh`)
- **Docker base-image digest detector** (`audit-docker-base-digest.sh`)
- **dependency-policy** lockfile detector (`dependency_policy_violations`=0, detector ran)
- **TypeScript** `--noEmit` (`type_errors`=0)
- **php-style** Pint/PHP-CS-Fixer (`style_violations`=88 — real findings)
- **Curated Semgrep default** (0 critical / 0 high vs `--config=auto`'s 7/16; **never `--config=auto`**)
- Core scanners: Gitleaks, composer audit, php-syntax (`php -l`), Trivy-fs.

## What zenchron-tools did NOT prove

Not exercised by the pilot — these remain `supported` / `experimental` / `template-only` /
`manual` / `non-gating` (see [`product-status.md`](product-status.md)):

- **Main-gate scanners** — `sentinel-shield-main.yml` is `workflow_dispatch`-only and was not
  dispatchable from a feature branch before merge.
- **DAST** (OWASP ZAP baseline/full) — manual, needs target + allowlist.
- **AI review** (Claude Code Security Review / Kuzushi) — non-gating, non-deterministic.
- **Nuclei** — manual, allowlisted.
- **OpenSSF Scorecard** — needs repo token in CI.
- **Grype** — not run.
- **OWASP Dependency-Check** — not run.
- **Checkov / Conftest / Terrascan** — no IaC in the pilot to scan.
- **Dockle** — needs a built image.
- **Psalm / Deptrac / ESLint** — **not configured** in zenchron-tools, so the runners correctly
  reported `not-configured` / `unavailable` (no fake-clean output). Promotion needs a consumer
  that configures them.

## Onboarding the next consumer

A second consumer is what promotes `supported` tools to `proven`. To onboard one, follow
[`profile-driven-adoption.md`](profile-driven-adoption.md) and
[`product-readiness-checklist.md`](product-readiness-checklist.md), run a tool that is currently
`supported`/`experimental`, and record the run ID + raw→summary-key evidence here.
</content>

## zenchron-tools — main-gate live validation (2026-06-09)

- **sentinel-shield-main-validation / run 27214865086 — success.** Promoted with artifact
  evidence (see [`main-gate-live-evidence.md`](main-gate-live-evidence.md)): **CodeQL** (codeql.json
  669 KB SARIF → 0/0/11 medium), **OSV-Scanner** (osv-scanner.json → 1 high), **Trivy-fs**
  (trivy.json 308 KB → clean), **Syft SBOM** (sbom.spdx.json 964 KB). Grype/Dependency-Check/Dockle
  = unavailable (binary/image absent — wrappers no-op, no fake). Deptrac = not configured.
  Checkov/Conftest/Terrascan = no IaC.
- **sentinel-shield baseline / run 27214863297 — FAIL (correct gate behavior).**
  `critical_vulnerabilities=2` from a real npm critical: `shell-quote` (1.1.0–1.8.3) pulled via
  `concurrently@9.2.1`. The release gate **correctly blocked**. This is a consuming-project
  dependency finding — fixed in zenchron's own PR. Sentinel Shield does **not** suppress,
  accept-risk, or downgrade it. PHPStan 0, tests 0, unsafe_docker 5/0, gh-actions 0 — unchanged.
