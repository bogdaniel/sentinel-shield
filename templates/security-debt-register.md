# Security Debt Register

> Generic Sentinel Shield template. Copy to `docs/security/security-debt-register.md` in
> the consuming project and fill in. Tracks **known, accepted, time-boxed** security debt.
> Debt here is *tracked*, not *fixed* — every row needs an owner and a target.

| ID | Item | Status | Counted in gate? | Owner | Target / expiry |
| --- | --- | --- | --- | --- | --- |
| D1 | _e.g. PHPStan baseline debt (N)_ | tracked | no | _team_ | _rolling reduction_ |
| D2 | _e.g. Docker DL3018 (unpinned apk)_ | accepted-risk | no (accepted) | _owner_ | _expires YYYY-MM-DD_ |
| D3 | _e.g. dependency CVE deferred_ | deferred | no | _team_ | _next dep window_ |

## Per-item detail (one block per ID)

### D2 — <title>
```txt
finding:     <tool + rule + file:line>
gate:        <unsafe_docker | medium_vulnerabilities | ...>  (count preserved, not zeroed)
status:      approved accepted-risk
scope:       finding (rule_id + files)   # broad scope:gate is discouraged
owner:       <name / team>
approved_at: YYYY-MM-DD
review_at:   YYYY-MM-DD
expires_at:  YYYY-MM-DD
required action before expiry: <fix or renew with fresh approval>
on expiry:   the record stops suppressing; the gate blocks again
```

## Rules
- Only `unsafe_docker` / `medium_vulnerabilities` are suppressible; `secrets`,
  `expired_exceptions`, `missing_release_evidence` are never suppressible.
- Accepted-risk records live in `.sentinel-shield/accepted-risks.json` (a Markdown row
  alone does NOT suppress anything).
- Do not extend an expiry without a fresh, explicit approval.
