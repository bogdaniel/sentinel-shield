# v1.0 Readiness Definition (pre-1.0)

This document **defines the path to `v1.0`** for Sentinel Shield. It is a contract for what
`v1.0` will *mean*, which surfaces are stable today, and the policies (migration, deprecation,
security, graduation) that govern the engine until that frontier is closed.

> **`v1.0` is NOT reached.** This doc does not declare it reached — it defines the minimum
> required to declare it. Sentinel Shield remains **pre-1.0**. Every maturity claim here defers
> to [`product-status.md`](product-status.md), the single source of truth; where any other doc
> (including this one) disagrees on a label, `product-status.md` wins. Live-validation claims
> defer to [`main-gate-live-evidence.md`](main-gate-live-evidence.md). Interface-stability claims
> build on (and do not duplicate) [`product-contract.md`](product-contract.md).

See also: [`product-contract.md`](product-contract.md) (stable vs experimental surfaces +
pre-1.0 migration), [`product-status.md`](product-status.md) (maturity source of truth),
[`main-gate-live-evidence.md`](main-gate-live-evidence.md) (what is live-validated),
[`roadmap.md`](roadmap.md) (maturity-ordered plan), [`raw-report-contract.md`](raw-report-contract.md)
(per-collector raw behavior), [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md)
(tags, immutability, release gate).

---

## 1. What `v1.0` means here

`v1.0` is **not** "all scanners proven" and **not** "turnkey." It is the point where the
**engine and the core gate path** carry a stability guarantee strong enough that a consumer can
adopt a pinned ref and expect no breaking change without a major bump. `v1.0` is a *commitment to
interface stability over a proven core*, not a breadth milestone. Breadth (more scanners) stays
frozen until depth (live validation) catches up — see [`roadmap.md`](roadmap.md).

---

## 2. `v1.0` MINIMUM required capabilities (DONE vs OUTSTANDING)

Each row states the capability, its required bar, and today's honest status. "DONE" means cited
evidence exists in [`product-status.md`](product-status.md) / [`main-gate-live-evidence.md`](main-gate-live-evidence.md);
"OUTSTANDING" means the bar is not yet met.

| # | Capability | Required bar for `v1.0` | Status today |
| --- | --- | --- | --- |
| 1 | **Gate engine proven** | resolver/enforcer/summary-builder/select deterministic, blocking self-test green | **DONE** — `proven`; blocking self-test (`negative`, `fallback`, `suppression`, `finding-scope`); self-gated in this repo's CI |
| 2 | **PR-fast gate proven** | live-validated on a real consumer with no regression | **DONE** — `proven`; zenchron run 27170148123 (baseline PASS) |
| 3 | **Main-gate core live-validated** (CodeQL / OSV / Trivy-fs / Syft / Grype / Dockle) | each has a cited consumer artifact + collector parse | **DONE** — CodeQL/OSV/Trivy-fs/Syft (run 27214865086); Grype/Dockle (run 27239206382). Severities for CodeQL/OSV remain coarse |
| 4 | **OWASP Dependency-Check live-validated** | a real, cited `dependency-check.json` from a consumer parsed by its collector, **with non-zero CVE buckets exercised** | **DONE** — v0.1.27: real run on a **dependency-rich consumer** (`zenchron-tools`, 9,289 deps) → **7 vulnerable deps / 11 vulns**, collector-parsed to **6 high / 3 medium** (`fail`). The v0.1.26 thin-self-scan caveat is **CLOSED** — non-zero severity buckets are exercised. Surfaced + fixed a real npm `MODERATE→medium` mapping gap. Cited in [`dependency-check-consumer-evidence-v027.md`](dependency-check-consumer-evidence-v027.md). **Residual:** severity fidelity best-effort; npm Node-Audit was rate-limited (429) so npm-source coverage is partial |
| 5 | **Install/sync proven across shipped profiles** | dry-run-default install/sync round-trips with fixtures for the shipped install manifests | **DONE** — v0.1.28: **8 profiles** round-tripped (laravel-react-docker, laravel, react, node, node-react, symfony, php-library, docker): dry-run no-op, apply creates managed files, accepted-risks never created/overwritten, full drift detect→resolve cycle, unmanaged files untouched ([`strict-ci-and-install-sync-evidence-v028.md`](strict-ci-and-install-sync-evidence-v028.md)); guarded by `self-test v028-live` |
| 6 | **Digest pinning** | a documented, verifiable policy to pin every shipped scanner image/action to a digest | **DONE (policy)** — v0.1.28: digests re-verified (all MATCH); **policy decided** — dev/onboarding = readable tags, production/hardened = digest-pinned overrides; hardened digest-pinned example added (`examples/hardened/sentinel-shield-hardened.snippet.yml`); rollback + drift guidance documented. **Pinned-by-default remains opt-in by design** (templates legible; consumer hardens) — a deliberate stance, not an open gap |
| 7 | **Strict mode validated on ≥1 consumer** | a clean strict CI run: delta visible (no masking override) AND Dependency-Check completes | **CLOSED.** v0.1.29 delivered the clean delta (run `27513388096`); **v0.1.30 closes DC-in-CI** — run **`27530386965`** (success): DC downloaded the full NVD dataset (357,832 records) and produced a valid 67 KB `dependency-check.json`, collector `fail` 1 critical / 1 high / 0 medium. Strict views: baseline FAIL `[critical, high]`, **strict-EVIDENCE FAIL `[critical, high, medium]`** (delta visible). Root cause was the non-root container unable to write the host-owned bind-mounted NVD data dir; **fixed** by `chmod a+rwX` ([`dependency-check-ci-evidence-v030.md`](dependency-check-ci-evidence-v030.md)). **Caveat:** strict is not "green" (correctly fails on real findings — opt-in/non-required by default); CI scans the committed surface (69 deps; DC also locally validated on 9,289). Strict **NOT production-ready** by default — but the CI-validation bar is **met** |

