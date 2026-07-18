# Consumer Onboarding (v0.1.25)

A practical, sequenced checklist for adopting Sentinel Shield in a **consuming project** —
from the first pilot through to a regulated, production project. This guide is **task-facing**:
it orders the work and points at the authoritative mechanics rather than re-stating them.

> **Honesty / maturity.** The install/sync engine and the PR-fast gate are `proven`; most
> non-core scanner integrations are `supported`/`experimental`; DAST is `manual` and AI review is
> `non-gating`. The **single source of truth for maturity is**
> [`product-status.md`](product-status.md) — where any label here and that file disagree,
> `product-status.md` wins. **This is not a v1.0 product** and makes no v1.0 claim. Always adopt
> in `report-only` first.

**Related docs (each verified to exist):**
- [`profile-adoption-guide.md`](profile-adoption-guide.md) — per-stack install commands, decision tree, mode tightening.
- [`profile-compatibility.md`](profile-compatibility.md) — stack → profile mapping and tool-list correctness.
- [`profile-driven-adoption.md`](profile-driven-adoption.md) — install/sync mechanics, file modes, `never_touch` safety.
- [`multi-project-rollout.md`](multi-project-rollout.md) — rolling Sentinel Shield across many projects; profile selection guidance.
- [`install-sync-guide.md`](install-sync-guide.md) — install/sync productization, rollback, troubleshooting.
- [`adoption-guide.md`](adoption-guide.md) — the five mode phases (report-only → baseline → strict → regulated).
- [`product-status.md`](product-status.md) — maturity source of truth.
- [`architecture-governance.md`](architecture-governance.md) — architecture evidence contract, producers, policy file, style templates.
- [`pilot-consumers.md`](pilot-consumers.md) — the cited live consumer (`bogdaniel/zenchron-tools`) and what it did / did not prove.

---

## 201 — Consumer onboarding checklist

Run top-to-bottom for any single project. Each step links to the authoritative source.

