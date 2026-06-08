# Sentinel Shield Rollout Status

> Generic template. Copy to `docs/security/sentinel-shield-rollout-status.md`. Tracks a
> project's adoption journey and open follow-ups.

## Current state
- **Mode:** report-only | baseline | strict | regulated
- **Baseline status:** PASS | FAIL
- **Sentinel Shield ref:** `<tag>` pinned to `<full commit SHA>`
- **Last enforced run:** `<run id / link>`

## Adoption ladder
- [ ] report-only adopted (workflow runs, summary produced)
- [ ] real scanners wired (no example-summary fallback)
- [ ] baseline gates passing (secrets/critical/high/type/test/docker/actions)
- [ ] CI refs + images pinned to SHAs/digests
- [ ] strict / regulated (when ready)

## Open follow-ups (Issues)
### Issue N — <title>
- **Context / risk:**
- **Acceptance:**
- **Owner / target:**
- **Status:**

## Accepted risks in force
| id | gate | scope | rule_id/files | expires | review |
| --- | --- | --- | --- | --- | --- |
