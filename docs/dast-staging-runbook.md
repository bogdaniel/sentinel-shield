# DAST Staging / Manual Runbook (v1.8.0 — A06)

Operational runbook for ZAP (baseline/full) and Nuclei. **DAST stays `manual` / non-default.** It is
**never** in the PR-fast gate and never scans arbitrary targets. Builds on
[`dast-policy.md`](dast-policy.md), [`dast-zap-readiness.md`](dast-zap-readiness.md),
[`nuclei-readiness.md`](nuclei-readiness.md), [`nuclei-guard.md`](nuclei-guard.md).

## Staging target contract (hard)

- Scan **only** a **staging/pre-prod** target you own and are authorized to test.
- Required env: `SENTINEL_SHIELD_DAST_TARGET_URL` + `SENTINEL_SHIELD_DAST_ALLOWED_HOST`.
- **Missing target → skip; host mismatch → fail closed** (guarded). Never a default value.

## Forbidden targets

Production, third-party hosts, shared infra, anything not on the allowlist, anything you lack written
authorization for. A host outside the allowlist **fails closed** — by design.

## Authentication & scope

- Authenticated scans are **out of scope unless explicitly configured** with throwaway/staging creds
  (never production credentials, never committed).
- Active/attack scans (ZAP full) require **manual approval** + a defined scan window.

## Rate limits & windows

- Respect target rate limits; schedule active scans in an agreed window; coordinate with the owner.
- Prefer ZAP **baseline** (passive) first; escalate to **full** only with approval.

## Artifacts & collectors

- `zap.json` / `zap-full.json` → `zap.sh` → `dast_findings`; `nuclei.json` → `nuclei.sh` →
  `dast_findings`. Upload `if: always()`.

## Nuclei template-path policy

Templates must come from a pinned, reviewed path (`ss_nuclei_template_check`); no arbitrary remote
templates. See [`nuclei-guard.md`](nuclei-guard.md).

## Failure handling / rollback / cancel

- A failed/blocked scan reports `unavailable` — **never** a fake clean.
- Cancel = stop the workflow run; DAST creates no infra, so there is nothing to tear down.

## Example: evidence-only manual workflow (sketch)

```yaml
name: sentinel-shield-dast-staging
on: { workflow_dispatch: {} }     # MANUAL ONLY — never on push/PR
permissions: { contents: read }
jobs:
  zap-baseline:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@<sha>
      - name: ZAP baseline (passive, staging only)
        env:
          SENTINEL_SHIELD_DAST_TARGET_URL: ${{ vars.DAST_STAGING_URL }}
          SENTINEL_SHIELD_DAST_ALLOWED_HOST: ${{ vars.DAST_ALLOWED_HOST }}
        run: echo "run ZAP baseline against $SENTINEL_SHIELD_DAST_TARGET_URL (allowlisted)"
      - uses: actions/upload-artifact@<sha>
        if: always()
        with: { name: zap-evidence, path: zap.json, retention-days: 30 }
```

## Self-test / non-default guarantee

`self-test` asserts DAST is **not** in the PR-fast set and fails closed on host mismatch / non-http.
DAST is never promoted to a default gate in this release (deferred — see [`roadmap.md`](roadmap.md)).