1. **Confirm the stack and pick a profile.** Use the decision tree in
   [`profile-adoption-guide.md` §72](profile-adoption-guide.md#72--profile-selection-decision-tree)
   and the stack table in [`profile-compatibility.md` §40](profile-compatibility.md#40-profile-compatibility-table).
   Pick the smallest profile that covers what the repo actually ships.
2. **Dry-run the install.** `install-baseline.sh --target <project> --profile <name>` (dry-run is
   the default — it writes nothing). Read the planned file list. Mechanics:
   [`profile-driven-adoption.md`](profile-driven-adoption.md).
3. **Apply in `report-only`.** Add `--apply --mode report-only`. Nothing blocks CI yet.
4. **Pin tool references.** Pin scanner images/actions by digest — see
   [`pinned-tool-references.md`](pinned-tool-references.md).
5. **Fill project metadata.** Complete `.sentinel-shield/profile.yaml` and copy any `manual`-mode
   config files the installer printed (per-stack notes below).
6. **Open a `report-only` PR.** Confirm the PR-fast gate runs and produces a security summary
   without failing the build (the PR-fast gate is `proven`).
7. **Triage the baseline.** Record existing findings as accepted risk where justified
   (`.sentinel-shield/accepted-risks.json`; see [`accepted-risk-suppression.md`](accepted-risk-suppression.md)
   and [`exception-policy.md`](exception-policy.md)). This file is **never** touched by install/sync.
8. **Promote to `baseline`.** Once new code stops adding risk, flip the mode so new findings
   gate but the existing baseline does not (see [Baseline promotion (219)](#219--baseline-promotion)).
9. **Plan the path to strict/regulated** only after the pre-flights
   ([`strict-mode-readiness.md`](strict-mode-readiness.md), [`regulated-mode-readiness.md`](regulated-mode-readiness.md)).
   Keep DAST manual and AI review non-gating.
10. **Schedule sync.** Track template updates with `sync-baseline.sh` (drift report first).

---

## 203 — First-project pilot guide

The first project is a **learning pilot**, not a production rollout. Goal: prove the engine runs
in *your* CI and learn your baseline — not to block anything.

- **Choose a low-stakes repo** with an active CI and a stack that has a shipped profile
  ([`profile-compatibility.md` §40](profile-compatibility.md#40-profile-compatibility-table)).
- **Install in `report-only` only.** Do the steps in [201](#201--consumer-onboarding-checklist)
  through step 7. Do **not** promote to `baseline` on the first PR.
- **Expect a noisy first run.** `experimental` scanners (OSV/CodeQL/Grype severity, container
  scanners) produce coarse severities — treat them as review prompts, not verdicts
  ([`product-status.md` §3](product-status.md#3-current-maturity-by-area)).
- **Capture evidence.** Record the workflow run id and the security summary; this is your
  reference point for every later project (mirrors what [`pilot-consumers.md`](pilot-consumers.md)
  did for `zenchron-tools`).
- **Exit criteria:** PR-fast gate runs green in `report-only`, baseline triaged, tool refs pinned.

---

## 204 — Second-project adoption

The second project is where onboarding becomes **repeatable**. Reuse the pilot's learnings.

- **Reuse the pinned tool refs and triage conventions** from the pilot; don't re-derive them.
- **Pick the profile from the table**, not from memory — the second project may be a different
  stack ([`profile-compatibility.md` §40](profile-compatibility.md#40-profile-compatibility-table)).
- **Shorten the report-only window.** With a known-good baseline process you can move
  report-only → baseline faster than on the pilot.
- **Note divergences.** Anything that differs from the pilot (extra `never_touch` paths, manual
  config) belongs in your rollout tracker — feed it into [`multi-project-rollout.md`](multi-project-rollout.md).

---

## 205 — Production project adoption

Adopting on a project that ships to production. Higher bar; no shortcuts on the pre-flights.

- **Start in `report-only` even here.** Production projects are exactly where a surprise gate
  failure is most expensive — get a clean baseline first.
- **Promote deliberately:** report-only → baseline (new-code gating) → strict only after the
  [`strict-mode-readiness.md`](strict-mode-readiness.md) pre-flight passes.
- **Pin everything by digest** ([`pinned-tool-references.md`](pinned-tool-references.md)) so CI is
  reproducible; production gates must not drift with upstream tool releases.
- **Wire the main-branch gate** with eyes open: it is `supported` (partial) — CodeQL/OSV/Trivy-fs/
  Syft are live-validated, but Grype/Dependency-Check/Dockle/Deptrac/IaC are not yet
  ([`product-status.md` §3](product-status.md#3-current-maturity-by-area)). Treat their output as
  advisory until you have your own evidence.
- **Keep DAST manual and AI review non-gating** ([`dast-policy.md`](dast-policy.md),
  [`ai-review-policy.md`](ai-review-policy.md)).

---

## 208–212 — Per-stack onboarding pointers

These do **not** re-write the per-stack install steps — they link the existing, authoritative
sections in [`profile-adoption-guide.md`](profile-adoption-guide.md). Each section there gives the
install command, what gets created, recommended tools, and manual steps.

| # | Stack | Profile (`--profile`) | Authoritative section |
| --- | --- | --- | --- |
| 208 | Laravel | `laravel` | [`profile-adoption-guide.md` §68](profile-adoption-guide.md#68--laravel---profile-laravel) |
| 209 | Symfony | `symfony` | [`profile-adoption-guide.md` §67](profile-adoption-guide.md#67--symfony---profile-symfony) |
| 210 | Node + React | `node-react` | [`profile-adoption-guide.md` §69](profile-adoption-guide.md#69--node--react---profile-node-react) |
| 211 | Docker-only | `docker` | [`profile-adoption-guide.md` §70](profile-adoption-guide.md#70--docker-only---profile-docker) |
| 212 | PHP library | `php-library` | [`profile-adoption-guide.md` §71](profile-adoption-guide.md#71--php-library---profile-php-library) |

Notes that matter at onboarding time (full detail in the linked sections):
- **Symfony / PHP library**: PHPStan/Psalm/Deptrac/style configs are `manual` mode — the installer
  prints them; copy and tune them yourself. PHP library uses **generic** PHPStan, not Larastan.
- **Laravel**: `phpstan.neon` / `phpstan-baseline.neon` are project-local and **never** overwritten.
- **Node + React**: `tsconfig`/`eslint` config stay project-local. For a pure service or pure SPA,
  use `--profile node` or `--profile react` instead.
- **Docker-only**: container-image scanners (Trivy-image/Checkov/Dockle) are `experimental` —
  severities are review prompts. If the repo also ships app code, **do not** use `docker` alone.

---

## 213 — Mixed-stack repositories

A repo that ships more than one application language (e.g. PHP API + React SPA) plus containers.

- **Prefer a combination profile when one exists.** Today only **`node-react`** and the default
  **`laravel-react-docker`** ship as combination manifests
  ([`profile-compatibility.md` §40](profile-compatibility.md#40-profile-compatibility-table)).
- **If no combination covers your mix**, install the closest **single app profile** now, then add
  the other stack's assets manually — the decision tree calls this out explicitly
  ([`profile-adoption-guide.md` §72](profile-adoption-guide.md#72--profile-selection-decision-tree)).
- **Verify tool-list correctness** for each stack against
  [`profile-compatibility.md`](profile-compatibility.md#tool-list-stack-correctness-notes-tasks-41-45)
  so you don't, e.g., run a PHP runner against a JS-only sub-tree.

---

## 214 — Tenant / multi-app repositories

One repository hosting several deployable apps (per-tenant builds, several services in one tree).

- **One gate, one mode per repo today.** The mode in `.sentinel-shield/profile.yaml` applies
  repo-wide; there is no per-subdirectory mode resolution. Choose the mode for the *most* sensitive
  app and accept it applies to all.
- **Scope scanners with `.semgrepignore`** and path filters so each tool only sees the code it
  should — this is the lever for keeping a multi-app repo's findings attributable.
- **Triage per app, record centrally.** Keep accepted-risk entries annotated by app/tenant in
  `.sentinel-shield/accepted-risks.json` (see [`accepted-risk-suppression.md`](accepted-risk-suppression.md)).
- This is an onboarding **consideration**, not a solved feature — flag any per-app gating need in
  your rollout tracker ([`multi-project-rollout.md`](multi-project-rollout.md)).

---

## 215 — Monorepo considerations

Closely related to 214; the emphasis is build/CI structure.

- **Match the workflow to how CI already splits the monorepo.** Sentinel Shield installs a single
  managed `.github/workflows/sentinel-shield.yml`; in a monorepo with per-package pipelines you may
  need to wire its gate steps into each package job rather than a top-level workflow.
- **Pin once, reuse everywhere.** Pin tool refs centrally ([`pinned-tool-references.md`](pinned-tool-references.md))
  so every package job uses identical, reproducible scanner versions.
- **Profile per package, not per repo,** when packages differ in stack — each package can be its
  own "consumer" using the [201 checklist](#201--consumer-onboarding-checklist).
- **Watch CI budget.** Many packages × deep scanners can blow the runtime budget; see
  [`ci-runtime-budget.md`](ci-runtime-budget.md).

---

## 216 — Legacy project adoption

Old codebases with a large pre-existing finding backlog.

- **`report-only` is mandatory here, and stay there longer.** The point is visibility without a wall
  of red — Phase 1 of [`adoption-guide.md`](adoption-guide.md#phase-1--visibility-report-only).
- **Baseline aggressively.** Record the existing backlog as accepted risk (with justification and,
  ideally, a remediation ticket) so the *baseline* mode gates only **new** findings
  ([Baseline promotion (219)](#219--baseline-promotion), [`exception-policy.md`](exception-policy.md)).
- **Do not chase strict mode early.** A legacy project may live in `baseline` indefinitely; that is
  a legitimate end state, not a failure.
- **Pin tool refs first** — legacy CI is the most likely to break on an upstream scanner bump.

---

## 217 — Regulated project adoption

Projects under a compliance regime (evidence, retention, segregation of duties).

- **Same sequence, higher evidence bar.** report-only → baseline → strict → `regulated`, with the
  `regulated`-mode evidence requirements in
  [`adoption-guide.md` Phase 5](adoption-guide.md#phase-5--regulated-mode-regulated) and the
  pre-flight in [`regulated-mode-readiness.md`](regulated-mode-readiness.md).
- **Run the regulated pre-flight before flipping the mode** — do not promote to `regulated` until it
  passes.
- **DAST stays `manual` and fail-closed; AI review stays `non-gating`** — neither is a compliance
  control on its own ([`dast-policy.md`](dast-policy.md), [`ai-review-policy.md`](ai-review-policy.md)).
- **Retain evidence.** Archive security summaries and workflow run ids per release; the engine
  produces the normalized `security-summary.json` contract you retain.

---

## 218 — Report-only-first rollout

The single most important onboarding rule, stated explicitly so no project skips it.

- **Every project, every stack, every maturity level installs in `--mode report-only` first.** The
  example profile shows this is the recommended first step
  ([`examples/profiles/76-report-only-onboarding.profile.yaml`](examples/profiles/76-report-only-onboarding.profile.yaml)).
- In `report-only`, scanners run and emit a security summary but **nothing blocks the release** — so
  you can observe true noise levels and triage without breaking CI.
- **Only after** a clean report-only run and a triaged baseline do you move to `baseline`. This is the
  hinge of the whole adoption path ([`adoption-guide.md`](adoption-guide.md)).

---

## 219 — Baseline promotion

Moving report-only → `baseline`, where **new** findings gate but the accepted existing baseline does
not.

1. **Triage the report-only output.** Everything you accept goes into
   `.sentinel-shield/accepted-risks.json` with justification
   ([`accepted-risk-suppression.md`](accepted-risk-suppression.md), [`exception-policy.md`](exception-policy.md)).
   That file is **never** modified by install/sync.
2. **Confirm new code has stopped adding risk** — i.e. recent PRs are clean in report-only.
3. **Flip the mode** in `.sentinel-shield/profile.yaml` to `baseline`
   (example: [`examples/profiles/77-baseline-onboarding.profile.yaml`](examples/profiles/77-baseline-onboarding.profile.yaml)).
   Mode + `fail_on` resolve to enforced thresholds via [`gate-resolution.md`](gate-resolution.md).
4. **Verify on a PR** that a *new* finding now fails the gate while the baseline does not.
5. **Then** consider strict/regulated, gated on the readiness pre-flights
   ([`strict-mode-readiness.md`](strict-mode-readiness.md), [`regulated-mode-readiness.md`](regulated-mode-readiness.md)).

---

## 220 — Adopting engineering quality gates (v2.1)

> **Unreleased, additive engine capability** — **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim (latest release remains `v2.0.1`). Adopt it the same report-only-first way as every
> other gate. Full reference: [`engineering-quality-gates.md`](engineering-quality-gates.md).

The engineering-quality gates (coverage, coverage regression, mutation, complexity, duplication, dead
code) live in a **separate counter channel** from security and default to **non-blocking** in
`report-only`/`baseline`, so they are safe to turn on early for visibility.

1. **Copy the policy template.** Copy `templates/quality-policy.example.yaml` to
   `.sentinel-shield/quality-policy.yaml` and set realistic `line_min`/`branch_min` (and, if you use
   them, mutation/complexity/duplication thresholds). An absent file falls back to defaults; a malformed
   one fails closed (exit 2).
2. **Report-only first.** Wire the coverage runner (mandatory quality signal) — and any optional
   mutation/complexity/duplication/dead-code runners — and read the numbers in the enforcement report;
   nothing new blocks yet.
3. **Record a coverage baseline** so `coverage_regression` becomes meaningful.
4. **Promote to strict**, where coverage threshold/regression, complexity, and duplication block; add
   mutation + dead-code by moving to **regulated**. Quality gates are **not** accepted-risk-suppressible.

---

## 221 — Adopting architecture governance (v2.1)

> **Unreleased, additive engine capability** — **not** part of `v2.0.1`/`v2.0.0` and **not** a new
> release claim (latest release remains `v2.0.1`). Adopt it the same report-only-first way as every
> other gate. Full reference: [`architecture-governance.md`](architecture-governance.md).

Sentinel Shield enforces architecture governance through normalized architecture evidence. Deptrac is
the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are JS/TS producers.
Custom architecture tests can also emit the same contract. Per profile: `laravel` / `symfony` /
`php-library` get **deptrac** (recommended) plus optional **php-arkitect** and **php-architecture-tests**;
`node` / `react` get **dependency-cruiser** and **eslint-boundaries** (both recommended) plus optional
**js-architecture-tests**. dependency-cruiser and ESLint boundaries are fast enough to run on PRs.

> **Evidence honesty.** Architecture governance is supported by engine tests and fixtures. Do not
> claim real consumer proof until a real Laravel/Symfony/Node consumer validation exists. Architecture
> tools detect dependency-boundary violations, not the quality of domain modeling itself. Sentinel
> Shield does **not** prove Clean Architecture by itself, does **not** prove DDD correctness, does
> **not** replace architectural review, and Deptrac does **not** validate BDD/TDD/ATDD.

The adoption ramp:

1. **Report-only / baseline — add a producer + config, observe the count.** Copy
   `templates/architecture-policy.example.yaml` to `.sentinel-shield/architecture-policy.yaml` and
   enable the producers for your stack. Starting points for the rule files live under
   `templates/architecture/` (clean-architecture, hexagonal, ddd-bounded-contexts, modular-monolith,
   node-clean-architecture, node-ddd-bounded-contexts, react-feature-boundaries) — each is marked
   *"Template only. Adapt to your namespaces/folders. Do not enable as blocking until observed clean."*
   Sentinel Shield **never** overwrites project-owned architecture files. Read
   `architecture_violations` (summed across all producers) and the informational
   `architecture_rule_count` / `architecture_tool_count` / `architecture_context_count`. In `baseline`,
   violations from evidence that exists block; absent evidence does not block yet.
2. **Fix or accept what it finds.** Tune the rules to your real namespaces/folders, fix the crossings
   worth fixing, and keep the count stable and visible before tightening.
3. **Strict — missing evidence starts blocking.** `missing_architecture_evidence` turns on
   (`SENTINEL_SHIELD_FAIL_ON_MISSING_ARCHITECTURE_EVIDENCE`): an applicable producer that is absent,
   `unavailable` or errored now fails. Opt out honestly with `architecture.enabled: false` or
   `architecture.evidence_required: false` rather than faking a pass. An absent policy file is fine —
   defaults apply; a malformed one fails closed. Pre-flight:
   [`strict-mode-readiness.md`](strict-mode-readiness.md).
4. **Regulated — retain the raw architecture reports** (`reports/raw/*.json` per producer) with the
   release evidence. Pre-flight: [`regulated-mode-readiness.md`](regulated-mode-readiness.md).

---

## Where this fits

This checklist covers a **single consumer**. To roll Sentinel Shield across **many** projects —
sequencing, profile selection at scale, and the compatibility self-test — see
[`multi-project-rollout.md`](multi-project-rollout.md). The product roadmap is tracked separately in
[`roadmap.md`](roadmap.md).
