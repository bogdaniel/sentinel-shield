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
- [x] `done` — **Branch-safe main-gate validation path** (`run-main-gate-validation.sh` + self-test
  `main-gate-harness`) — removes the `workflow_dispatch` blocker (v0.1.17).
- [ ] `partial` — Main-gate **live runs** still pending: harness enables them, but no scanner is
  `live-validated` yet (needs cited consumer runs — roadmap Phase 3).

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

## v0.1.25 — live evidence closure (status update)
- [x] `done` — **Real local scanner validations**: Checkov 3.3.0 (16 iac_violations), Grype 0.114.0 (1 medium), Deptrac 4.6.1 (2 violations) ran for real and were collector-parsed ([`live-evidence-v025.md`](live-evidence-v025.md)).
- [x] `done` — Real strict-mode engine run (baseline pass / strict fail on 3 gates).
- [x] `done` — **zap-full collector input gap CLOSED** (real code fix) + self-test.
- [x] `done` — **Code-enforced Nuclei template-path guard** (missing/traversal/remote/host) + self-test; `ss_dast_check` unchanged.
- [x] `done` — Supply-chain digests re-verified live (MATCH); install/sync consumer-safety + managed-file inventory (honest about no dirty-tree guard); consumer onboarding + multi-project rollout; workflow release-hardening (10 rules verified + 3 new self-tests).
- [x] `done` — Self-test 349 → **375** (`v025-live`).
- [ ] `blocked-external` — **Dependency-Check live validation**: real cold run **failed on NVD HTTP 429** (API key required); wrapper correctly reported unavailable (no fake-clean). **Attempted, NOT live-validated — proven blocked by external constraint.** Unblock: NVD API key.
- [ ] `not-reached` — **v1.0**: 5/7 hard gates met (outstanding: Dependency-Check live, strict-on-consumer).

## v0.1.24 — enterprise production closure (status update)
- [x] `done` — Complete 34-collector fixture library + `v024-collectors`/`v024-coverage`/`v024-docs` self-test suites.
- [x] `done` — Per-profile install/sync productization matrix + quickstart; profile adoption guides + mode/onboarding override examples.
- [x] `done` — Strict/regulated execution fixtures enforced (multi→strict fails/baseline passes; dast→regulated fails/strict passes; clean→all pass).
- [x] `done` — DAST (ZAP baseline/full incl. explicit-input gap test) + Nuclei + IaC (tf/k8s/compose) + Deptrac + architecture realism fixtures with tested collector mappings.
- [x] `done` — Supply-chain: 3 scanner digests re-verified live (MATCH); reproducibility/update/rollback docs.
- [x] `done` — Workflow hardening: every template upload guarded by `if: always()` (self-test enforced); adoption docs.
- [x] `done` — Doc maturity audit (0 contradictions); stray cruft tags + 6 broken links fixed.
- [x] `done` — `v1-closure-v024.md` (thresholds, graduation ladder, governance).
- [ ] `blocked` — **Dependency-Check live validation**: real run **attempted** (evidence workflow pushed to a non-default consumer branch; dispatch blocked by default-branch-only rule); no artifact. **Still attempted, NOT live-validated** — chief v1.0 blocker.
- [ ] `not-reached` — **v1.0**: explicitly NOT reached.

## v0.1.23 — enterprise readiness burn-down (status update)
- [x] `done` — v1.0 readiness definition ([`v1-readiness.md`](v1-readiness.md)) + product contract.
- [x] `done` — Strict/regulated gate-promotion policy + 24-gate readiness matrix (enforced by `self-test v023-coverage`).
- [x] `done` — Install/sync reliability (audit/rollback/troubleshooting/checklist) + Symfony adoption fixture + profile-compatibility table.
- [x] `done` — Supply-chain reproducibility: 3 scanner digests re-verified live; no validated scanner pinned to `:latest` (self-test enforced).
- [x] `done` — DAST controlled-pilot readiness + approval template; fail-closed proven (missing target/non-http/host-mismatch) — **DAST still never enabled**.
- [x] `done` — IaC/Deptrac/architecture fixtures + readiness doc (collector mappings tested; remain `experimental`/only-if-configured).
- [ ] `blocked` — **Dependency-Check live validation**: real run **attempted** (gh auth + network OK) but the evidence workflow is not yet deployed on the consumer; no artifact. **Still attempted, NOT live-validated** — chief remaining blocker.
- [ ] `not-reached` — **v1.0**: explicitly NOT reached; see the outstanding list in `v1-readiness.md`.
</content>
