# Nuclei Target Allowlist

> The host you pass as `SENTINEL_SHIELD_DAST_ALLOWED_HOST`. The runner fails closed if the
> target host is not exactly one of these.

| Host | Environment | Owner | Approved until | Notes |
|---|---|---|---|---|
| staging.example.com | staging | … | YYYY-MM-DD | … |

Templates/severity: restrict to `medium,high,critical`; never run against production or
third-party hosts you do not own. See docs/dast-policy.md.
