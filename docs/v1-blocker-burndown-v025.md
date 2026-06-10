# v1.0 Blocker Burn-Down (v0.1.25)

This is the **v0.1.25 blocker burn-down** layered on top of [`v1-readiness.md`](v1-readiness.md)
(the authoritative `v1.0` definition — its §1 "what `v1.0` means", §2 minimum capabilities, §16
blocker list) and the [`v1-closure-v024.md`](v1-closure-v024.md) addendum (the v0.1.24 thresholds
and graduation ladder). It does **not** redefine `v1.0`. It records, for the v0.1.25 sprint: the
current blocker table, what closed in v0.1.24, what was **targeted** in v0.1.25 (including the
**real local scanner runs** this sprint), the hard/soft `v1.0` gates, the minimum-bar thresholds,
an honest readiness **score**, and a risk register.

> Every maturity claim here defers to [`product-status.md`](product-status.md) (single source of
> truth for maturity). Live-validation claims defer to
> [`main-gate-live-evidence.md`](main-gate-live-evidence.md). Interface-stability promises build on
> [`product-contract.md`](product-contract.md) and do not duplicate it. Maturity-ordered plan:
> [`roadmap.md`](roadmap.md). The captain owns [`v1-readiness.md`](v1-readiness.md),
> [`v1-closure-v024.md`](v1-closure-v024.md), and [`roadmap.md`](roadmap.md); this burn-down edits
> none of them.

---

```
╔════════════════════════════════════════════════════════════════════════════╗
║                       v1.0 STATUS: NOT REACHED                               ║
║                                                                              ║
║  Sentinel Shield remains PRE-1.0 as of v0.1.25. The engine, PR-fast gate,    ║
║  and the main-gate core (CodeQL/OSV/Trivy-fs/Syft/Grype/Dockle) are proven   ║
║  on a real consumer; the v1.0 frontier is NOT closed. Do NOT read this doc   ║
║  as a v1.0 declaration.                                                      ║
║                                                                              ║
║  CHIEF BLOCKER: OWASP Dependency-Check live validation.                      ║
║   v0.1.25 ran Dependency-Check for real (cold, LOCAL) — it FAILED on an      ║
║   NVD HTTP 429 (rate-limit / API key required). The wrapper correctly        ║
║   reported UNAVAILABLE (no fake-clean). Dependency-Check is therefore        ║
║   PROVEN-BLOCKED-BY-EXTERNAL-CONSTRAINT (NVD-429), still NOT live-validated:  ║
║   no real dependency-check.json artifact exists.                            ║
╚════════════════════════════════════════════════════════════════════════════╝
```

---

## 261. v1.0 blocker table (current, v0.1.25)

Cross-referenced from [`v1-readiness.md`](v1-readiness.md) §2/§16 and
[`v1-closure-v024.md`](v1-closure-v024.md) §222. Status vocabulary: **OPEN** (not met),
**PARTIAL** (minimum met, stretch open), **MET**.