**Net:** **all 7 hard blockers now have real, cited evidence.** Engine/PR-fast/main-gate core DONE;
(4) DC rich-consumer, (5) install/sync breadth, (6) digest policy, and **(7) clean strict CI with DC
completing** are CLOSED. The SS-side DC CI bugs (propertyfile perms, container-writable data dir) are
fixed and regression-guarded.

**v1.0 RC status: `v1.0.0-rc.1` soaked → `v1.0.0-rc.2` recommended (NOT final `v1.0.0`).** All 7 hard
blockers remain closed with cited evidence. The rc.1 soak (3-hour, multi-lane) **validated rc.1 on a
real consumer** and found/fixed real issues before final:

- **Consumer evidence (rc.1 tag):** transitive DC CI run `27573703800` (success) — **9,179 deps**,
  collector `fail` 1 critical / 8 high / 6 medium; baseline FAIL `[critical, high]`, strict-EVIDENCE
  FAIL `[critical, high, medium]` (delta visible). The v0.1.30 committed-surface caveat is **closed**.
- **STABLE-surface bug found + fixed (why rc.2, not final):** `resolve-gates.sh` exited `1` on config
  errors, contradicting the STABLE exit-code contract (`2` = config/input). Fixed to exit `2`. Because
  this **changes behavior of a frozen STABLE surface**, RC discipline requires a **new candidate
  (`rc.2`) and re-soak** rather than going straight to final `v1.0.0` — the rc.1→final "drop-in"
  promise no longer holds for rc.1 specifically.
- **Coherence fixes:** stale "DC experimental/NOT live-validated" labels removed from canonical
  product-status/strict-mode-readiness; example workflow uploads hardened with `if: always()`.

**Decision: cut `v1.0.0-rc.2`** carrying these fixes; re-soak; then final `v1.0.0` if rc.2 is clean.
The remaining items are **soft/known limitations appropriate for a release candidate**, not blockers:

- **Soft:** strict mode is opt-in/non-required by default (it correctly fails on real findings — a
  consumer must triage/accept-risk before flipping strict to required); DC CI scans the committed
  dependency surface (add `composer install`/`npm ci` for full transitive CI coverage); digest pinning
  is opt-in (dev tags / prod pinned); install/sync `sync-managed-block` in-place updater is still
  reserved; the NVD key must be rotated (it was chat-exposed) and the secret re-set.
- **Not a blocker:** none of the above is a Sentinel Shield engine defect.

rc.1 ships these as documented known limitations; final `v1.0.0` follows after the rc soak + the
soft items are burned down. **v1.0 (final) is NOT yet claimed — `v1.0.0-rc.1` is.**
See §16 for the consolidated blocker list.

