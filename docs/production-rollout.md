# Production Rollout

> **Stable adoption doc (v1.2.0).** This is an additive, docs-only operations guide for adopting
> Sentinel Shield across **real production projects** at an organization. It changes **no** STABLE
> surface, gate, schema, or maturity label. Where any maturity claim here disagrees with
> [`product-status.md`](product-status.md), that file wins.

This page is the **practical playbook** a platform or security owner runs when standing Sentinel
Shield up across many projects: how to stage the rollout, when to use each mode, how to govern
accepted risk, and how to keep many consumers consistent and reproducible. It **points at** the
authoritative mechanics rather than restating them.

**Read these first — this doc complements, it does not duplicate them:**
- [`multi-project-rollout.md`](multi-project-rollout.md) — the wave model for rolling across many repos at scale.
- [`consumer-onboarding.md`](consumer-onboarding.md) — the per-consumer onboarding checklist (pilot → production → regulated).
- [`adoption-guide.md`](adoption-guide.md) — the mode phases (report-only → baseline → strict → regulated).
- [`accepted-risk-suppression.md`](accepted-risk-suppression.md) / [`exception-policy.md`](exception-policy.md) — accepted-risk mechanics and policy.
- [`gate-resolution.md`](gate-resolution.md) — mode → enforced gate-threshold mapping.
- [`strict-mode-readiness.md`](strict-mode-readiness.md) / [`regulated-mode-readiness.md`](regulated-mode-readiness.md) — the strict/regulated pre-flights.
- [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md) — version pinning, upgrade, rollback.
- [`install-sync-guide.md`](install-sync-guide.md) — install/sync mechanics, rollback, troubleshooting.

> A separate `multi-project-adoption.md` is **not** needed — multi-project sequencing already lives in
> [`multi-project-rollout.md`](multi-project-rollout.md). Use that file; this one is the org-level
> rollout + ownership operations layer on top of it.

---

## 1. The staged rollout: pilot → staged → default

Roll Sentinel Shield out to an organization in three stages. This is the org-level frame; the
per-wave repo sequencing is in [`multi-project-rollout.md`](multi-project-rollout.md), and the
per-consumer checklist is in [`consumer-onboarding.md`](consumer-onboarding.md).

| Stage | Scope | Mode floor | Exit signal |
| --- | --- | --- | --- |
| **Pilot** | One low-stakes repo with active CI and a shipped profile | `report-only` | PR-fast gate runs green in report-only; baseline triaged; tool refs pinned; evidence (run id + summary) captured |
| **Staged** | A handful of representative repos (one per stack you ship) | `report-only` → `baseline` | Onboarding proven *repeatable*, not project-specific; pinned-ref + triage conventions reused |
| **Default** | Sentinel Shield is the expected baseline for new and existing production repos | `baseline` (strict/regulated opt-in per project) | New repos adopt by default; a central pinned `SENTINEL_SHIELD_REF`; rollout tracker is the source of truth |

Rules that hold at every stage:
- **Every project starts in `report-only`.** No exceptions — production repos most of all, because a
  surprise gate failure there is the most expensive.
- **Promote one mode at a time**, deliberately, with team agreement, gated on the relevant pre-flight.
- **Pin tool refs once, reuse everywhere** so CI is reproducible and upgrades are deliberate.
- **Strict and regulated are opt-in, never the org default** — they correctly fail on real findings.

---

## 2. When to use each mode

Modes are set per project in `.sentinel-shield/profile.yaml` (`gates.mode`) and resolve to enforced
thresholds via [`gate-resolution.md`](gate-resolution.md). Full phase detail is in
[`adoption-guide.md`](adoption-guide.md); use this table as the trigger checklist.