| # | Blocker | Status | v0.1.25 note |
| --- | --- | --- | --- |
| B1 | **OWASP Dependency-Check live validation — CHIEF BLOCKER** | **OPEN** | Real LOCAL cold run this sprint **FAILED with NVD HTTP 429** (rate-limit / API key required); wrapper [`scripts/collectors/dependency-check.sh`](../scripts/collectors/dependency-check.sh) correctly reported **unavailable** (no fake-clean). **Proven-blocked-by-external-constraint** — no real `dependency-check.json` exists. Path unchanged: warm-cache nightly evidence workflow on a consumer — [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md), [`templates/workflows/sentinel-shield-dependency-check.yml`](../templates/workflows/sentinel-shield-dependency-check.yml). |
| B2 | **Main-gate FULL live coverage** (beyond the core 6) | **PARTIAL** | Core 6 live-validated on consumer ([`main-gate-live-evidence.md`](main-gate-live-evidence.md)). **Checkov and Grype now LOCALLY tool-validated** this sprint (real artifacts — Checkov 3.3.0 / 16 `iac_violations`; Grype 0.114.0 / 1 medium — parsed by their collectors). **Local tool-validation is NOT live validation** (no cited consumer run). Deptrac / Trivy-image still unproven. |
| B3 | **Strict mode validated on ≥1 real consumer** | **OPEN** | No consumer has run green in `strict` with no `report-only` escape hatch. Pre-flight only — [`strict-mode-readiness.md`](strict-mode-readiness.md), [`regulated-mode-readiness.md`](regulated-mode-readiness.md). |
| B4 | **Install/sync proof beyond `laravel-react-docker`** | **PARTIAL** | Only `laravel-react-docker` has a full fixture round-trip (`proven`). Others (`react`, `node`, `docker`, `php-library`, `symfony`, `node-react`) are `supported` (manifest + dry-run, no round-trip). Minimum bar met; stretch open. |
| B5 | **Default-capable digest pinning across every shipped ref** | **PARTIAL** | Digests **resolved (not invented)** for Semgrep / Grype / Dockle; override env vars documented — [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md), [`pinned-tool-references.md`](pinned-tool-references.md). Not pinned by default; full coverage incomplete. |
| B6 | **DAST / IaC / architecture still experimental / manual** | **OPEN (by design)** | Bounded by product non-goals (§271/§274). DAST stays `manual`/fail-closed; IaC `experimental`; Deptrac `not-configured` in the pilot. v0.1.25 hardened the `zap-full` parse path and noted the Nuclei template-path guard (§263). |

**Net:** the chief blocker remains **B1 (Dependency-Check)**, now characterized more precisely as
**externally blocked (NVD-429)** rather than merely "attempted." B2/B3 are the next depth items;
B4/B5 are breadth/hardening; B6 is bounded by non-goals.

---

## 262. Blockers closed by v0.1.24 (docs / fixtures / tests — NOT live validation)

Per [`v1-closure-v024.md`](v1-closure-v024.md) §223 and [`CHANGELOG.md`](../CHANGELOG.md) `[0.1.24]`.
**No tool was promoted to live-validated in v0.1.24.** What closed was documentation, fixtures, and
tests:

- **`v1-closure-v024.md`** closure addendum (thresholds §224–§226, graduation ladder §235,
  governance §239) — a documentation/governance close, not a live-validation close.
- **34-collector fixture library** `tests/fixtures/collectors-v024/*` + INDEX.
- **Dep-check hardening fixtures** (high/critical/empty/malformed) + [`dependency-check-hardening.md`](dependency-check-hardening.md).
- **DAST fixtures** `tests/fixtures/dast/{zap-baseline,zap-full,nuclei}.json` + [`dast-zap-readiness.md`](dast-zap-readiness.md), [`nuclei-readiness.md`](nuclei-readiness.md).
- **IaC / Deptrac / architecture fixtures** `tests/fixtures/{iac-v024,deptrac-v024,architecture-v024}/*` + [`iac-scanner-realism.md`](iac-scanner-realism.md), [`architecture-deptrac-realism.md`](architecture-deptrac-realism.md).
- **Self-test suites** `v024-collectors` / `v024-coverage` / `v024-docs`; `self-test all` PASS.

The v0.1.24 Dependency-Check **attempt** (evidence workflow pushed to a non-default consumer branch;
`workflow_dispatch` only registers on the default branch → no artifact) is recorded honestly in
[`dependency-check-live-evidence-v024.md`](dependency-check-live-evidence-v024.md). It did **not**
promote anything.

---

## 263. Blockers TARGETED by v0.1.25 (real local scanner validations + DAST hardening)

This sprint's concrete, honest work. **None of these promote a tool to live-validated** (that still
requires a cited real **consumer** run per [`v1-readiness.md`](v1-readiness.md) §15) — but the local
runs are **real tool executions producing real artifacts**, a step above fixtures.

