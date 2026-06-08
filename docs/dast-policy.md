# DAST Policy (v0.1.12)

DAST (OWASP ZAP baseline/full, Nuclei) is **manual / controlled** — never a PR check and
never run by default. Findings map to the `dast_findings` summary key (gated only in
`regulated` by default).

## Hard safety rules (enforced by `scripts/runners/dast-guard.sh`)
1. **No target → no scan.** Without `SENTINEL_SHIELD_DAST_TARGET_URL` the runner SKIPS (exit 0).
2. **Allowlist required, fail closed.** Without `SENTINEL_SHIELD_DAST_ALLOWED_HOST`, or if the
   target host ≠ the allowlisted host, the runner **fails closed** (exit 3, no scan).
3. **http/https only.** Any other scheme fails closed.
4. Never scan production without written approval — use a staging target you control.

## How to run
1. Complete [`templates/dast-scan-approval.md`](../templates/dast-scan-approval.md) (and
   [`templates/nuclei-target-allowlist.md`](../templates/nuclei-target-allowlist.md) for Nuclei).
2. Trigger `sentinel-shield-dast.yml` (workflow_dispatch) with `target_url` + `allowed_host`.
3. Review `reports/raw/{zap,zap-full,nuclei}.json`; file accepted-risks for confirmed findings.

ZAP **full** is active/intrusive — separate approval; staging only.
