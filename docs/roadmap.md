# Roadmap (v0.1.16)

Organized around **product maturity**, not tool accumulation. Sentinel Shield will not add more
scanners until the existing matrix is live-validated. Each phase has a goal, required work, a
definition of done, and risks.

## Phase 1 — Core baseline engine
**Status: mostly complete (`proven`).**

- **Goal:** a deterministic, self-gated release-gate engine.
- **Required work:** resolver, enforcer, summary builder, select/fallback, accepted-risk
  suppression, self-test. *(Done.)* Remaining: broaden finding-scoped suppression beyond
  `unsafe_docker`.
- **Definition of done:** blocking self-test green on every push; engine scripts A-grade; contract
  schema stable. *(Met for the engine; finding-scope generalization is the only open item.)*
- **Risks:** schema churn breaking the contract; suppression logic gaps. Mitigated by `negative`
  and `finding-scope` self-tests.

## Phase 2 — Profile-driven adoption
**Status: partially complete / needs install-sync polish.**

- **Goal:** one-command, safe adoption for the common stacks.
- **Required work:** profile manifests + install/sync (done for laravel-react-docker, react, node,
  docker; php-library added v0.1.16). Remaining: a true `node-react` combination manifest,
  Symfony/Go/Python install manifests, and a `sync-managed-block` in-place updater (reserved today).
- **Definition of done:** each of {laravel-react-docker, node-react, docker-only, php-library}
  installs a thin consumer with a fixture round-trip in `self-test fixtures`.
- **Risks:** sync clobbering project-local decisions. Mitigated by hard protections + dry-run default.

## Phase 3 — Live validation of main-gate tools
**Status: in progress — branch-safe harness delivered (v0.1.17); live runs pending.**

- **Goal:** promote main-gate scanners from `experimental` to `proven`.
- **Delivered (v0.1.17):** the dispatch blocker is solved by a Sentinel-Shield-owned harness,
  `scripts/run-main-gate-validation.sh`, which runs the main-gate wrappers from any branch/PR (no
  `workflow_dispatch`, no merge-first) and emits the same `reports/raw/*` contracts. See
  [`main-gate-validation-strategy.md`](main-gate-validation-strategy.md).
- **Remaining work:** run CodeQL, OSV, Grype, Dependency-Check, Trivy, Syft, IaC on a real consumer
  via the harness; refine OSV/CodeQL severity parsing; pin digests; record cited evidence in
  [`pilot-consumers.md`](pilot-consumers.md). **The harness existing is not live validation.**
- **Definition of done:** each main-gate tool has a cited consumer run with raw→summary-key
  evidence and a pinned ref; severities reviewed.
- **Risks:** coarse severity → false gates; long runtimes blowing the CI budget
  ([`ci-runtime-budget.md`](ci-runtime-budget.md)). Run advisory first.

## Phase 4 — Controlled DAST pilot
**Status: manual / future.**

- **Goal:** a documented, safe DAST run against a staging target.
- **Required work:** complete `dast-scan-approval.md` + `nuclei-target-allowlist.md` for a real
  staging host; run `sentinel-shield-dast.yml` with target + allowlist; record findings handling.
- **Definition of done:** one approved ZAP baseline run on staging with the fail-closed guard
  demonstrated (host mismatch → fail) and findings triaged. **Stays `manual`** — never a default gate.
- **Risks:** scanning the wrong target. Mitigated by the allowlist guard (fail-closed).

## Phase 5 — Strict-mode readiness
**Status: future.**

- **Goal:** a consumer running green in `strict` with no `report-only` escape hatches.
- **Required work:** burn down baseline debt; configure Psalm/Deptrac/ESLint on a consumer to
  promote them; enable style/IaC/container gates; full digest pinning.
- **Definition of done:** a consumer passes `strict` with all enabled gates `proven` and a clean
  accepted-risk register.
- **Risks:** strict gates blocking delivery before debt is controlled. Mitigated by the staged
  report-only → baseline → strict path.

## Phase 6 — Multi-project adoption
**Status: future.**

- **Goal:** repeatable adoption across ≥3 projects of different stacks.
- **Required work:** Phases 2–5 generalized; per-stack onboarding manifests; a documented
  promotion ledger; versioned sync across consumers.
- **Definition of done:** ≥3 consumers on pinned Sentinel Shield refs, each with cited evidence;
  `supported` tools promoted to `proven` by at least one consumer.
- **Risks:** drift between consumers and upstream. Mitigated by `sync-baseline.sh` + pinned refs.

---

**Guiding constraint:** no new scanners, no weakened gates, no claimed maturity without cited
evidence. Breadth is frozen until depth (live validation) catches up.
</content>

## v0.1.18 — main-gate promotions
CodeQL, OSV-Scanner, Trivy-fs, Syft SBOM promoted to live-validated (zenchron run 27214865086).
Next: Grype/Dependency-Check/Dockle via container on a consumer; Deptrac on a layered project;
IaC scanners on a repo with `*.tf`. Semgrep image bumped to 1.165.0 (configurable).

## v0.1.20–0.1.22 — execution depth + adoption closure
- v0.1.20: Grype + Dockle live-validated; Semgrep 1.165.0 consumer-verified (run 27239206382).
- v0.1.21: Dependency-Check nightly/cached strategy + scanner digest pinning (real digests).
- v0.1.22: dependency-check **evidence workflow** (path to first artifact); `symfony`/`node-react`
  manifests + recommended tool lists; strict/regulated readiness guides; product contract; workflow
  hardening (if:always uploads, digest overrides); self-test grown to 271 checks.
- **Still open:** the single biggest gap is **Dependency-Check live validation** — run the evidence
  workflow on a consumer with a warm NVD cache and cite the artifact in `main-gate-live-evidence.md`.
  Then: Deptrac on a layered project; IaC scanners on a repo with `*.tf`; refine OSV/CodeQL severity.

## v0.1.23 — enterprise readiness burn-down
Blocker burn-down + evidence prep (no promotions): Dependency-Check live run **attempted** (blocked:
evidence workflow not deployed on consumer); Symfony adoption fixture; gate-promotion policy +
readiness matrix with enforced mode fixtures; DAST controlled-pilot prep (still fail-closed/never
enabled); IaC/deptrac/architecture fixtures; supply-chain reproducibility (digests re-verified);
[`v1-readiness.md`](v1-readiness.md) defining the path to v1.0 (NOT reached). Self-test 271→312.
- **Top of the next backlog:** deploy `sentinel-shield-dependency-check.yml` on a consumer, warm the
  NVD cache, and capture the first real `dependency-check.json` → promote to live-validated (v0.1.24).
