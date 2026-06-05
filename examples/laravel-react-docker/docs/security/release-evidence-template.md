# Release Evidence

> Project-provided release readiness evidence. Complete this before a `regulated`
> release. The Sentinel Shield enforcement rollup is appended to a copy of this file
> at `reports/release-evidence.md` by CI — it does not replace the human sections
> below.

| Field | Value |
| --- | --- |
| Release / tag | |
| Commit SHA | |
| Date | |
| Release owner | |
| Adoption mode | report-only / baseline / strict / regulated |

## Scope

What is being released (features, fixes, migrations)? What is explicitly out of scope?

## Risk and security review

- High-risk changes (auth, payments, compliance, data access, cron/queue jobs,
  infrastructure)? List and link the security review for each (or state n/a).
- Open exceptions for this release: IDs, owners, expiry dates.

## SBOM

- [ ] SBOM generated and archived (`reports/sbom.spdx.json`)
- New critical/high components triaged: yes / no / n/a

## Rollback

- Previous known-good version:
- Migrations reversible or paired with a tested down-path: yes / no / n/a
- Rollback procedure (and who executes it):

## Verification

- [ ] Tests pass
- [ ] Static analysis / type checks pass at target level
- [ ] Container/IaC scans reviewed
- [ ] Secrets scan clean

## Approvals

| Role | Name | Decision | Date |
| --- | --- | --- | --- |
| Release owner | | approve / hold | |
| Security | | approve / hold | |
| Compliance (regulated) | | approve / hold | |

---

_CI appends the Sentinel Shield enforcement rollup below this line._