| Mode | What gates (additive) | Use it when… |
| --- | --- | --- |
| **report-only** | Observe only — nothing blocks except `secrets` and `expired_exceptions` | First contact with any repo; legacy backlog; measuring true noise before committing to a gate |
| **baseline** | + secrets, critical/high vulns, architecture, type errors, test failures, unsafe_docker, unsafe_github_actions — new-code gating; **migration/legacy debt tolerated** | The default steady state: new risk must not merge, but you are not forcing a backlog burn-down |
| **strict** | + `medium_vulnerabilities`, `missing_sbom`, style_violations, iac_violations, container_image_violations, and the higher-confidence third-party signals — whole codebase, not just new code | A clean run is achievable on demand; medium/style triaged or accept-risked; pre-flight ([`strict-mode-readiness.md`](strict-mode-readiness.md)) passes. **Opt-in.** |
| **regulated** | + release-evidence, scorecard, the noisier third-party signals | A compliance regime requires auditable evidence per release; pre-flight ([`regulated-mode-readiness.md`](regulated-mode-readiness.md)) passes. **Opt-in.** |

> **Engineering quality gates (v2.1) — unreleased, additive engine capability.** A separate
> engineering-quality counter channel (coverage, coverage regression, mutation, complexity,
> duplication, dead code) follows the **same promotion path** as the modes above: non-blocking in
> report-only/baseline, `strict` adds coverage threshold/regression + complexity + duplication, and
> `regulated` adds mutation + dead-code. It is **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim (latest release remains `v2.0.1`); adopt it report-only-first via
> `.sentinel-shield/quality-policy.yaml`. See [`engineering-quality-gates.md`](engineering-quality-gates.md).

Concrete triggers:
- **Stay in report-only longer** for legacy repos with a large finding backlog — that is a legitimate
  state, not a failure.
- **Move to baseline** once recent PRs are clean in report-only and the existing backlog is inventoried
  as owned accepted-risk.
- **Move to strict** only after medium + style are clean or accept-risked and the strict pre-flight is
  green. A project may live in `baseline` indefinitely; do not chase strict early.
- **Move to regulated** only for projects under a compliance regime, and only after the regulated
  pre-flight passes. DAST stays manual/fail-closed and AI review stays non-gating in every mode.

---

## 3. Profile selection

