# Public Adoption Kit (v1.7.0 — Agent E)

A single entry point for adopting Sentinel Shield. Everything here links to canonical docs; nothing
here changes defaults.

## One-page overview

Sentinel Shield is a **reusable release-gate engine + security/quality baseline**. It **normalizes
and gates** external scanner output into one contract (`security-summary.json`); it does **not**
bundle scanners. The gate engine is `proven` (self-gated in CI); individual scanners carry honest
maturity labels (see below). Adoption is **profile-driven** and **opt-in by mode**
(`report-only → baseline → strict → regulated`).

## Start in 30 minutes

1. [`quickstart.md`](quickstart.md) — install in `report-only`, wire the PR-fast gate.
2. [`install-sync-quickstart.md`](install-sync-quickstart.md) — profile install/sync model.

## Scale to production

- [`production-rollout.md`](production-rollout.md) — staged rollout.
- [`multi-project-rollout.md`](multi-project-rollout.md) — many teams/repos.
- [`enterprise-hardening.md`](enterprise-hardening.md) + the hardened snippet — digest/SHA pinning,
  least-privilege, retention.
- [`enterprise-iac-adoption.md`](enterprise-iac-adoption.md) — IaC gate at scale.

## Evidence & maturity (read this before trusting a gate)

- [`product-status.md`](product-status.md) — **canonical** per-tool maturity (source of truth).
- [`main-gate-live-evidence.md`](main-gate-live-evidence.md) — cited run IDs/artifacts.
- [`scanner-maturity-policy.md`](scanner-maturity-policy.md) — what each label means + promotion rules.
- [`evidence-platform.md`](evidence-platform.md) — how evidence is produced.

**Label cheat-sheet:** `proven` (engine) · `live-validated` (real consumer CI) · **`ci-validated
(evidence-fixture)`** (real CI on a non-deployed insecure fixture — IaC today) · `experimental` ·
`manual` (DAST) · `non-gating` (AI). `ci-validated` ≠ `live-validated`.

## FAQ (start)

- *Does it run the scanners?* No — you run them; SS normalizes/gates the output. See
  [`faq.md`](faq.md).
- *Is IaC production-proven?* IaC is `ci-validated (evidence-fixture)` — real CI on an insecure
  fixture, **not** yet a real-consumer `live-validated`. See
  [`scanner-maturity-policy.md`](scanner-maturity-policy.md).
- *Will upgrades break me?* STABLE surfaces follow semver
  ([`product-contract.md`](product-contract.md)).

## Decision matrix (which mode?)

| Situation | Mode |
|---|---|
| Trying it out / legacy repo with debt | `report-only` |
| New code should stop adding risk | `baseline` |
| Mature repo, ready to block on more | `strict` (opt-in) |
| Audit evidence required | `regulated` (opt-in) |

DAST/AI stay manual/non-gating regardless. See [`gate-promotion-policy.md`](gate-promotion-policy.md).

## Sample 4-week rollout

1. **Week 1:** install `report-only`; wire PR-fast; pin actions/images.
2. **Week 2:** triage findings; create owned `accepted-risks.json`; move to `baseline`.
3. **Week 3:** add main-gate scanners as advisory; review `experimental`/`ci-validated` severities.
4. **Week 4:** tighten to `strict` where clean; keep DAST/AI manual. Use `regulated` only if audited.
