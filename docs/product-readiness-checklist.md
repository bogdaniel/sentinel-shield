# Product Readiness Checklist (v0.1.16)

Status legend: `done` · `partial` · `not started` · `blocked`. An item is `done` only with
evidence (a self-test suite, a cited consumer run, or a shipped artifact). No item is marked
`done` on intent alone.

## Core engine
- [x] `done` — Gate resolver (mode → fail-on flags), self-tested.
- [x] `done` — Gate enforcer (findings → pass/fail/error), self-tested (`negative`, `fallback`).
- [x] `done` — Summary builder (raw → contract) with self-check.
- [x] `done` — Fallback policy (fail-closed outside report-only), self-tested.
- [ ] `partial` — Finding-scoped suppression: implemented for `unsafe_docker` only; other count
  gates support broad `scope:gate` only.

## Profile install/sync
- [x] `done` — Manifest-driven installer, dry-run default, hard protections.
- [x] `done` — Non-destructive sync (drift report + managed-only update).
- [x] `done` — laravel-react-docker fixture round-trip (`self-test fixtures`).
- [ ] `partial` — Per-stack coverage: laravel/react/node/docker/php-library manifests exist;
  no `node-react` combination manifest (uses `react`); no Symfony/Go/Python install manifest.
- [ ] `not started` — `sync-managed-block` in-place updater (reserved; treated as manual today).

## Workflow templates
- [x] `done` — Six templates ship (pr-fast, main, scheduled, dast, ai-review, combined).
- [x] `done` — PR-fast live-validated on a consumer.
- [ ] `partial` — main/scheduled/combined are `template-only` (not executed by default).
- [x] `done` — Minimal `permissions:`; no `pull_request_target` (self-test `workflow-sanity`).
- [ ] `partial` — Action/image SHA pinning: self-test workflow pinned; consumer templates carry
  TODO refs to pin per [`pinned-tool-references.md`](pinned-tool-references.md).

## Raw report contracts
- [x] `done` — `security-summary.json` JSON Schema + example + docs.
- [x] `done` — Clean raw examples in `templates/raw/` for every wired tool.
- [x] `done` — Collector contract: missing artifact → `unavailable` (0), invalid JSON → exit 2.

## Scanner maturity
- [x] `done` — Single canonical maturity table in [`product-status.md`](product-status.md).
- [x] `done` — Core PR-fast scanners `proven` (zenchron run 27170148123).
- [ ] `partial` — Main-gate scanners `experimental`; severity parsing coarse for OSV/CodeQL.
- [ ] `blocked` — Main-gate live validation blocked on a dispatchable strategy (roadmap Phase 3).

## Accepted-risk governance
- [x] `done` — Schema, approval/expiry/owner enforcement, never-suppressible gates.
- [x] `done` — Finding-scoped suppression for `unsafe_docker` (self-test `finding-scope`).
- [ ] `partial` — Components/fingerprints reserved in schema, not enforced.

## Release process
- [x] `done` — Documented release gate ([`sentinel-shield-release-process.md`](sentinel-shield-release-process.md)).
- [x] `done` — Blocking `full-self-test` job in `ci-self-test.yml`.
- [x] `done` — Tag immutability rule documented.
- [x] `done` — No unstable scanner runs in the engine's own release gate.

## Consumer onboarding
- [x] `done` — `profile-driven-adoption.md` + example integration package.
- [x] `done` — Reference example (`examples/laravel-react-docker/`).
- [ ] `partial` — Onboarding for non-PHP/JS stacks not solved.

## Documentation completeness
- [x] `done` — Documentation index ([`docs/README.md`](README.md)).
- [x] `done` — Product status, boundaries, pilot, roadmap, this checklist (v0.1.16).
- [ ] `partial` — Some per-tool severity tuning guidance is high-level only.

## Pinning / reproducibility
- [x] `done` — `pinned-tool-references.md` with resolved upstream SHAs.
- [x] `done` — Self-test workflow actions SHA-pinned.
- [ ] `partial` — Consumer workflow templates still carry version tags / TODO pins by default.

## Runtime budget
- [x] `done` — `ci-runtime-budget.md` documents PR-fast vs main vs nightly split.
- [ ] `partial` — Budgets are documented targets, not enforced limits; not measured on a consumer
  beyond the PR-fast run.

---

**Overall:** the **engine, install/sync, contract, and PR-fast gate are `done`/`proven`**. The
open frontier is **Phase 3 — live validation of main-gate tools**, currently `blocked` on a
dispatchable validation strategy. Do not read a `partial`/`blocked` item as production-ready.
</content>