---

## 3. `v1.0` NON-goals (explicitly out of scope)

`v1.0` will **not** turn Sentinel Shield into any of the following. These are permanent product
boundaries, consistent with [`product-status.md`](product-status.md) §2 and
[`product-contract.md`](product-contract.md) §4.

- **Not a bundled scanner suite.** It does not ship scanner binaries; it normalizes and gates
  their output. The consumer runs the tools.
- **Not turnkey / zero-config.** Adoption still requires a profile, pinned refs, and per-project
  risk decisions.
- **Not a DAST platform.** DAST stays `manual`, allowlisted, fail-closed — never a default gate.
- **Not AI-gated.** AI review stays `non-gating` / advisory; it never blocks a release by default.

---

## 4. STABLE CLI scripts (consumers may build automation on these)

These are STABLE surfaces (changes additive before `v1.0`; see §7). Flags below are the stable
contract; new flags may be added, existing ones are not silently repurposed. Exit codes: `0`
pass, `1` gate fail / missing-required, `2` config-or-input error.

| Script | Purpose | Stable flags |
| --- | --- | --- |
| [`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh) | Mode → fail-on flags; writes `reports/sentinel-shield-gates.{env,json,md}` | `--profile <path>`, `--mode <report-only\|baseline\|strict\|regulated>`, `--output-dir <path>`, `--help` |
| [`scripts/enforce-gates.sh`](../scripts/enforce-gates.sh) | Findings → pass/fail against resolved flags | `--gates-env <path>`, `--summary <path>`, `--output-dir <path>`, `--format <markdown\|json\|all>`, `--strict-summary`, `--accepted-risks <path>`, `--hadolint-raw <path>`, `--docker-base-digest-raw <path>`, `--help` |
| [`scripts/build-security-summary.sh`](../scripts/build-security-summary.sh) | Merge collector output over `reports/raw/*` into one `security-summary.json` | `--raw-dir <path>`, `--output <path>`, `--project-name`, `--project-type`, `--criticality <low\|medium\|high\|critical>`, `--commit`, `--branch`, `--workflow`, `--strict-tools`, `--require-tool <tool>` (repeatable), `--help` |
| [`scripts/select-security-summary.sh`](../scripts/select-security-summary.sh) | Fail-closed summary selection (example never accepted outside `report-only`) | `--summary <path>`, `--example <path>`, `--gates-env <path>`, `--mode <mode>`, `--help` |
| [`scripts/install-baseline.sh`](../scripts/install-baseline.sh) | Dry-run-by-default install of a profile baseline | `--profile <name>`, `--mode <mode>`, `--target <dir>`, `--apply`, `--force`, `--help` |
| [`scripts/sync-baseline.sh`](../scripts/sync-baseline.sh) | Dry-run-by-default drift sync; honors `never_touch` | `--profile <name>`, `--target <dir>`, `--apply`, `--dry-run`, `--force`, `--help` |
| [`scripts/self-test.sh`](../scripts/self-test.sh) | The engine's blocking self-test | subcommands incl. `all`, `fixtures`, `install-sync`, `negative`, `suppression`, `finding-scope`, `scanner-matrix`, `workflow-sanity`, `main-gate-harness`, `mode-readiness` (run `all` for the full suite) |

STABLE alongside these: the `SENTINEL_SHIELD_*` env-var contract (e.g. `SENTINEL_SHIELD_MODE`,
`SENTINEL_SHIELD_FAIL_ON_*`, `SENTINEL_SHIELD_PATH`, `SENTINEL_SHIELD_REF`), the exit-code
conventions, and the adoption mode names (`report-only`, `baseline`, `strict`, `regulated`) — per
[`product-contract.md`](product-contract.md) §1.

---

## 5. EXPERIMENTAL CLI scripts / surfaces (depend on these only with review)

These exist to *produce* or *verify* contract artifacts. Their flags/behavior may change without
an additive guarantee.

| Surface | Why experimental |
| --- | --- |
| Individual audit wrappers — [`scripts/audits/`](../scripts/audits/) (`grype.sh`, `dockle.sh`, `osv-scanner.sh`, `trivy-fs.sh`, `trivy-image.sh`, `dependency-check.sh`, `checkov.sh`, `conftest.sh`, `terrascan.sh`, `scorecard.sh`, `trufflehog.sh`, `syft.sh`, `dependency-policy.sh`) | Produce raw reports with **coarse severity** mapping (best-effort buckets per [`raw-report-contract.md`](raw-report-contract.md)). The collector I/O contract is stable; the severity assigned is not. Wrappers for not-yet-live-validated tools may change shape. |
| [`scripts/run-main-gate-validation.sh`](../scripts/run-main-gate-validation.sh) | Branch-safe harness that runs main-gate wrappers from any branch. The **harness engine** is `proven` (self-test `main-gate-harness`), but it is an internal validation driver, not a consumer-facing gate CLI; its flags (`--target`, `--output-dir`, `--profile`, `--tool`, `--all`) may evolve. **Running scanners through it ≠ live-validated.** |
| [`scripts/verify-semgrep-image.sh`](../scripts/verify-semgrep-image.sh) | Tooling-verification helper (Semgrep over a modern-PHP fixture). Emits a verification artifact, not a gated report. Flags (`--config`, `--json`, `--output`, `--rm`) may change. |

---

## 6. STABLE raw-report schema expectations

Authoritative reference: [`raw-report-contract.md`](raw-report-contract.md). The following
behaviors are STABLE:

- **Missing or empty raw input → status `unavailable`, counts `0`, exit `0`.** A tool that did
  not run is reported as unavailable — **never** fake-clean.
- **Invalid JSON → exit `2`** (a hard error, not a silent zero). A missing *required* summary key
  in the enforcer path is likewise exit `2`.
- **Collectors normalize to a fixed object shape:** `{ tool, status, summary{…}, tool_report }`,
  merged by [`scripts/build-security-summary.sh`](../scripts/build-security-summary.sh) by summing
  counts.
- **`security-summary.json` summary keys are additive.** New keys are added; existing keys are not
  renamed/removed, and their semantics do not change underneath consumers without a CHANGELOG
  callout. Consumers must tolerate unknown keys.

---

## 7. Migration policy for breaking changes (pre-1.0)

Per [`product-contract.md`](product-contract.md) §5 and
[`sentinel-shield-release-process.md`](sentinel-shield-release-process.md):

- **Pre-1.0 is additive.** Minor tags may add summary keys, env vars, manifest fields, and
  collectors/runners without being treated as breaking.
- **Breaking changes are announced in [`CHANGELOG.md`](../CHANGELOG.md).** Any rename/removal of a
  STABLE surface, change to an exit-code meaning, or change to an existing summary key's semantics
  is called out there. Absence of a breaking-change note means a release is intended to be drop-in
  for the STABLE surfaces in §4 and §6.
- **Tags are immutable.** A published tag is never moved or rewritten. To get changes, bump the
  ref — never expect an existing tag's contents to change.
- **Consumers pin `SENTINEL_SHIELD_REF`** to a **tag or full commit SHA**, never a moving branch.
  Combined with immutable tags, a consumer's behavior changes only when it deliberately bumps the
  ref.

---

## 8. Deprecation policy

- **Announce ahead.** A deprecation of a STABLE surface is announced in [`CHANGELOG.md`](../CHANGELOG.md)
  **at least N minor releases ahead** of removal (default `N = 2`), so consumers have time to
  migrate.
- **Keep a deprecation table.** While a surface is deprecated-but-present, it is listed in a
  deprecation table in the CHANGELOG with: the surface, the replacement, the first release that
  announced it, and the earliest release it may be removed in.
- **Remove only at a major bump.** A deprecated STABLE surface is **not removed before `v1.0`**;
  after `v1.0`, removal happens only at a **major** version bump (semver). Pre-1.0, deprecated
  surfaces keep working until the major boundary.

---

## 9. Support matrix for profiles

Maturity per [`product-status.md`](product-status.md) (source of truth) and
[`product-contract.md`](product-contract.md) §3. Profiles live under [`profiles/`](../profiles/);
install manifests determine which can be installed via [`scripts/install-baseline.sh`](../scripts/install-baseline.sh).

| Profile | Install manifest? | Maturity | Notes |
| --- | --- | --- | --- |
| `laravel` | yes | `supported` | manifest + dry-run; full round-trip only via the `laravel-react-docker` combination |
| `react` | yes | `supported` | manifest + dry-run |
| `node` | yes | `supported` | manifest + dry-run |
| `php-library` | yes | `supported` | manifest added v0.1.16; dry-run |
| `docker` | yes | `supported` | manifest + dry-run (docker-only) |
| `symfony` | yes (manifest) | `supported` | manifest added v0.1.22; no fixture round-trip yet |
| `laravel-react-docker` (combination) | yes | **`proven`** | full fixture round-trip (self-test `install-sync`/`fixtures`) — the only proven install path |
| `node-react` (combination) | yes (manifest) | `supported` | combination manifest added v0.1.22 |

Profiles exist for `symfony`/Go/Python conceptually, but **only the stacks above ship install
manifests**; there is no general onboarding for arbitrary stacks. This is a coverage limit, not a
contract weakness.

---

## 10. Minimum GitHub Actions support

- **Runner:** `ubuntu-latest` (the only runner the shipped templates target).
- **Pinned action versions** used by the shipped templates today: `actions/checkout@v4`,
  `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `actions/cache@v4`,
  `actions/setup-node@v4`.
- **Pin-before-prod requirement.** Templates ship readable tags for legibility. Before production
  use, a consumer **must pin** both first-party actions and scanner images/actions to a digest —
  see [`pinned-tool-references.md`](pinned-tool-references.md) and
  [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md). Templates expose digest
  override env vars to make this a one-line change.
- **Workflow hardening invariants** (enforced by the `workflow-sanity` self-test): no
  `pull_request_target`, minimal permissions, DAST allowlist required, AI review non-gating,
  `if: always()` artifact uploads.

---

## 11. Release cadence (pre-1.0)

- **Small, frequent minors.** Below `v1.0`, releases are small patch/minor tags shipped often
  (the history runs `v0.1.x`). Breadth is frozen; releases deepen validation, hardening, and
  adoption.
- **What triggers a tag:** changes land on `master` via PR with `ci-self-test` green; the
  blocking pre-tag validation in [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md)
  passes (shell syntax, `self-test.sh all` green, JSON/YAML valid, adapter syntax, CHANGELOG
  updated, tag immutability respected); then an annotated `vX.Y.Z` tag is cut. A tag is the unit a
  consumer pins to.

---

## 12. Security patch policy

- **CVE / scanner fixes ship as normal versioned releases** (a new patch/minor tag), following the
  same blocking release gate — there is **no out-of-band silent path**.
- **No silent gate weakening.** A fix never downgrades, suppresses, or removes a gate to make a
  release pass. Never-suppressible gates (secrets, expired exceptions, missing release evidence)
  stay never-suppressible. If a gate's behavior changes, it is a CHANGELOG breaking-change note
  (§7).
- **Real findings are the consumer's to fix.** When a consumer's gate fails on a real CVE (e.g.
  the zenchron baseline FAIL on `critical_vulnerabilities=2`, run 27214863297), Sentinel Shield
  does **not** suppress or accept-risk it on the consumer's behalf — that is correct gate behavior,
  not a bug (see [`main-gate-live-evidence.md`](main-gate-live-evidence.md)).
- **Tool/image bumps** (e.g. a Semgrep version that fixes parser errors, or a re-resolved digest)
  ship as a versioned release with the new ref/digest recorded; resolving a digest is supply-chain
  hardening, not a maturity change.

---

## 13. Compatibility contract for consumers

- **Pin `SENTINEL_SHIELD_REF`** to a tag or full SHA. Never track a moving branch.
- **Expect additive changes** within a pinned major (pre-1.0: across minors). New summary keys,
  env vars, and manifest fields may appear; tolerate unknown keys.
- **Sync-baseline drift handling.** Run [`scripts/sync-baseline.sh`](../scripts/sync-baseline.sh)
  dry-run-first to see drift; `--apply` to reconcile. Project-local files in a manifest's
  `never_touch` list (e.g. `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`,
  `phpstan.neon`) are **never** created or overwritten — regardless of `--force`. See
  [`install-sync-guide.md`](install-sync-guide.md) and [`profile-driven-adoption.md`](profile-driven-adoption.md).
- **Bump deliberately.** Because tags are immutable, a consumer's behavior changes only when it
  bumps the ref and re-syncs; review the CHANGELOG for breaking notes before bumping.

---

## 14. How to graduate a tool: experimental → supported

A tool moves from `experimental` to `supported` when **all** hold:

1. A **collector** exists that normalizes the tool's raw report into the
   `{tool,status,summary,tool_report}` contract (per [`raw-report-contract.md`](raw-report-contract.md)).
2. A **deterministic self-test fixture** exercises it (missing → `unavailable`/exit 0; invalid →
   exit 2; a representative valid report → expected summary keys), wired into
   [`scripts/self-test.sh`](../scripts/self-test.sh) (e.g. the `scanner-matrix` suite).
3. The collector is **deterministic** — same input yields same output, no network, no fake-clean.

Recording: update [`product-status.md`](product-status.md) (the maturity source of truth). A
`supported` tool still has **no cited consumer run** — that is the next gate (§15).

---

## 15. How to graduate a tool: supported → proven

A tool moves from `supported` to `proven` (live-validated) when:

1. It runs in a **real consumer CI** (e.g. bogdaniel/zenchron-tools) and produces a **real raw
   artifact** (`reports/raw/<tool>.json` or the SBOM path) that is **downloaded and confirmed
   valid**.
2. Its **collector parses that real artifact** into the expected summary keys.
3. The run is **cited** — consumer, workflow, run ID, artifact (size + validity), and summary
   mapping — in [`main-gate-live-evidence.md`](main-gate-live-evidence.md), the source of truth for
   "what is live-validated."

Only then is the maturity bumped in [`product-status.md`](product-status.md). **Fixtures alone
never promote a tool; running a scanner is not live validation.** This is exactly how
CodeQL/OSV/Trivy-fs/Syft (run 27214865086) and Grype/Dockle (run 27239206382) were promoted — and
exactly why **OWASP Dependency-Check is not promoted**: no real cited artifact exists.

---

## 16. `v1.0` is NOT reached — outstanding blockers

**Sentinel Shield has not reached `v1.0`.** The engine and main-gate core are proven, but the
following must close first (cross-referenced from §2):

1. **OWASP Dependency-Check live validation — chief blocker.** Still **attempted, NOT
   live-validated**; cold NVD exceeds the CI budget and no real `dependency-check.json` exists. The
   path is the dedicated warm-cache nightly evidence workflow; promotion requires a real cited
   artifact in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
2. **Install/sync proof beyond `laravel-react-docker`.** Only that combination has a full fixture
   round-trip proven; the other shipped manifests need round-trip evidence.
3. **Default-capable digest pinning coverage.** Digests are resolved for Semgrep/Grype/Dockle and
   the override path is documented, but full coverage across every shipped ref (and the
   not-pinned-by-default posture) remains open.
4. **Strict mode validated on ≥1 consumer.** No consumer has yet run green in `strict`.

Secondary depth items tracked in [`roadmap.md`](roadmap.md): refine OSV/CodeQL coarse severity,
Deptrac on a layered project, IaC scanners on a repo with `*.tf`, and the controlled DAST pilot
(stays `manual`). `v1.0` is declared only when the [`roadmap.md`](roadmap.md) frontier (Phase 3
live validation and beyond) lands with cited evidence — this document defines that bar; it does
not assert it is met.

## v0.1.24 closure addendum
The per-sprint v1.0 closure status — blockers remaining/closed, the test-count / profile / live-evidence
thresholds, the graduation ladder, and governance — lives in
[`v1-closure-v024.md`](v1-closure-v024.md). **v1.0 STATUS: NOT REACHED.** The chief remaining blocker
is **OWASP Dependency-Check live validation** (no real artifact exists; a real run was *attempted* this
sprint — see [`dependency-check-live-evidence-v024.md`](dependency-check-live-evidence-v024.md)).

## v0.1.25 closure addendum
Detailed blocker burn-down + readiness score (**5/7 hard gates**, v1.0 **NOT reached**) lives in
[`v1-blocker-burndown-v025.md`](v1-blocker-burndown-v025.md). v0.1.25 produced **real local scanner
validations** (Checkov 16, Grype 1, Deptrac 2 — collector-parsed) and a real strict-mode engine run
([`live-evidence-v025.md`](live-evidence-v025.md)). The chief blocker, **Dependency-Check live
validation, is now characterized as proven-blocked-by-external-constraint (NVD HTTP 429 / API-key
requirement)** — the wrapper correctly refused to fake-clean. Unblock: supply an NVD API key and run
to completion. **v1.0 STATUS: NOT REACHED.**
