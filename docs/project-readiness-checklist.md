# Project Readiness Checklist

A scored checklist to assess whether a project meets the Sentinel Shield bar. Use it
at onboarding, before promoting to a stricter mode, and before a major release.

Scoring: each item is **Yes / Partial / No / N/A**. A category passes when all
items are Yes or justified N/A. Partial and No items need an owner and a plan (or an
approved exception).

---

## Security

- [ ] Secret scanning (Gitleaks) runs and is blocking.
- [ ] SAST (Semgrep + CodeQL) runs on PRs.
- [ ] Authentication uses the framework's vetted system; MFA for admin (regulated).
- [ ] Authorization is server-side, object-level, default-deny.
- [ ] Input validation and output encoding follow the secure-coding standard.
- [ ] No high/critical findings unaddressed (or all covered by approved exceptions).

## Quality

- [ ] Static analysis (PHPStan/Psalm or tsc) runs and is green at the target level.
- [ ] Linting/formatting (Pint/PHP-CS-Fixer/ESLint/Prettier) enforced in CI.
- [ ] Tests run in CI and pass; meaningful coverage of critical paths.
- [ ] Dead-code/unused-dependency check (Knip) reviewed.

## Architecture

- [ ] Layer boundaries enforced (Deptrac / ESLint import rules).
- [ ] Domain has no framework/infrastructure dependencies.
- [ ] Modules communicate via contracts/events/APIs.
- [ ] Tenant boundaries explicit and tested (multi-tenant systems).

## Docker

- [ ] Non-root user; minimal, pinned base image.
- [ ] No secrets in image layers or ENV.
- [ ] No privileged containers; capabilities dropped.
- [ ] Healthcheck and resource limits defined.
- [ ] Hadolint and Trivy pass at the target threshold.

## CI/CD

- [ ] Workflows use minimal permissions; no write-all.
- [ ] Third-party actions pinned in sensitive workflows.
- [ ] No unsafe `pull_request_target`; no shell injection.
- [ ] Build/test/deploy permissions separated; prod behind a protected environment.
- [ ] actionlint / zizmor pass.

## Observability

- [ ] Security-relevant events logged (auth, authz denials, admin actions).
- [ ] No secrets/PII in logs.
- [ ] Requests correlated with a trace/request ID.
- [ ] Alerting exists for security and availability signals.

## Compliance

- [ ] SBOM generated and archived (regulated).
- [ ] Exceptions are formal: owner, reason, expiry, review, mitigation, approval.
- [ ] Security review completed for auth/payments/compliance/data/cron/infra changes.
- [ ] Audit logs retained per the applicable regime.

## Release readiness

- [ ] All required release gates green for the released commit.
- [ ] Rollback plan documented and verified.
- [ ] Release evidence / readiness report completed (regulated).
- [ ] Emergency-release process understood and documented.

---

## Scoring summary

| Category | Score | Blocking gaps | Owner |
| --- | --- | --- | --- |
| Security | / | | |
| Quality | / | | |
| Architecture | / | | |
| Docker | / | | |
| CI/CD | / | | |
| Observability | / | | |
| Compliance | / | | |
| Release readiness | / | | |

A project is "ready" for a given mode when every category required by that mode
passes. See [`adoption-guide.md`](adoption-guide.md) for which categories each mode
requires.
