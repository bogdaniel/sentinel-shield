# Production Readiness Report

Release evidence for a production deploy. Required in `regulated` mode and
recommended in `strict`. Completed before the production release gate
([`../RELEASE-GATES.md`](../RELEASE-GATES.md)).

| Field | Value |
| --- | --- |
| Project | |
| Release / tag | |
| Commit SHA | |
| Adoption mode | report-only / baseline / strict / regulated |
| Release owner | |
| Date | |

## 1. Gate status

| Gate | Result | Evidence (link/artifact) |
| --- | --- | --- |
| Build / install from lockfile | pass/fail | |
| Secret scan (Gitleaks) | pass/fail | |
| SAST (Semgrep / CodeQL) | pass/fail | |
| Dependency audit (composer/npm/OSV) | pass/fail | |
| Container scan (Hadolint / Trivy) | pass/fail | |
| Static analysis / types | pass/fail | |
| Architecture (Deptrac) | pass/fail | |
| Tests | pass/fail | |

## 2. SBOM

- [ ] SBOM generated (Syft) and archived
- Format: CycloneDX / SPDX
- Artifact link:
- [ ] SBOM scanned (Grype); new critical/high triaged

## 3. Vulnerabilities and exceptions

| Severity | Open count | Covered by exception? | Exception IDs |
| --- | --- | --- | --- |
| Critical | | | |
| High | | | |
| Medium | | | |

All open exceptions have owner, reason, expiry, review, mitigation, and approval.

## 4. Security review (high-risk changes)

- [ ] Auth changes reviewed (or n/a)
- [ ] Payments changes reviewed (or n/a)
- [ ] Compliance/data-access changes reviewed (or n/a)
- [ ] Cron/queue job changes reviewed (or n/a)
- [ ] Infrastructure changes reviewed (or n/a)
- Review links:

## 5. Rollback

- [ ] Known-good previous version identified:
- [ ] Migrations reversible or paired with tested down-path
- [ ] Rollback procedure documented and verified

## 6. Observability

- [ ] Security-relevant events logged (auth, authz denials, admin actions)
- [ ] No secrets/PII in logs
- [ ] Alerting in place for security and availability

## 7. Sign-off

| Role | Name | Decision | Date |
| --- | --- | --- | --- |
| Release owner | | approve/hold | |
| Security | | approve/hold | |
| Compliance (regulated) | | approve/hold | |

> The release gate fails if any required item above is missing for the project's
> adoption mode.