| Item (v0.1.25) | Category | What is REAL | What it is NOT |
| --- | --- | --- | --- |
| **Checkov real LOCAL run** | tool-validation | Checkov **3.3.0** executed locally; produced a real report parsed by [`scripts/audits/checkov.sh`](../scripts/audits/checkov.sh) → **16 `iac_violations`** | not a cited consumer run → **not live-validated**; IaC remains `experimental` |
| **Grype real LOCAL run** | tool-validation | Grype **0.114.0** executed locally; produced a real report parsed by [`scripts/audits/grype.sh`](../scripts/audits/grype.sh) → **1 medium** | Grype is already `proven` on consumer (run 27239206382); the local run is corroborating, not the promotion source |
| **Dependency-Check real LOCAL cold run** | negative evidence | Real cold run **FAILED with NVD HTTP 429** (rate-limit / API key required); [`scripts/collectors/dependency-check.sh`](../scripts/collectors/dependency-check.sh) correctly reported **unavailable** (exit 0, no fake-clean) | proves the wrapper's fail-closed behavior; does **not** produce a `dependency-check.json` → B1 stays **OPEN**, now **externally blocked (NVD-429)** |
| **`zap-full` parse-path fix** | tests | `self-test all` now exercises `zap-FULL via explicit --input -> dast_findings=2`; DAST collector handles full-scan output | DAST stays `manual`/fail-closed; never enabled as a gate |
| **Nuclei template-path guard** | tests | `nuclei fixture -> dast_findings=1 (info excluded)` exercised; template-path guard noted | DAST stays `manual`; guard is a hardening note, not a promotion |

**Honest framing of the local runs:** a tool that runs locally and is parsed by its collector is
**locally tool-validated** — strictly stronger than a fixture (real binary, real output), strictly
weaker than **live-validated** (which requires a cited real consumer-CI run + downloaded artifact).
The graduation ladder ([`v1-readiness.md`](v1-readiness.md) §14–§15) is unchanged: **local runs do
not promote maturity in [`product-status.md`](product-status.md).**

---

## 264. Hard v1.0 release gates (MUST all be MET to declare v1.0)

These are the **blocking** gates. `v1.0` is declared only when **every** row is MET with cited
evidence. Per [`v1-readiness.md`](v1-readiness.md) §2.

| HG | Hard gate | Met? |
| --- | --- | --- |
| HG1 | Gate engine proven (resolver / enforcer / summary-builder / select deterministic; blocking self-test green) | **MET** |
| HG2 | PR-fast gate live-validated on a real consumer (zenchron run 27170148123, baseline PASS) | **MET** |
| HG3 | Main-gate core (CodeQL / OSV / Trivy-fs / Syft / Grype / Dockle) live-validated with cited consumer artifacts (runs 27214865086 + 27239206382) | **MET** |
| HG4 | **OWASP Dependency-Check live-validated** (real cited `dependency-check.json` parsed by its collector) | **NOT MET — CHIEF BLOCKER (B1); externally blocked by NVD-429** |
| HG5 | Strict mode validated green on ≥1 real consumer (no `report-only` escape hatch) | **NOT MET (B3)** |
| HG6 | Self-test green at/above floor (≥300 PASS, 0 failures) covering every STABLE surface + every promoted tool | **MET — 349 PASS, `self-test all`: PASS (verified this sprint)** |
| HG7 | ≥1 install path `proven` (full fixture round-trip) AND every shipped manifest ≥ `supported` | **MET** (`laravel-react-docker` proven; all shipped manifests ≥ supported) |

**Hard gates met: 5 / 7.** Outstanding: **HG4** (chief, externally blocked) and **HG5** (strict on a
consumer).

---

## 265. Soft v1.0 recommendations (SHOULD; non-blocking)