Profile selection is a **deliberate human choice** via the `--profile` flag — there is no
auto-detect/recommend command. Use the decision tree and stack table referenced from
[`multi-project-rollout.md` §206](multi-project-rollout.md#206--profile-selection-guidance).

| `--profile` | Pick when the repo ships… |
| --- | --- |
| `laravel` | a Laravel application |
| `symfony` | a Symfony 6/7 application |
| `php-library` | a plain PHP package (generic PHPStan, not Larastan) |
| `node` | a Node service only |
| `react` | a React (Vite) SPA only |
| `docker` | containers/IaC **only**, no app language |
| `node-react` | Node + React in one repo (combination) |
| `laravel-react-docker` | Laravel + React + Docker in one repo (default; `proven` install/sync) |

Install/sync via `scripts/install-baseline.sh` / `scripts/sync-baseline.sh` — **dry-run is the
default**; nothing is written until `--apply`. If no profile fits the repo's mix, install the closest
single app profile and add the other stack's assets manually (the decision tree calls this out).

---

## 4. Accepted-risk governance

Accepted risk is the **only** legitimate suppression path. A scanner suppression without an exception
record is itself a finding. Mechanics: [`accepted-risk-suppression.md`](accepted-risk-suppression.md);
policy: [`exception-policy.md`](exception-policy.md).

- **Every record carries owner + reason + expiry**, plus `status: approved` (Sentinel Shield never
  sets `approved` — it is a reviewed human action). Prefer **finding-scoped** records (`rule_id` +
  `files`) over broad `scope: gate`.
- **Fail-closed on expiry.** An expired (or pending/rejected) record stops suppressing — the gate
  re-fires. Set realistic expiries; an expiry is a forcing function to revisit, not a snooze.
- **Secrets are never suppressible.** Neither are `expired_exceptions`,
  `missing_release_evidence`, `missing_sbom`, critical/high vulns, type/test/architecture, or
  `unsafe_github_actions`. Only `unsafe_docker` and `medium_vulnerabilities` are honored.
- **Findings are never hidden.** Raw counts are preserved; suppression is explicit and reported in the
  enforcement artifacts.
- **The consumer owns this file.** `.sentinel-shield/accepted-risks.json` is **never** created or
  overwritten by install/sync.

**Review cadence:**
- Review accepted risks at least monthly, and before any mode promotion.
- Treat any expired record surfaced by the gate as a triage item, not an outage — fix the finding or
  file a fresh, justified record.
- In `regulated` mode, exceptions must be formal (owner, reason, expiry, **approval**).

---

## 5. Multi-project consistency

The lever for consistency is **version pinning**, not copy-paste.

- **Pin every consumer to the same `SENTINEL_SHIELD_REF`** — a tag or full commit SHA, never a moving
  branch. Tags are immutable, so a pinned ref makes each consumer's CI reproducible.
- **Bump centrally.** To move the fleet, bump the ref in one place and roll it to consumers; that is
  how you keep many projects on identical scanner behavior. See
  [`v1.1-onboarding-and-migration.md`](v1.1-onboarding-and-migration.md).
- **Pin scanner images/actions by digest in production** so production gates don't drift with upstream
  tool releases (see the hardened example referenced from the onboarding guide).
- **Sync deliberately.** When a newer Sentinel Shield ships, run `sync-baseline.sh` as a drift report
  first, then `--apply --force`. Sync honors `never_touch` and **never** clobbers project-local risk
  decisions (`profile.yaml`, `accepted-risks.json`, baselines).
- **Track per-project state** (profile, mode, pinned ref, last sync, evidence run id) in the rollout
  tracker from [`multi-project-rollout.md`](multi-project-rollout.md#suggested-rollout-tracker-columns).

---

## 6. Handling noisy findings

`experimental`/`supported` scanners emit coarse severities — treat them as review prompts, not
verdicts. The triage loop, in order of preference:

1. **Fix** the finding. Acceptance is a time-boxed bridge, not a resolution.
2. **Accept-risk with an expiry** when a fix isn't immediate — owner + reason + expiry, finding-scoped
   where possible. This keeps the finding visible and re-surfaces it on expiry.
3. **Scope the scanner** (e.g. `.semgrepignore`, path filters) so a tool only sees code it should —
   this reduces noise without hiding real findings.
4. **Never silently suppress.** Do not disable a gate, zero a count, or delete a finding. The only
   legitimate quietening is an approved, unexpired, owner-bound accepted-risk record on a suppressible
   gate.

If a whole scanner is too noisy to gate on yet, keep it in `report-only` for that project (or keep the
project in `baseline`) rather than weakening enforcement globally.

---

## 7. Ownership model

Sentinel Shield owns the **engine**; the consumer owns the **risk decisions**. Sentinel Shield never
remediates or suppresses a consumer's findings.

| Sentinel Shield OWNS | The CONSUMER owns |
| --- | --- |
| Templates, collectors, gates, the resolve/enforce engine | `.sentinel-shield/profile.yaml` (mode + per-gate overrides) |
| Managed workflow + scripts (`install`/`sync`) | `.sentinel-shield/accepted-risks.json` (owner + reason + expiry) |
| Maturity labels (source of truth: [`product-status.md`](product-status.md)) | Findings, triage, and remediation of its own code |
| Schema + summary contract (semver-stable) | Pinned `SENTINEL_SHIELD_REF` and scanner digests for its repo |

Consequences: accepted-risk is the **only** legitimate suppression path; secrets are never
suppressible; install/sync never touches consumer-owned files (`profile.yaml`, `accepted-risks.json`,
baselines, code).

---

## 8. Rollout checklist (org owner)

```txt
[ ] Pick the pilot repo (low-stakes, active CI, shipped profile)
[ ] Choose one central SENTINEL_SHIELD_REF (immutable tag or full SHA) for the fleet
[ ] Pilot: install in report-only (dry-run, then --apply); pin tool refs; triage baseline
[ ] Capture pilot evidence (workflow run id + security summary) as the reference baseline
[ ] Staged: onboard one repo per stack you ship; prove onboarding is repeatable
[ ] Stand up a rollout tracker (project, stack, profile, mode, ref, last sync, evidence)
[ ] Promote pilot/staged repos report-only → baseline once new code stops adding risk
[ ] Make Sentinel Shield the default for new production repos (baseline floor)
[ ] Define the accepted-risk review cadence and assign owners
[ ] Document the central upgrade + rollback procedure for the fleet
```

## 9. Project-readiness checklist (per repo)

```txt
[ ] Profile chosen from the table (smallest that covers what the repo ships)
[ ] .sentinel-shield/profile.yaml present; mode: report-only first
[ ] SENTINEL_SHIELD_REF pinned to the central tag/SHA (no moving branch)
[ ] Scanner images/actions pinned by digest (production)
[ ] reports/ gitignored in the consumer
[ ] PR-fast gate runs green in report-only; summary produced
[ ] Baseline triaged; accepted-risks.json filled (owner + reason + expiry)
[ ] strict/regulated pre-flight passed BEFORE promoting to those modes
[ ] DAST kept manual/fail-closed; AI review kept non-gating
```

---

## 10. Team-responsibilities matrix

| Activity | Platform team | Security team | App team |
| --- | --- | --- | --- |
| Choose/maintain central `SENTINEL_SHIELD_REF`, bump centrally | **Owns** | Consulted | Informed |
| Profile selection + install/sync per repo | **Owns** | Consulted | Consulted |
| Mode promotion (baseline → strict → regulated) | Facilitates | **Approves** | **Requests** |
| Accepted-risk records (owner + reason + expiry) | Reviews | **Approves policy** | **Owns its records** |
| Triage + remediation of findings | Supports | Advises | **Owns** |
| Strict/regulated pre-flights + evidence retention | Supports | **Owns** | Supplies evidence |
| Upgrade + rollback execution | **Owns** | Informed | Informed |

Owners differ per organization — adapt the matrix, but keep one principle: the **consumer (app team)
owns its findings and accepted-risk records**, the **platform team owns the engine and the pinned
ref**, and the **security team owns policy and approvals**.

---

## 11. Upgrade policy

- **Semver from `v1.0.0`.** Minor releases are additive and drop-in (new capabilities are opt-in /
  default-off); any rename/removal/exit-code or summary-key change is a **major**. STABLE surfaces and
  coarse scanner severity follow [`product-contract.md`](product-contract.md).
- **Upgrade by bumping the ref.** Move `SENTINEL_SHIELD_REF` to the new immutable tag (or full SHA),
  centrally, then roll to consumers. No STABLE surface is renamed/removed across a minor, so existing
  pipelines behave identically.
- **Pin a release candidate for soak** when validating a new major: pin the RC tag, run the gate,
  report regressions before the final tag.
- **Sync managed files after the bump** with `sync-baseline.sh` (drift report → `--apply --force`);
  consumer-owned files are never touched.

## 12. Rollback strategy

Because tags are immutable, the exact prior behavior is always retrievable. Roll back at the smallest
scope that resolves the problem:

| Symptom | Roll back by… |
| --- | --- |
| New Sentinel Shield version misbehaves | Bump `SENTINEL_SHIELD_REF` back to the prior tag/SHA |
| A scanner image regressed | Restore the prior `@sha256:` digest pin |
| A mode promotion is too disruptive | Lower `gates.mode` (e.g. `strict` → `baseline`) in `profile.yaml` — record it and time-box it |
| An accepted-risk change broke the gate | Revert the `accepted-risks.json` edit (consumer-owned; in the repo's history) |

A backward mode move during an incident is allowed but must be **recorded and time-boxed** — it is a
bridge, not a new steady state. After any rollback, capture why in the rollout tracker so the fleet's
state stays accurate.
