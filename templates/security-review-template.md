# Security Review

Use for high-risk changes (authentication, authorization, payments, compliance,
data access, cron/queue jobs, infrastructure) and for periodic reviews. Required in
`strict` and `regulated` modes for the above categories.

| Field | Value |
| --- | --- |
| Change / feature | |
| PR / ticket | |
| Reviewer(s) | |
| Date | |
| Risk level | low / medium / high |

## Scope

What is in scope for this review, and what is explicitly out of scope.

## Assets

What is being protected (data, funds, credentials, availability, integrity)?
Classify sensitivity (PII, payment, auth, audit).

## Trust boundaries

Where does control/trust change hands (client ↔ server, service ↔ service,
tenant ↔ tenant, app ↔ third party)? List each boundary.

## Data flows

How does data move through the change? Note where untrusted input enters and where
sensitive data is stored, transmitted, or logged.

```
[actor] --> [entry point] --> [validation] --> [logic] --> [store / external call]
```

## Threats

Enumerate threats (STRIDE or freeform). For each: how it could be exploited and the
current control.

| # | Threat | Affected asset | Existing control | Adequate? |
| --- | --- | --- | --- | --- |
| 1 | | | | yes/no |

## Findings

| # | Severity | Description | Recommendation | Status |
| --- | --- | --- | --- | --- |
| 1 | | | | open/fixed/accepted |

## Decisions

Key security decisions made during review and their rationale.

## Accepted risks

List any risks accepted instead of fixed. Each must have an exception record
(owner, reason, severity, expiry, review, mitigation, approval) per
[`../docs/exception-policy.md`](../docs/exception-policy.md).

## Outcome

- [ ] Approved
- [ ] Approved with conditions (list above)
- [ ] Rejected — must address findings and re-review