Strongly recommended for a confident `v1.0`, but not strictly blocking the declaration:

- **SR1 — Install/sync stretch:** full fixture round-trips for the four representative paths
  `{laravel-react-docker, node-react, docker-only, php-library}` (B4 stretch).
- **SR2 — Default-capable digest pinning** across **every** shipped scanner image/action, with a
  decided default-vs-override posture (B5).
- **SR3 — Refine coarse severity** for CodeQL / OSV (currently best-effort buckets).
- **SR4 — Main-gate breadth:** Deptrac on a layered project, IaC scanners on a repo with `*.tf`/k8s,
  Trivy-image against a built image (B2 — below the `v1.0` live-evidence bar, tracked in
  [`roadmap.md`](roadmap.md)).
- **SR5 — Controlled DAST pilot** (stays `manual`; a roadmap item, never a default gate).

---

## 266. Minimum live-validated tools

Per [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (source of truth for "what is
live-validated") and [`v1-closure-v024.md`](v1-closure-v024.md) §226.

- **Required for v1.0 and MET (live-validated on consumer):** Engine + PR-fast gate; **CodeQL,
  OSV-Scanner, Trivy-fs, Syft, Grype, Dockle** (runs 27214865086 + 27239206382).
- **Required for v1.0 and NOT MET:** **OWASP Dependency-Check** — the single remaining required tool
  (B1 / HG4); externally blocked by NVD-429.
- **v0.1.25 LOCAL tool-validation (NOT live-validation):** **Checkov** (3.3.0, 16 `iac_violations`)
  and **Grype** (0.114.0, 1 medium) ran locally and were parsed by their collectors. Grype is
  already `proven` on consumer; Checkov remains `experimental` (local run does not promote).
- **Dependency-Check posture:** **proven-blocked-by-external-constraint (NVD-429)**, still **NOT
  live-validated** — no real artifact exists.
- **Below the bar (NOT required for v1.0):** Deptrac, Conftest/Terrascan, Trivy-image — graduate via
  the §235 ladder with cited evidence. DAST stays `manual` by design.

**Minimum live-validated count for v1.0:** engine + PR-fast + 6 main-gate core + Dependency-Check =
**8 of 9 met** (Dependency-Check outstanding).

---

## 267. Minimum profiles

Per [`v1-readiness.md`](v1-readiness.md) §9 and [`v1-closure-v024.md`](v1-closure-v024.md) §225.

- **Minimum bar (MET):** **≥1 install path `proven`** (full fixture round-trip) AND **every shipped
  manifest ≥ `supported`**. `laravel-react-docker` is the proven path; `react`, `node`, `docker`,
  `php-library`, `symfony`, `node-react` are `supported` (manifest + dry-run, honor `never_touch`).
- **Stretch bar (OPEN, = B4):** the four representative paths
  `{laravel-react-docker, node-react, docker-only, php-library}` each `proven`.
- **Scope honesty:** install manifests exist only for the stacks above; **no general onboarding for
  arbitrary stacks** — a coverage limit, not a contract weakness.

---

## 268. Minimum self-test checks

Per [`v1-closure-v024.md`](v1-closure-v024.md) §224.

- **Floor:** `self-test all` **≥ 300 PASS** AND **0 failures**, covering every STABLE surface and
  every promoted (live-validated) tool with deterministic fixtures.
- **Current (verified this sprint):** **349 PASS checks, `self-test all`: PASS.** Above the floor.
  (History: 271 @ v0.1.22 → 312 @ v0.1.23 / v0.1.24 → **349 @ v0.1.25.**)
- **Rule:** the count may only grow or hold; a release that lowers it without a CHANGELOG
  breaking-change note is a regression that blocks a tag.

---

## 269. Docs completeness

Per [`v1-closure-v024.md`](v1-closure-v024.md) §238. For `v1.0` the set must (and as of v0.1.25 does,
for the proven surfaces) include — **completeness rule:** every STABLE surface and every promoted
tool documented; every "NOT live-validated" / experimental state stated honestly with a path to
close:

- **Contract & maturity:** [`product-contract.md`](product-contract.md),
  [`product-status.md`](product-status.md), [`v1-readiness.md`](v1-readiness.md),
  [`v1-closure-v024.md`](v1-closure-v024.md), this burn-down.
- **Evidence:** [`main-gate-live-evidence.md`](main-gate-live-evidence.md),
  [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md),
  [`dependency-check-live-evidence-v024.md`](dependency-check-live-evidence-v024.md).
- **Adoption / governance / plan:** [`gate-promotion-policy.md`](gate-promotion-policy.md),
  [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md),
  [`pinned-tool-references.md`](pinned-tool-references.md),
  [`strict-mode-readiness.md`](strict-mode-readiness.md),
  [`regulated-mode-readiness.md`](regulated-mode-readiness.md), [`roadmap.md`](roadmap.md).

**Status: MET** for the proven surfaces; the chief gap (B1) is documented honestly, not hidden.

---

## 270. Install / sync threshold

Per [`v1-closure-v024.md`](v1-closure-v024.md) §225 and [`v1-readiness.md`](v1-readiness.md) §13.

- **Threshold:** install/sync is **dry-run-by-default**; `--apply` writes; project-local
  `never_touch` files (e.g. `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`,
  `phpstan.neon`) are **never** created/overwritten, regardless of `--force`. ≥1 manifest must have
  a full fixture round-trip in `self-test` (`install-sync` / `fixtures`).
- **Current:** **MET** at minimum — `laravel-react-docker` round-trip proven, all shipped manifests
  dry-run-validated. **Stretch (B4) OPEN.**

---

## 271. DAST non-goal / minimum

Per [`v1-readiness.md`](v1-readiness.md) §3, [`dast-policy.md`](dast-policy.md),
[`dast-zap-readiness.md`](dast-zap-readiness.md), [`nuclei-readiness.md`](nuclei-readiness.md).

- **Non-goal:** Sentinel Shield is **not a DAST platform.** DAST (ZAP / Nuclei) stays `manual`,
  allowlisted, fail-closed — **never a default gate**, never blocks a release by default.
- **v1.0 minimum:** DAST is **not** a `v1.0` gating feature. The minimum is that the DAST collector
  parses fixtures correctly and the workflow is fail-closed/allowlisted. v0.1.25 hardened the
  `zap-full` parse path and the Nuclei template-path guard (§263); a controlled DAST pilot remains a
  roadmap item, not a gate.

---

## 272. AI non-goal / minimum

Per [`v1-readiness.md`](v1-readiness.md) §3 and [`product-status.md`](product-status.md).

- **Non-goal:** Sentinel Shield is **not AI-gated.** AI review stays `non-gating` / advisory; it
  **never blocks a release by default.**
- **v1.0 minimum:** the `workflow-sanity` self-test invariant that **AI review is non-gating** holds;
  no AI surface is a `v1.0` gate. AI is advisory commentary only.

---

## 273. Strict-mode requirement

Per [`v1-readiness.md`](v1-readiness.md) §2 (cap. 7), [`strict-mode-readiness.md`](strict-mode-readiness.md),
[`regulated-mode-readiness.md`](regulated-mode-readiness.md).

- **Requirement (HG5 / B3):** ≥1 real consumer runs **green in `strict`** with no `report-only`
  escape hatch and a clean accepted-risk register.
- **Current:** **NOT MET.** The mode pre-flight is defined; no consumer has run green in `strict`
  yet. Path: burn down baseline debt on a consumer, enable the strict gate set, capture a cited green
  `strict` run.

---

## 274. Regulated non-goal

Per [`regulated-mode-readiness.md`](regulated-mode-readiness.md) and
[`v1-closure-v024.md`](v1-closure-v024.md) §227.

- **Non-goal:** `regulated` mode is the **strictest** adoption mode (adds release-evidence /
  never-suppressible gates on top of `strict`); it is **not** a compliance-certification product and
  does **not** itself bundle scanners or auto-remediate. Like `strict`, a green `regulated` run on a
  real consumer is **not** a separate `v1.0` hard gate beyond HG5 — it is a deeper adoption mode
  tracked in [`roadmap.md`](roadmap.md). Never-suppressible gates (secrets, expired exceptions,
  missing release evidence) stay never-suppressible.

---

## 275. Migration policy

Per [`v1-readiness.md`](v1-readiness.md) §7/§13 and [`product-contract.md`](product-contract.md) §5.

- **Pre-1.0 is additive** — minor tags may add summary keys, env vars, manifest fields, and
  collectors/runners without being breaking.
- **Breaking changes are announced in [`CHANGELOG.md`](../CHANGELOG.md)** (rename/removal of a STABLE
  surface, exit-code semantic change, or existing-key semantic change). Absence of a note ⇒ drop-in
  for STABLE surfaces.
- **Tags are immutable;** consumers pin `SENTINEL_SHIELD_REF` to a tag/SHA, never a moving branch.
- **Re-sync deliberately** with [`scripts/sync-baseline.sh`](../scripts/sync-baseline.sh) (dry-run
  first) when bumping; `never_touch` files are never created/overwritten.

---

## 276. Deprecation policy

Per [`v1-readiness.md`](v1-readiness.md) §8 and [`v1-closure-v024.md`](v1-closure-v024.md) §230.

- **Announce ahead** — a STABLE-surface deprecation is announced in [`CHANGELOG.md`](../CHANGELOG.md)
  **≥ N minor releases ahead** of removal (default **N = 2**).
- **Keep a deprecation table** (surface · replacement · first announcing release · earliest removal
  release).
- **Remove only at a major bump** — a deprecated STABLE surface is **not removed before `v1.0`**;
  post-1.0, removal lands only at a **major** version (semver).

---

## 277. v1.0 blocker checklist

- [x] HG1 — Gate engine proven (self-test green).
- [x] HG2 — PR-fast gate live-validated on a consumer.
- [x] HG3 — Main-gate core 6 live-validated (cited consumer artifacts).
- [ ] **HG4 — OWASP Dependency-Check live-validated — CHIEF BLOCKER (externally blocked: NVD-429).**
- [ ] HG5 — Strict mode green on ≥1 real consumer.
- [x] HG6 — Self-test ≥300 PASS / 0 failures (349 PASS this sprint).
- [x] HG7 — ≥1 install path proven; all shipped manifests ≥ supported.
- [ ] SR1 — Install/sync stretch (4 representative paths proven).
- [ ] SR2 — Default-capable digest pinning across every shipped ref.
- [ ] SR3 — Refine CodeQL/OSV coarse severity.
- [ ] SR4 — Main-gate breadth (Deptrac / IaC / Trivy-image live-validated).
- [ ] SR5 — Controlled DAST pilot (stays manual).

---

## 278. v1.0 readiness SCORE (honest)

**Hard gates: 5 / 7 met.** Outstanding: **HG4** (Dependency-Check live validation — chief, externally
blocked by NVD-429) and **HG5** (strict on a real consumer).

**Soft recommendations: 0 / 5 met** (SR1–SR5 all open; several are PARTIAL — digests resolved,
install minimum met).

**Overall: `v1.0` is NOT reached.** Meeting 5/7 hard gates is real progress (engine + PR-fast +
main-gate core + self-test + install minimum are all proven), but the two remaining hard gates are
both gating, and one (HG4) is blocked by an external constraint outside the project's CI control. The
score must not be read as "71% to v1.0" in any release-decision sense: **a single unmet hard gate
keeps the product pre-1.0.**

---

## 279. v1.0 risk register

| ID | Risk | Likelihood | Impact | Mitigation / status |
| --- | --- | --- | --- | --- |
| R1 | **NVD rate-limiting (HTTP 429) blocks Dependency-Check evidence indefinitely** | High (observed this sprint) | High (chief blocker B1/HG4) | Warm monthly NVD `actions/cache` + an **NVD API key** to lift the 429; foreground run with `if: always()` upload on a consumer default branch — [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md). Until then the wrapper reports `unavailable` honestly (no fake-clean). |
| R2 | **Pressure to fake-clean or invent a Dependency-Check artifact** to close HG4 | Low | Critical (integrity) | Honesty invariant + self-test asserts the live-evidence registry does **not** promote Dependency-Check; `unavailable` is the only correct empty state. |
| R3 | **No consumer reaches green `strict`** (baseline debt) | Medium | High (HG5) | Burn down debt on a consumer via `report-only → baseline → strict` progression ([`strict-mode-readiness.md`](strict-mode-readiness.md)). |
| R4 | **Digest drift / unpinned scanner refs in production** | Medium | Medium (B5) | Resolved digests + documented override env vars ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md), [`pinned-tool-references.md`](pinned-tool-references.md)); consumers pin before prod. |
| R5 | **Install/sync regressions on un-round-tripped manifests** | Medium | Medium (B4) | Dry-run-by-default + `never_touch` protection; add fixture round-trips for remaining manifests. |
| R6 | **Local tool-validation mistaken for live-validation** (Checkov/Grype this sprint) | Medium | Medium (integrity / over-claiming) | This doc, §263/§266, and the graduation ladder explicitly state local runs do **not** promote maturity; only cited consumer runs do. |
| R7 | **Self-test count regression** lowering coverage silently | Low | Medium | Floor rule (≥300 PASS, growth-or-hold); a drop without a CHANGELOG note blocks a tag. |
| R8 | **Scope creep into DAST/AI gating** against non-goals | Low | Medium | Non-goals fixed in §271/§272; `workflow-sanity` enforces DAST fail-closed + AI non-gating. |

