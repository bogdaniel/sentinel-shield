# FAQ

> Reference/support doc (v1.2.0)

Concise answers to the questions new adopters ask most. For symptom-driven debugging see
[`troubleshooting.md`](troubleshooting.md); for the authoritative interface contract see
[`product-contract.md`](product-contract.md).

---

**Q: What is Sentinel Shield?**
A release-gate **engine**. It resolves a project's declared adoption mode into enforceable gate
thresholds, runs a set of security/quality scanners, normalizes their output into a single
`reports/security-summary.json`, and decides pass/fail. The engine
(resolver / enforcer / summary-builder / install / sync / self-test) is `proven` and self-gated.

**Q: Is it a scanner suite?**
Not exactly. It is the **engine and contract** that orchestrates and gates on scanners. It
ships integrations for many scanners, but the value is the consistent gate/summary/accepted-risk
machinery — not a bespoke scanner. Many individual scanner integrations are `supported` or
`experimental` and should run advisory before you let them block. See
[`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md).

**Q: Does v1.0 mean every scanner is a production default?**
**No.** v1.0 means the **engine** interfaces are STABLE and production-ready. It is **not** a
turnkey "all scanners proven" product. Several scanner integrations are `supported` /
`experimental` and should run advisory first. The canonical maturity claims live in
[`product-status.md`](product-status.md).

**Q: Which mode should I use?**
Start in `baseline` (a migration aid that blocks on the highest-confidence findings). Move to
`strict` only after completing the strict pre-flight. `regulated` adds further gates (e.g.
`dast_findings`). See [`strict-mode-readiness.md`](strict-mode-readiness.md).

**Q: Is strict mode required?**
No. Strict is **opt-in**. It turns Sentinel Shield from a migration aid into a production
release requirement by making medium/style/etc. hard blockers. Adopt it when you are ready, not
before.

**Q: Why did my gate fail when the scanner succeeded?**
Because the scanner **found something**. The gate blocks on findings, so a successful scan with
findings yields exit `1`. That is correct. Triage the finding or record an accepted risk — do
not suppress. See [`gate-resolution.md`](gate-resolution.md).

**Q: A scanner exited non-zero but a report still exists — is that broken?**
No. A non-zero exit is normal when findings are present; the wrapper **preserves the valid
report** (preserve-on-nonzero). If **no** valid JSON was produced, the collector reports
`unavailable` rather than faking a clean result.

**Q: What do the exit codes mean?**
`0` = success, `1` = a gate failed (findings block), `2` = a config-or-input error (bad/missing
input, invalid JSON, missing required summary key). These are **STABLE** —
[`product-contract.md`](product-contract.md).

**Q: How do I accept a risk?**
Add an **approved, unexpired, owner-bound, scoped** JSON record to
`.sentinel-shield/accepted-risks.json`. It must match the finding on `rule_id` + `files`. A
Markdown draft does nothing; pending/expired/legacy-unscoped records do not suppress; **secrets
are never suppressible**. See [`accepted-risk-suppression.md`](accepted-risk-suppression.md).

**Q: I added an accepted risk but the gate still fails — why?**
The record is probably missing one of: approved, unexpired, owner-bound, or a matching
`rule_id` + `files` scope. See the accepted-risk-mismatch section in
[`troubleshooting.md`](troubleshooting.md).

**Q: Do I need the NVD API key?**
You need it for Dependency-Check to avoid HTTP 429 throttling. Provide the GitHub secret
`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`. Without it, DC uses the anonymous (throttled)
NVD rate limit and is likely to fail. See
[`dependency-check-ci-cache.md`](dependency-check-ci-cache.md).

**Q: How is the NVD key kept safe?**
It is **consumer-provided** via a GitHub secret and handed to Dependency-Check only through a
`0600 --propertyfile` — **never** on the command line, so it stays off process listings and CI
logs. **Never print, log, paste, or commit the value.** See
[`security-hygiene.md`](security-hygiene.md).

**Q: How do I rotate the NVD key?**
Regenerate it at NVD, update the GitHub Actions secret with `gh secret set` (value piped from a
`0600` file or entered at the hidden prompt — never echoed), re-run Dependency-Check, then
delete the old key locally and keep it out of shell history. Full steps in
[`security-hygiene.md`](security-hygiene.md).

**Q: What's the difference between committed and transitive Dependency-Check?**
By default DC scans what is present. To scan the full **transitive** tree, enable the opt-in
knobs `SENTINEL_SHIELD_DEPENDENCY_CHECK_INSTALL_PHP` / `INSTALL_NODE` (default `false`) so the
wrapper runs `composer install` / `npm ci` first. A **private registry** additionally needs
consumer-provided registry auth. See [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md).

**Q: How do I pin scanner images by digest?**
Templates are tag-pinned for readability, but tags are mutable. For supply-chain integrity, pin
scanner images by **digest** (`@sha256:…`). The resolved, real digests and the
verify/update/rollback procedure are in
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).

**Q: How do I upgrade Sentinel Shield?**
Bump `SENTINEL_SHIELD_REF` to the new tag (or full SHA — never a moving branch). Within a minor
line (e.g. `v1.0.0 → v1.1.0`) upgrades are **drop-in**: no STABLE surface is renamed/removed and
new capabilities are opt-in / default-off. See
[`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md).

**Q: How do I roll back?**
Set `SENTINEL_SHIELD_REF` back to the previous tag/SHA. Because the STABLE contract (exit codes,
env vars, schemas, modes, file modes) is unchanged across a minor line, rolling the ref back is
sufficient — your project-local files are untouched by install/sync.

**Q: What does install/sync touch, and what is safe?**
Both are **dry-run by default**; `--apply` writes, and `--force` overwrites **managed files
only**. Project-local files (`.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`)
are **never** created or overwritten. Sync detects "managed drift" and resolves with
`--apply --force`. See [`install-sync-guide.md`](install-sync-guide.md).

**Q: Where are the artifacts / reports?**
Under `reports/` — the normalized gate input is `reports/security-summary.json`, raw tool output
is under `reports/raw/`. A scanner with no valid raw JSON is reported `unavailable` (not clean).
See [`raw-report-contract.md`](raw-report-contract.md).

**Q: Is the AI review a gate?**
No. AI review is **non-gating** — it never blocks a build. See
[`ai-review-policy.md`](ai-review-policy.md).

**Q: How do I run DAST (ZAP / Nuclei)?**
Manually only. DAST is **manual / allowlisted / fail-closed** — never a PR check. No target →
it skips; host mismatch or non-`http(s)` scheme → it fails closed (exit `3`). Use a staging
target you control with an explicit allowlist. See [`dast-policy.md`](dast-policy.md).

**Q: My Semgrep run is noisy or hits parser errors — what do I do?**
Pin Semgrep to **`1.165.0`**, copy the profile `.semgrepignore` to your repo root, run from the
repo root, and use the **curated app rules** — never `--config=auto`. See
[`semgrep-scoping.md`](semgrep-scoping.md).

**Q: Do the workflow templates need elevated permissions?**
No. They use **minimal permissions** and never `pull_request_target`. Use them unmodified; add
the least scope necessary if you must extend them. See [`security-hygiene.md`](security-hygiene.md).
