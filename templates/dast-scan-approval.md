# DAST Scan Approval

> Required before running sentinel-shield-dast.yml. See docs/dast-policy.md.

- **Requester / date:** …
- **Scan type:** zap-baseline | zap-full (active) | nuclei
- **Target URL:** …  (sets `SENTINEL_SHIELD_DAST_TARGET_URL`)
- **Allowed host (exact):** …  (sets `SENTINEL_SHIELD_DAST_ALLOWED_HOST`) ← must equal the target host or the runner FAILS CLOSED
- **Staging confirmation:** ☐ Target is staging / pre-prod that I own — NOT production.
- **Auth boundary:** scoped staging test account only; no production credentials; blast radius: …
- **Environment:** staging | pre-prod (NOT production without explicit sign-off)
- **Window (start/end):** …
- **Approver (owner of target system):** …  **Signature/date:** …
- **Approval expiry:** …  (after this date the approval is void; re-approve to scan again)
- **Rollback / blast-radius notes:** …

Active (zap-full) / Nuclei scans require explicit approver sign-off above.
See [`docs/dast-pilot-readiness.md`](../docs/dast-pilot-readiness.md) for the controlled-pilot checklist.