---

## 280. Roadmap update (captain-owned — note only)

The maturity-ordered plan lives in [`roadmap.md`](roadmap.md), which the **captain owns**; this
burn-down does **not** edit it. For the captain's roadmap pass, the v0.1.25 delta to reflect:

- **B1 (chief):** reclassify Dependency-Check from "attempted" to **"proven-blocked-by-external-
  constraint (NVD-429)"** — a real cold run failed on NVD rate-limiting; the path now explicitly
  requires a warm NVD cache **plus an NVD API key** on a consumer default branch.
- **B2:** record **Checkov (3.3.0) and Grype (0.114.0) as LOCALLY tool-validated** this sprint (real
  artifacts parsed by their collectors) — a step above fixtures, still below live-validation.
- **Hardening:** `zap-full` parse path and Nuclei template-path guard exercised by `self-test all`
  (349 PASS).
- **Score:** **5 / 7 hard gates met**; HG4 + HG5 outstanding. **v1.0 NOT reached.**

---

## Closing — v1.0 STATUS: NOT REACHED

To restate plainly: **Sentinel Shield has NOT reached `v1.0` as of v0.1.25.** The engine, PR-fast
gate, and main-gate core (6 tools) are proven; the self-test floor and install minimum are met
(349 PASS). v0.1.25 added **real local tool-validation** of Checkov and Grype and a **real cold
Dependency-Check run that failed on NVD-429** (wrapper correctly reported unavailable — no
fake-clean). The chief blocker — **OWASP Dependency-Check live validation (HG4)** — is now
characterized as **externally blocked by NVD rate-limiting**, alongside **strict mode on a real
consumer (HG5)**. **5 of 7 hard gates met. `v1.0` is declared only when all hard gates are MET with
cited evidence.** This burn-down records the gap; it does not close it.
