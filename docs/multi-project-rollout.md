# Multi-Project Rollout Plan (v0.1.25)

How to roll Sentinel Shield across **many** consuming projects in a controlled, evidence-driven
sequence. For onboarding a **single** consumer end-to-end, see
[`consumer-onboarding.md`](consumer-onboarding.md); this doc is about doing it at scale.

> **Honesty / maturity.** The install/sync engine and the PR-fast gate are `proven`; most
> non-core scanner integrations are `supported`/`experimental`. The **single source of truth for
> maturity is** [`product-status.md`](product-status.md) — where any label here disagrees with that
> file, `product-status.md` wins. **This is not a v1.0 product** and makes no v1.0 claim. Every
> project starts in `report-only`.

**Related docs (each verified to exist):**
- [`consumer-onboarding.md`](consumer-onboarding.md) — per-consumer checklist (pilot → production → regulated).
- [`profile-adoption-guide.md`](profile-adoption-guide.md) — per-stack install commands and the profile decision tree.
- [`profile-compatibility.md`](profile-compatibility.md) — stack → profile mapping and the compatibility self-test.
- [`profile-driven-adoption.md`](profile-driven-adoption.md) — install/sync mechanics and safety.
- [`pilot-consumers.md`](pilot-consumers.md) — the cited first live consumer (`bogdaniel/zenchron-tools`).
- [`product-status.md`](product-status.md) — maturity source of truth.
- [`roadmap.md`](roadmap.md) — product roadmap (Phase 6 covers multi-project adoption).

---

## 202 — Multi-project rollout plan

Roll out in **waves**, each gated on evidence from the previous wave. This mirrors the phased
adoption in [`roadmap.md` Phase 6](roadmap.md#phase-6--multi-project-adoption) and the
single-consumer sequence in [`consumer-onboarding.md`](consumer-onboarding.md).

**Wave 0 — Pilot (one project).** Onboard a single low-stakes project in `report-only` and capture
its evidence (workflow run id + security summary). This is the reference baseline for everything
that follows — exactly what [`pilot-consumers.md`](pilot-consumers.md) established with
`zenchron-tools`. Do not start Wave 1 until the pilot runs clean in report-only.

**Wave 1 — Repeatable second/third project.** Reuse the pilot's pinned tool refs and triage
conventions. The goal of this wave is to prove onboarding is *repeatable*, not project-specific
(see [`consumer-onboarding.md` §204](consumer-onboarding.md#204--second-project-adoption)).

**Wave 2 — Production projects.** Apply to projects that ship to production, still starting in
`report-only`, promoting deliberately through `baseline` → `strict` behind the readiness
pre-flights ([`consumer-onboarding.md` §205](consumer-onboarding.md#205--production-project-adoption),
[`strict-mode-readiness.md`](strict-mode-readiness.md)).

**Wave 3 — Regulated / specialized projects.** Regulated, legacy, mixed-stack, and monorepo
projects, each with their onboarding considerations
([`consumer-onboarding.md`](consumer-onboarding.md) §§213–217).

**Cross-cutting throughout all waves:**
- **Pin tool refs once and reuse** across projects ([`pinned-tool-references.md`](pinned-tool-references.md))
  so every project's CI is reproducible and upgrades are deliberate.
- **Track per-project state** (profile, mode, run id, divergences) in a rollout tracker.
- **Sync deliberately.** When a newer Sentinel Shield ships, run `sync-baseline.sh` per project as a
  drift report first, then `--apply --force` — it never clobbers project-local risk decisions
  ([`profile-driven-adoption.md`](profile-driven-adoption.md)).
- **Watch aggregate CI budget** ([`ci-runtime-budget.md`](ci-runtime-budget.md)).

### Suggested rollout tracker columns

| Project | Stack | Profile | Mode | Pinned refs? | Last sync | Evidence (run id) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |

---

## 206 — Profile selection guidance

> **No selection CLI exists.** There is **no** auto-detect or "recommend a profile" command.
> Selection is a **deliberate human choice** expressed via the `--profile` flag to
> `install-baseline.sh`, guided by the decision tree and the compatibility table. Stated honestly so
> no one waits for tooling that does not ship.

To select a profile for a project:

1. **Determine what the repository actually ships** (application language(s), containers/IaC).
2. **Walk the decision tree** in
   [`profile-adoption-guide.md` §72](profile-adoption-guide.md#72--profile-selection-decision-tree)
   — it returns exactly one profile (or "single app profile + manual assets" when no combination
   manifest covers the mix).
3. **Cross-check the stack table** in
   [`profile-compatibility.md` §40](profile-compatibility.md#40-profile-compatibility-table)
   and the tool-list correctness notes
   ([`profile-compatibility.md`](profile-compatibility.md#tool-list-stack-correctness-notes-tasks-41-45)).
4. **Pass the result explicitly:** `install-baseline.sh --target <project> --profile <name>`.

Shipped profiles today (nine manifests: seven single-stack + two combinations):

| `--profile` | Use when the repo ships… |
| --- | --- |
| `laravel` | a Laravel application |
| `symfony` | a Symfony 6/7 application (app code in `src/`) |
| `php-library` | a plain PHP package, no framework (generic PHPStan) |
| `node` | a Node service only |
| `react` | a React (Vite) SPA only |
| `node-react` | Node + React in one repo (combination) |
| `docker` | containers/IaC **only**, no app language |
| `laravel-react-docker` | Laravel + React + Docker in one repo (default; `proven` install/sync) |

If no profile fits the repo's mix, install the closest **single app profile** and add the other
stack's assets manually — the decision tree states this explicitly. Other stacks (Go, Python, …) are
**not** covered by manifests yet ([`profile-driven-adoption.md`](profile-driven-adoption.md)).

---

## 207 — Profile-compatibility self-test (captain-owned)

A **profile-compatibility self-test exists** and is owned by the captain (engine/`self-test.sh`).
This Lane K doc does **not** modify it; it only records that it exists for rollout planning.

- The repository self-test asserts that **every shipped profile manifest validates** against
  [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json) — see the
  validation summary in
  [`profile-compatibility.md` §36](profile-compatibility.md#36-profile-manifest-validation-summary)
  and [`profile-adoption-guide.md` §61–62](profile-adoption-guide.md#6162--schema-validation-actually-run).
- Fixture coverage and round-trip checks are tracked in
  [`profile-compatibility.md`](profile-compatibility.md#fixture-coverage-tasks-31-35).
- **For rollout:** before a wave, a green engine self-test is your signal that the profiles you are
  about to install are structurally valid. Treat a self-test failure as a rollout blocker. The
  authoritative run lives with the captain's `scripts/self-test.sh`; this doc does not touch it.

---

## 220 — Roadmap (captain-owned)

The product **roadmap is captain-owned** and tracked in [`roadmap.md`](roadmap.md). Multi-project
adoption is its [Phase 6](roadmap.md#phase-6--multi-project-adoption). This doc intentionally does not
restate or own roadmap content — refer to [`roadmap.md`](roadmap.md) for forward-looking plans and to
[`product-status.md`](product-status.md) for current, evidence-backed maturity.
