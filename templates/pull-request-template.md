<!-- Sentinel Shield — Pull Request template. Copy to .github/pull_request_template.md -->

## Summary

<!-- What does this change do, and why? Link the issue/ticket. -->

## Risk level

- [ ] Low — isolated, no security/data/infra impact
- [ ] Medium — touches shared code or non-sensitive data paths
- [ ] High — touches authentication, authorization, payments, compliance, data
      access, cron/queue jobs, or infrastructure (**requires security review**)

## Security impact

<!-- Does this change affect auth, authz, input handling, secrets, crypto, file
     uploads, external requests (SSRF), or dependencies? Describe. If none, say so. -->

- New/changed inputs validated:  yes / no / n/a
- AuthZ enforced server-side (object-level):  yes / no / n/a
- Secrets handled via env/secret manager (none in code):  yes / n/a
- New dependencies reviewed/audited:  yes / n/a

## Tests

- [ ] Unit/feature tests added or updated
- [ ] Tests pass locally
- [ ] Critical paths covered

## Deployment impact

<!-- Migrations? Config/env changes? Backward-compatible? Feature flags? -->

## Rollback notes

<!-- How to roll back if this fails in production. Migrations must be reversible or
     paired with a tested down-path. -->

## Checklist

- [ ] Follows the secure-coding standard
- [ ] No secrets committed
- [ ] Static analysis / lint / types pass
- [ ] Architecture boundaries respected
- [ ] Docker/Actions changes follow the hardening standards (if applicable)
- [ ] High-risk change has a completed security review (if applicable)
- [ ] Any accepted risk has an exception record (owner, expiry, approval)
