# Accepted Risk Record

> Copy this file to `.sentinel-shield/exceptions/EXC-YYYY-NNN.md` in the consuming
> project, fill every field, and obtain approval before the suppression is valid.
> See [`../../docs/exception-policy.md`](../../docs/exception-policy.md).

| Field | Value |
| --- | --- |
| Exception ID | EXC-YYYY-NNN |
| Owner (named person) | Name \<email\> |
| Affected component | path / package / service |
| Finding reference | scanner + rule ID / advisory / link |
| Severity | critical \| high \| medium \| low |
| Reason for acceptance | why this risk is being accepted now |
| Mitigation / compensating controls | what reduces the risk meanwhile |
| Expiry date | YYYY-MM-DD (auto-lapses) |
| Review date | YYYY-MM-DD (before expiry) |
| Approved by | role + name (must match severity authority) |
| Approval date | YYYY-MM-DD |

## Context

Describe the finding, where it occurs, and why it cannot be fixed immediately.

## Risk analysis

- Impact if exploited:
- Likelihood / exploitability:
- Affected data / users:
- Why the residual risk is acceptable for the stated window:

## Mitigation

Concrete compensating controls currently in place (network restrictions, WAF rules,
feature flags, monitoring/alerting, reduced exposure).

## Suppression linkage

Record where the suppression is applied so it can be removed on expiry:

- [ ] Semgrep `nosemgrep: <rule-id>  # EXC-YYYY-NNN`
- [ ] Trivy `.trivyignore` entry referencing this ID
- [ ] audit-ci allowlist entry referencing this ID
- [ ] Other: ___

## Lifecycle

- [ ] Raised with all fields complete
- [ ] Approved by the required authority
- [ ] Suppression applied and references this ID
- [ ] Surfaced in the production readiness report
- [ ] Reviewed on the review date
- [ ] Resolved or re-approved before expiry

> On the expiry date this exception lapses automatically and the underlying gate
> re-activates. There is no permanent exception.
