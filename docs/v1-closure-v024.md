# v1.0 Closure Addendum (v0.1.24)

This is the **v0.1.24 closure addendum** to [`v1-readiness.md`](v1-readiness.md). It does **not**
redefine `v1.0` — [`v1-readiness.md`](v1-readiness.md) owns that definition (its §1 "what `v1.0`
means", §2 minimum capabilities, §16 blocker list). This addendum records, for the v0.1.24 sprint:
the **blockers that remain**, the **blockers that closed this sprint** (precisely and modestly —
docs/fixtures/tests, **not** live validations), and the **explicit thresholds, processes, and
governance** that gate the `v1.0` declaration. The captain links this from
[`v1-readiness.md`](v1-readiness.md); the captain owns that file, this addendum does not edit it.

> Every maturity claim here defers to [`product-status.md`](product-status.md) (single source of
> truth for maturity). Live-validation claims defer to
> [`main-gate-live-evidence.md`](main-gate-live-evidence.md). Interface-stability promises build on
> [`product-contract.md`](product-contract.md) (the stable contract — see §240) and do not
> duplicate it. Maturity-ordered plan: [`roadmap.md`](roadmap.md).

---

```
╔════════════════════════════════════════════════════════════════════════════╗
║                       v1.0 STATUS: NOT REACHED                               ║
║                                                                              ║
║  Sentinel Shield remains PRE-1.0 as of v0.1.24. The engine and main-gate     ║
║  core are proven; the v1.0 frontier is NOT closed. Do NOT read this doc as   ║
║  a v1.0 declaration. Outstanding blockers (see §222):                        ║
║                                                                              ║
║   1. OWASP Dependency-Check live validation — CHIEF BLOCKER                  ║
║      (attempted; cold NVD exceeds CI budget; no real artifact exists)        ║
║   2. Main-gate FULL live coverage (Deptrac / IaC / Trivy-image still open)   ║
║   3. Strict mode validated on >=1 real consumer (none green in strict yet)   ║
║   4. Install/sync proof beyond `laravel-react-docker`                        ║
║   5. Default-capable digest pinning across every shipped ref                 ║
║   6. DAST / IaC / architecture (Deptrac) still experimental / manual         ║
╚════════════════════════════════════════════════════════════════════════════╝
```

---

## 221. Reference: this builds on `v1-readiness.md`

The authoritative `v1.0` definition is [`v1-readiness.md`](v1-readiness.md):

- **§1** — what `v1.0` *means* (interface stability over a proven core; **not** breadth, **not**
  turnkey).
- **§2** — the seven minimum required capabilities with DONE/PARTIAL/OUTSTANDING status.
- **§4–§6** — the STABLE CLI / env / exit-code / raw-report surfaces.
- **§7–§15** — migration, deprecation, support, release, security, graduation policies.
- **§16** — the consolidated "NOT reached" blocker list.

This addendum is a **v0.1.24 snapshot + sprint delta** layered on top of that document. Where this
addendum and [`v1-readiness.md`](v1-readiness.md) state the same policy, `v1-readiness.md` is the
parent; this addendum adds the **explicit numeric thresholds** (§224–§226) and the **process
detail** (§230–§239) referenced from it.

---

## 222. v1.0 blockers REMAINING (honest)

These are **open** as of v0.1.24. No live validation closed this sprint (see §223). Cross-referenced
from [`v1-readiness.md`](v1-readiness.md) §16 and [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

| # | Blocker | Why still open | Path to close |
| --- | --- | --- | --- |
| 1 | **OWASP Dependency-Check live validation — CHIEF BLOCKER** | **Attempted, NOT live-validated.** Cold NVD download exceeds the CI budget; the detached container ignored a step timeout (run 27239206382). **No real `dependency-check.json` artifact exists.** | Run the dedicated evidence workflow [`templates/workflows/sentinel-shield-dependency-check.yml`](../templates/workflows/sentinel-shield-dependency-check.yml) on a real consumer with a **warm monthly NVD `actions/cache`** (foreground), download the artifact, confirm `scripts/collectors/dependency-check.sh` parses it, and cite the run in [`main-gate-live-evidence.md`](main-gate-live-evidence.md). See [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md). |
| 2 | **Main-gate FULL live coverage** | Live-validated: CodeQL / OSV / Trivy-fs / Syft (run 27214865086); Grype / Dockle / Semgrep (run 27239206382). **Still unproven: Deptrac (no `deptrac.yaml` in pilot), IaC (Checkov/Conftest/Terrascan — no `*.tf`/k8s in pilot), Trivy-image (fs-mode only).** | Validate Deptrac on a layered project, IaC scanners on a repo with `*.tf`/k8s, and Trivy-image against a built image; cite each in [`main-gate-live-evidence.md`](main-gate-live-evidence.md). |
| 3 | **Strict mode on a real consumer** | No consumer has run green in `strict` with no `report-only` escape hatch. [`strict-mode-readiness.md`](strict-mode-readiness.md) / [`regulated-mode-readiness.md`](regulated-mode-readiness.md) define the pre-flight only. | Burn down baseline debt on a consumer, enable the strict gate set, and capture a green `strict` run with the accepted-risk register clean. |
| 4 | **Install/sync proof beyond `laravel-react-docker`** | Only the `laravel-react-docker` combination has a **full fixture round-trip** (self-test `install-sync`/`fixtures`). Other manifests (`react`, `node`, `docker`, `php-library`, `symfony`, `node-react`) have manifests + dry-run only. | Add fixture round-trips for the remaining shipped manifests, wired into [`scripts/self-test.sh`](../scripts/self-test.sh). |
| 5 | **Default-capable digest pinning** | Digests **resolved (not invented)** for Semgrep / Grype / Dockle (2026-06-10); override env vars documented. **Not pinned by default** (templates ship readable tags); full coverage across **every** shipped ref is incomplete. | Resolve + document digests for all remaining shipped scanner images/actions; decide the default-vs-override posture. See [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md), [`pinned-tool-references.md`](pinned-tool-references.md). |
| 6 | **DAST / IaC / architecture still experimental/manual** | DAST (ZAP/Nuclei) is `manual`/fail-closed and **never live-run**; IaC is `experimental`; Deptrac architecture is `not-configured` in the pilot. These are not `v1.0` gating *features* but are explicitly **not promoted**. | DAST stays `manual` by design (a controlled pilot is a roadmap item, not a `v1.0` gate); IaC/Deptrac graduate via the §235 process with cited evidence. |

**Net:** the chief blocker is **(1) Dependency-Check live validation**. (2)/(3) are the next depth
items; (4)/(5) are breadth/hardening; (6) is bounded by product non-goals (§227).

---

## 223. v1.0 blockers CLOSED this sprint (precise + modest)

**No tool was promoted to live-validated in v0.1.24. No new consumer run, no new artifact.** What
closed this sprint is **documentation, fixtures, and tests** — never live validation. Modesty is the
point: running a scanner or adding a fixture is **not** live validation
([`v1-readiness.md`](v1-readiness.md) §15).

| Item closed (v0.1.24) | Category | Evidence | What it is NOT |
| --- | --- | --- | --- |
| This `v1-closure-v024.md` closure addendum | docs | this file (cited, non-empty, `NOT reached` banner) | not a `v1.0` declaration |
| Explicit numeric `v1.0` thresholds recorded (§224–§226) | docs | §224 (self-test count), §225 (profiles), §226 (live evidence) | not a change to the bar in [`v1-readiness.md`](v1-readiness.md) |
| Graduation / evidence / onboarding / governance processes consolidated (§235–§239) | docs | §230–§239 here | not new policy — a restatement layered on [`v1-readiness.md`](v1-readiness.md) §7–§15 and [`product-contract.md`](product-contract.md) |
| Self-test remains green at the recorded count | tests | `self-test.sh all`: **PASS**, **312** PASS checks (verified this sprint) | not a maturity promotion |

**Honest delta vs prior sprints (from [`roadmap.md`](roadmap.md)):** v0.1.23 grew the self-test
271→312 and added [`v1-readiness.md`](v1-readiness.md); v0.1.24 adds **this closure addendum and the
explicit thresholds/processes** — a documentation/governance close, **not** a live-validation close.
The chief blocker (§222 #1) remains **open**.

---

## 224. v1.0 minimum TEST-COUNT threshold

- **Bar:** the engine's blocking self-test ([`scripts/self-test.sh`](../scripts/self-test.sh) `all`)
  must be **green** and must cover **every STABLE surface and every promoted (live-validated) tool**
  with deterministic fixtures (missing → `unavailable`/exit 0; invalid → exit 2; valid → expected
  summary keys).
- **Floor:** **`self-test all` >= 300 PASS checks** AND **0 failures**. The count is a guardrail
  against regression in coverage, not a vanity metric — the *qualitative* requirement (every STABLE
  surface + every promoted tool exercised) dominates.
- **Current count (verified this sprint):** **312 PASS checks, `self-test all`: PASS.** Above the
  floor. (History: 271 at v0.1.22 → 312 at v0.1.23, held at v0.1.24.)
- **Suites in `all`:** `syntax`, `lifecycle`, `fallback`, `negative`, `suppression`, `finding-scope`,
  `third-party`, `hadolint`, `adapters`, `phpstan-runner`, `ud-multisource`, `install-sync`,
  `scanner-matrix`, `fixtures`, `workflow-sanity`, `feature-completion`, `main-gate-harness`,
  `main-gate-evidence`, `main-gate-exec`, `install-matrix`, `mode-readiness`, `v022-fixtures`,
  `v023-coverage`, `v023-regression`.
- **Rule:** the count may only grow or hold across releases; a release that **lowers** the check
  count without a CHANGELOG breaking-change note (per [`v1-readiness.md`](v1-readiness.md) §7) is a
  regression and blocks a tag.

---

## 225. v1.0 minimum PROFILE-SUPPORT threshold

Per [`v1-readiness.md`](v1-readiness.md) §9 and [`product-contract.md`](product-contract.md) §3
(maturity per [`product-status.md`](product-status.md)).

- **Bar:** **>= 1 install path `proven`** (full fixture round-trip in self-test `install-sync` /
  `fixtures`), AND **every shipped install manifest** at least `supported` (manifest + dry-run
  validated, honors `never_touch`, dry-run-by-default).
- **Stretch bar (closes blocker §222 #4):** the four representative install paths —
  `{laravel-react-docker, node-react, docker-only, php-library}` — each `proven` with a fixture
  round-trip (matches [`roadmap.md`](roadmap.md) Phase 2 definition of done).
- **Current state:** **`laravel-react-docker` is the only `proven` install path** (fixture
  round-trip). `react`, `node`, `docker`, `php-library`, `symfony`, `node-react` ship manifests +
  dry-run (`supported`) but **no fixture round-trip** → minimum bar **met**, stretch bar
  **OUTSTANDING**.
- **Scope honesty:** install manifests exist only for the stacks above; there is **no general
  onboarding for arbitrary stacks** (Symfony/Go/Python have profiles but limited/no install
  manifests). This is a coverage limit, **not** a contract weakness — see
  [`product-status.md`](product-status.md).

---

## 226. v1.0 minimum LIVE-EVIDENCE threshold

Per [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (source of truth for "what is
live-validated") and [`v1-readiness.md`](v1-readiness.md) §2.

- **Bar — these scanners MUST be live-validated for `v1.0`:**
  - **Engine + PR-fast gate** — `proven` (self-test; zenchron run 27170148123). **MET.**
  - **Main-gate core (6):** CodeQL, OSV-Scanner, Trivy-fs, Syft, Grype, Dockle — each with a cited
    consumer artifact + collector parse. **MET** (runs 27214865086 + 27239206382).
  - **OWASP Dependency-Check** — a real cited `dependency-check.json` parsed by its collector.
    **NOT MET — CHIEF BLOCKER** (§222 #1).
- **Below the bar (NOT required for `v1.0`, tracked in [`roadmap.md`](roadmap.md)):** Deptrac
  (architecture), IaC scanners (Checkov/Conftest/Terrascan), Trivy-image — graduate via §235 with
  cited evidence; DAST stays `manual` by design (§227).
- **Evidence rule:** a tool is live-validated **only** when a real consumer run produces a real
  artifact that is downloaded, confirmed valid, and parsed by its collector, **cited** (consumer,
  workflow, run ID, artifact size + validity, summary mapping) in
  [`main-gate-live-evidence.md`](main-gate-live-evidence.md). **Fixtures never promote a tool.**
- **Current state:** core 6 + engine + PR-fast = live-validated; **Dependency-Check is the single
  remaining required tool** for the live-evidence bar.

---

## 227. v1.0 NON-goals (explicitly out of scope)

Permanent product boundaries, consistent with [`v1-readiness.md`](v1-readiness.md) §3,
[`product-status.md`](product-status.md) §2, and [`product-contract.md`](product-contract.md) §4.
`v1.0` will **not** make Sentinel Shield any of these:

- **Not a bundled scanner suite** — it normalizes and gates scanner output; the consumer runs the
  tools. No scanner binaries are shipped.
- **Not turnkey / zero-config** — adoption still requires a profile, pinned refs, and per-project
  risk decisions.
- **Not a DAST platform** — DAST stays `manual`, allowlisted, fail-closed; never a default gate.
- **Not AI-gated** — AI review stays `non-gating`/advisory; never blocks a release by default.
- **Not "all scanners proven" / not a breadth milestone** — `v1.0` is interface stability over a
  proven core. Breadth stays frozen until depth (live validation) catches up
  ([`roadmap.md`](roadmap.md)).

---

## 228. PRE-1.0 compatibility promises

Per [`v1-readiness.md`](v1-readiness.md) §7/§13 and [`product-contract.md`](product-contract.md) §5
(the stable contract).

- **Additive minors.** Below `v1.0`, minor tags may add summary keys, env vars, manifest fields, and
  collectors/runners **without** being treated as breaking.
- **Breaking changes are announced in [`CHANGELOG.md`](../CHANGELOG.md)** — any rename/removal of a
  STABLE surface, change to an exit-code meaning, or change to an existing summary key's semantics.
  Absence of a breaking-change note ⇒ drop-in for the STABLE surfaces.
- **Tags are immutable** — a published tag is never moved or rewritten; bump the ref to get changes.
- **Consumers pin `SENTINEL_SHIELD_REF`** to a tag or full SHA, never a moving branch.
- **Tolerate unknown keys** — new `security-summary.json` keys may appear within a pinned ref's
  successors; consumers must not break on them.

## 229. POST-1.0 compatibility promises

These take effect **only after `v1.0` is declared** (it is **not** — see banner). Recorded now so the
contract is explicit before the frontier closes:

- **Semantic versioning enforced.** After `v1.0`, the STABLE surfaces (CLIs, exit codes, env-var
  names, `security-summary.json` / manifest / accepted-risk schemas) change **only additively within
  a major**. A rename/removal or a change to an existing key's semantics requires a **major** bump.
- **No silent breaking change ever.** Same CHANGELOG-callout rule as pre-1.0, but enforced by semver:
  breaking ⇒ major.
- **Deprecation precedes removal** (see §230) — a STABLE surface is deprecated for >= N minors before
  removal, and removal lands only at a major boundary.
- **Tags remain immutable** post-1.0 as pre-1.0.

## 230. Deprecation process

Per [`v1-readiness.md`](v1-readiness.md) §8.

1. **Announce ahead** — a deprecation of a STABLE surface is announced in
   [`CHANGELOG.md`](../CHANGELOG.md) **at least N minor releases ahead** of removal (default
   **N = 2**).
2. **Keep a deprecation table** in the CHANGELOG while a surface is deprecated-but-present:
   surface · replacement · first release that announced it · earliest release it may be removed.
3. **Remove only at a major bump** — a deprecated STABLE surface is **not removed before `v1.0`**;
   post-1.0, removal happens only at a **major** version (semver). Pre-1.0, deprecated surfaces keep
   working until the major boundary.

## 231. Migration guide structure

A migration guide (per breaking release / per major) is structured as:

1. **From → To** — the ref range the guide covers (tag/SHA to tag/SHA).
2. **Breaking changes** — each STABLE-surface rename/removal/semantic change, cross-linked to its
   CHANGELOG breaking-change note (§228/§230).
3. **Required consumer actions** — concretely: bump `SENTINEL_SHIELD_REF`, re-run
   [`scripts/sync-baseline.sh`](../scripts/sync-baseline.sh) (dry-run first), reconcile any new
   gate / summary key, review the accepted-risk register.
4. **`never_touch` reassurance** — confirm which project-local files are never created/overwritten
   ([`install-sync-guide.md`](install-sync-guide.md), [`profile-driven-adoption.md`](profile-driven-adoption.md)).
5. **Rollback** — pin back to the prior tag (tags are immutable, so rollback is deterministic).

## 232. Release cadence

Per [`v1-readiness.md`](v1-readiness.md) §11.

- **Small, frequent minors** below `v1.0` (history runs `v0.1.x`). Breadth is frozen; releases
  deepen validation, hardening, and adoption.
- **Tag trigger:** changes land on `master` via PR with `ci-self-test` green; the blocking pre-tag
  validation in [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md) passes
  (shell syntax, `self-test.sh all` green, JSON/YAML valid, adapter syntax, CHANGELOG updated, tag
  immutability respected); then an annotated `vX.Y.Z` tag is cut. A tag is the unit a consumer pins.

## 233. Security patch process

Per [`v1-readiness.md`](v1-readiness.md) §12.

- **CVE / scanner fixes ship as normal versioned releases** (new patch/minor tag), through the same
  blocking release gate — **no out-of-band silent path**.
- **No silent gate weakening** — a fix never downgrades, suppresses, or removes a gate to make a
  release pass. Never-suppressible gates (secrets, expired exceptions, missing release evidence)
  stay never-suppressible; any gate-behavior change is a CHANGELOG breaking-change note (§228).
- **Real findings are the consumer's to fix** — when a consumer's gate fails on a real CVE (e.g. the
  zenchron baseline FAIL on `critical_vulnerabilities=2`, run 27214863297), Sentinel Shield does
  **not** suppress or accept-risk it on the consumer's behalf. That is correct gate behavior.
- **Tool/image bumps** (e.g. a Semgrep version fixing parser errors, or a re-resolved digest) ship as
  a versioned release with the new ref/digest recorded; resolving a digest is supply-chain hardening,
  not a maturity change.

## 234. Support lifecycle

- **Supported ref:** the **latest tag** is supported. Consumers pin a tag/SHA and bump deliberately.
- **Pre-1.0:** no long-term-support branches; fixes land on `master` and ship in the next tag. The
  immutable-tag + additive-minor contract (§228) is the stability guarantee, not back-porting.
- **Post-1.0 (future):** security fixes back-ported to the **current major** for its support window;
  a deprecation/removal of a STABLE surface follows §230 (>= N minors notice, removal at major).
- **End-of-support:** announced in [`CHANGELOG.md`](../CHANGELOG.md) ahead of time; a ref is never
  silently dropped.

## 235. Scanner graduation process (experimental → supported → proven)

The canonical promotion ladder. Per [`v1-readiness.md`](v1-readiness.md) §14–§15,
[`gate-promotion-policy.md`](gate-promotion-policy.md), and
[`product-status.md`](product-status.md) (vocabulary).

**`experimental` → `supported`** (all must hold):
1. A **collector** normalizes the tool's raw report into `{tool,status,summary,tool_report}`
   ([`raw-report-contract.md`](raw-report-contract.md)).
2. A **deterministic self-test fixture** exercises it (missing → `unavailable`/exit 0; invalid →
   exit 2; valid → expected summary keys), wired into [`scripts/self-test.sh`](../scripts/self-test.sh)
   (e.g. `scanner-matrix`).
3. The collector is **deterministic** — same input, same output; no network; **never fake-clean**.
   *Record in [`product-status.md`](product-status.md). A `supported` tool still has NO cited
   consumer run.*

**`supported` → `proven` (live-validated)** (all must hold):
1. Runs in a **real consumer CI** and produces a **real raw artifact** that is **downloaded and
   confirmed valid**.
2. Its **collector parses that real artifact** into the expected summary keys.
3. The run is **cited** (consumer · workflow · run ID · artifact size+validity · summary mapping) in
   [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
   *Only then is maturity bumped in [`product-status.md`](product-status.md). **Fixtures alone never
   promote; running a scanner is not live validation.*** This is exactly how CodeQL/OSV/Trivy-fs/Syft
   (27214865086) and Grype/Dockle (27239206382) were promoted, and exactly why Dependency-Check is
   **not** (no real cited artifact).

## 236. Evidence requirements

- **Live-validation evidence:** every promotion to `proven` cites a real consumer run in
  [`main-gate-live-evidence.md`](main-gate-live-evidence.md) with consumer, workflow, run ID,
  artifact (size + validity), and the summary-key mapping. **No invented run IDs or artifacts** — a
  PENDING/attempted state is recorded honestly (see the Dependency-Check rows there).
- **Engine evidence:** the blocking self-test (§224) is the engine's proof; it must be green at the
  recorded check count.
- **Negative evidence counts:** a wrapper reporting `unavailable` (tool absent, no fake-clean) and a
  gate correctly FAILing on a real finding (e.g. run 27214863297) are valid, cited evidence of
  correct behavior — not bugs.
- **Source-of-truth precedence:** maturity → [`product-status.md`](product-status.md);
  live-validation → [`main-gate-live-evidence.md`](main-gate-live-evidence.md); interface stability →
  [`product-contract.md`](product-contract.md). Where docs disagree on a label, these win in that
  order.

## 237. Consumer onboarding requirements

A consumer onboards by (per [`adoption-guide.md`](adoption-guide.md),
[`profile-driven-adoption.md`](profile-driven-adoption.md), [`install-sync-guide.md`](install-sync-guide.md)):

1. **Pick a profile** with a shipped install manifest (§225); pin `SENTINEL_SHIELD_REF` to a tag/SHA.
2. **Install dry-run-first** via [`scripts/install-baseline.sh`](../scripts/install-baseline.sh)
   (`--apply` to write); project-local `never_touch` files are never created/overwritten.
3. **Start in `report-only`**, then progress `report-only → baseline → strict` as debt is burned
   down ([`strict-mode-readiness.md`](strict-mode-readiness.md)).
4. **Pin scanner digests** before production ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md),
   [`pinned-tool-references.md`](pinned-tool-references.md)).
5. **Maintain the accepted-risk register** ([`accepted-risk-suppression.md`](accepted-risk-suppression.md));
   never-suppressible gates stay never-suppressible.
6. **Re-sync deliberately** with [`scripts/sync-baseline.sh`](../scripts/sync-baseline.sh) (dry-run
   first) when bumping the ref; review the CHANGELOG for breaking notes (§228).

## 238. Docs completeness requirements

For `v1.0`, the documentation set must (and as of v0.1.24 does, for the proven surfaces) include:

- **Contract & maturity:** [`product-contract.md`](product-contract.md) (stable surfaces),
  [`product-status.md`](product-status.md) (maturity SoT), [`v1-readiness.md`](v1-readiness.md)
  (the `v1.0` bar), this addendum.
- **Evidence:** [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (live-validation SoT),
  [`raw-report-contract.md`](raw-report-contract.md) (per-collector behavior).
- **Adoption:** [`adoption-guide.md`](adoption-guide.md),
  [`profile-driven-adoption.md`](profile-driven-adoption.md),
  [`install-sync-guide.md`](install-sync-guide.md),
  [`profile-compatibility.md`](profile-compatibility.md).
- **Governance / policy:** [`gate-promotion-policy.md`](gate-promotion-policy.md),
  [`accepted-risk-suppression.md`](accepted-risk-suppression.md),
  [`exception-policy.md`](exception-policy.md),
  [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md),
  [`pinned-tool-references.md`](pinned-tool-references.md).
- **Plan:** [`roadmap.md`](roadmap.md) (maturity-ordered).
- **Completeness rule:** every STABLE surface (§4 of [`v1-readiness.md`](v1-readiness.md)) and every
  promoted tool is documented; every "NOT live-validated" / experimental state is stated honestly,
  with the path to close it.

## 239. Governance requirements

- **Single sources of truth, with precedence** (§236): maturity → `product-status.md`;
  live-validation → `main-gate-live-evidence.md`; interface stability → `product-contract.md`. Other
  docs defer.
- **Promotion governance:** maturity is bumped **only** with cited evidence via the §235 ladder; the
  blocking self-test and the release gate (§232) enforce that the engine stays green and tags stay
  immutable.
- **No-silent-weakening invariant:** never-suppressible gates (secrets, expired exceptions, missing
  release evidence) stay never-suppressible (§233); accepted-risk requires an approved, in-scope,
  unexpired entry ([`accepted-risk-suppression.md`](accepted-risk-suppression.md)).
- **Honesty invariant:** no `v1.0`/turnkey claim, no invented evidence; attempted-but-unvalidated
  states are recorded as such (the Dependency-Check posture is the worked example).
- **Change control:** STABLE-surface changes go through PR + green `ci-self-test` + the blocking
  pre-tag validation; breaking changes are CHANGELOG-announced (§228) and deprecation-gated (§230).

## 240. The stable contract: `product-contract.md`

[`product-contract.md`](product-contract.md) **is the stable contract** for Sentinel Shield — it is
the authoritative statement of which surfaces a consumer may depend on (STABLE) versus which may
change (EXPERIMENTAL/INTERNAL), plus the raw-report, profile-manifest, and migration promises. This
addendum and [`v1-readiness.md`](v1-readiness.md) build on it and do **not** restate it as new
policy. **The captain may append to `product-contract.md`**; this addendum does not edit it. Where
any doc disagrees with `product-contract.md` on interface stability, `product-contract.md` wins
(maturity labels still defer to [`product-status.md`](product-status.md)).

---

## Closing — v1.0 STATUS: NOT REACHED

To restate plainly: **Sentinel Shield has NOT reached `v1.0` as of v0.1.24.** The engine, PR-fast
gate, and the main-gate core (6 tools) are proven; the v0.1.24 sprint closed **documentation,
fixtures, and tests only** — **no live validation**. The chief outstanding blocker is **OWASP
Dependency-Check live validation** (no real artifact exists), alongside full main-gate live coverage,
a strict run on a real consumer, install/sync proof beyond `laravel-react-docker`, full default-capable
digest pinning, and the still-experimental/manual DAST/IaC/architecture surfaces. `v1.0` is declared
only when the [`roadmap.md`](roadmap.md) frontier lands with cited evidence and the
[`v1-readiness.md`](v1-readiness.md) §2 bar is fully met. This addendum records the gap; it does not
close it.
</content>
</invoke>
