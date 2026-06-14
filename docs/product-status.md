# Product Status (v0.1.16)

This is the **single source of truth for Sentinel Shield maturity**. Where another doc
(enterprise-scanner-matrix, production-readiness-audit) disagrees on a label, this file wins.
It is deliberately conservative: a capability is only `proven` if there is cited evidence.

## Maturity vocabulary (canonical)

| Label | Meaning |
| --- | --- |
| `proven` | Live-validated in a real consumer CI **or** the engine's own blocking self-test. Cited evidence exists. |
| `supported` | Runner/collector/self-test fixture exists and is deterministic, but **not yet run against a real consumer**. |
| `experimental` | Wired, but the parser/severity mapping is coarse or noisy (e.g. OSV/CodeQL `level→severity`). Use with review. |
| `manual` | Runs only on explicit operator action with a target + allowlist (DAST). Never a default gate. |
| `template-only` | Workflow/docs exist; not executed by default and not yet validated on a consumer. |
| `non-gating` | Produces advisory output only; never blocks a release by default (AI review). |
| `not-ready` | Declared/reserved or known-incomplete; do not rely on it. |

Mapping from the per-tool A–F grades in
[`production-readiness-audit.md`](production-readiness-audit.md): A→`proven`,
B→`supported`, C→`experimental`, D→`template-only`, F→`manual`/`non-gating`/`not-ready`.

---

## 1. What Sentinel Shield is

A **reusable release-gate engine and security/quality baseline** for code, containers, CI,
and infrastructure. Concretely it owns:

- A deterministic **gate engine**: `resolve-gates.sh` (mode → fail-on flags), `enforce-gates.sh`
  (findings → pass/fail), `build-security-summary.sh` (raw reports → one contract).
- A normalized **finding contract** (`security-summary.json`) with a JSON Schema.
- **Collectors / runners / adapters / audits** that turn external scanner output into that contract.
- **Profile manifests** + `install-baseline.sh` / `sync-baseline.sh` for safe adoption.
- **Workflow templates**, **accepted-risk governance**, and **remediation/governance docs**.
- A **self-test** that gates the engine on every push/PR.

## 2. What it is not

- **Not a bundled scanner suite.** Sentinel Shield does not ship scanner binaries; it
  normalizes and gates their output. The consumer runs the tools.
- **Not "30 scanners all proven."** Most non-core scanner integrations are `supported`/`experimental`.
- **Not a turnkey, zero-config product.** Adoption requires a profile, pinned tool refs, and
  per-project risk decisions.
- **Not an AI-driven gate.** AI review is assistive and non-gating.
- **Not a DAST platform.** DAST is manual, allowlisted, and fail-closed.

## 3. Current maturity by area

| Area | Maturity | Evidence |
| --- | --- | --- |
| Gate resolver / enforcer / summary builder | `proven` | Blocking self-test (`negative`, `fallback`, `suppression`); self-gated in this repo's CI |
| Accepted-risk schema + finding-scoped suppression (`unsafe_docker`) | `proven` | Self-test `finding-scope`, `ud-multisource` |
| Install / sync engine (laravel-react-docker) | `proven` | Self-test `install-sync`, `fixtures` round-trip |
| Raw-report contract + collectors (core 14) | `proven` | Self-test fixtures + zenchron pilot |
| PR-fast gate (`sentinel-shield-pr-fast.yml`) | `proven` | zenchron run 27170148123 (baseline PASS, no regression) |
| Main-branch gate (`sentinel-shield-main.yml`) | `supported` (partial) | CodeQL/OSV/Trivy-fs/Syft **live-validated** (run 27214865086); Grype/Dep-Check/Dockle/Deptrac/IaC still unproven |
| Main-gate validation harness (`run-main-gate-validation.sh`) | `proven` (engine) | Self-test `main-gate-harness`; runs main-gate wrappers branch-safely, unavailable-not-fake. **Running scanners ≠ live-validated** |
| Profile system (Laravel/React/Node/Docker) | `supported` | Manifests + dry-run; only laravel-react-docker has a full fixture round-trip |
| Scheduled / nightly gate | `template-only` | Not executed by default |
| DAST (ZAP/Nuclei) | `manual` | Fail-closed guard + collector self-test; never live-run |
| AI review (Claude Code Security Review / Kuzushi) | `non-gating` | Collector self-test; advisory only |
| IaC (Checkov/Conftest/Terrascan) | `experimental` | Audit+collector+fixture; no consumer with IaC validated |

## 4. Proven capabilities (cited evidence)

Engine (self-gated in this repo):

- `resolve-gates.sh`, `enforce-gates.sh`, `build-security-summary.sh`,
  `select-security-summary.sh`, `install-baseline.sh`, `sync-baseline.sh`, `self-test.sh`.

Scanners live-validated on **bogdaniel/zenchron-tools** (run 27170148123, baseline 27170126445 PASS):

- Gitleaks, Semgrep app (**curated rules; never `--config=auto`**), PHPStan/Larastan, PHPUnit,
  composer audit, Hadolint (multi-Dockerfile), Docker base-digest audit, GitHub Actions pin audit,
  Trivy-fs, php-syntax (`php -l`).
- Promoted in v0.1.15 with cited raw→key evidence: **php-style** (Pint/PHP-CS-Fixer →
  `style_violations`=88), **TypeScript `--noEmit`** (`type_errors`=0), **dependency-policy lockfile
  detector** (`dependency_policy_violations`=0).
- **Promoted in v0.1.18 — main-gate tools, live evidence run 27214865086** (see
  [`main-gate-live-evidence.md`](main-gate-live-evidence.md)): **CodeQL** (`codeql.json` 669 KB
  SARIF → 0/0/11 medium), **OSV-Scanner** (`osv-scanner.json` → 1 high), **Trivy-fs** (`trivy.json`
  308 KB → clean), **Syft SBOM** (`sbom.spdx.json` 964 KB → `missing_sbom=false`). Severity for
  CodeQL/OSV remains coarse (limitation noted in the registry).

> **Baseline gate working (run 27214863297).** The zenchron-tools main baseline **FAILED** on
> `critical_vulnerabilities=2` — a real npm critical (`shell-quote` via `concurrently@9.2.1`).
> This is **correct release-gate behavior**, NOT a Sentinel Shield bug. The consuming project
> fixes the dependency in its own PR; Sentinel Shield does not suppress, accept-risk, or
> downgrade it. See [`pilot-consumers.md`](pilot-consumers.md) and [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## 5. Supported but not yet proven

Collector + deterministic self-test fixture exists; **no live consumer run** yet:

- npm audit, ESLint, Vitest/Jest adapters, Deptrac, Psalm,
  third-party Semgrep channel.

These were `not-configured` on the pilot (the runners correctly reported `unavailable` — no fake
output). To promote: run on a consumer that configures them and cite the run.

## 6. Experimental / template-only capabilities

- **Experimental** (coarse parser, live-validate before trusting severity):
  OWASP Dependency-Check,
  OpenSSF Scorecard, TruffleHog, Checkov, Conftest/OPA, Terrascan, Trivy-image.
  actionlint/zizmor run **advisory** in self-test.
- **Template-only**: `sentinel-shield-main.yml`, `sentinel-shield-scheduled.yml` (and the
  combined `sentinel-shield.yml` against a real consumer pipeline).

## 7. Known product gaps

- **Main-gate live validation underway.** v0.1.17 added the branch-safe path
  (`run-main-gate-validation.sh`); v0.1.18 promotes the **first four** main-gate tools with cited
  evidence (run 27214865086): **CodeQL, OSV-Scanner, Trivy-fs, Syft SBOM**. Still **not**
  live-validated: **Grype, OWASP Dependency-Check, Dockle** (binary/image absent on the pilot —
  see [`tooling/main-gate-tool-installation.md`](tooling/main-gate-tool-installation.md)),
  **Deptrac** (no `deptrac.yaml`), **Checkov/Conftest/Terrascan** (no IaC). Promotion requires a
  real cited run in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
- **Install/sync covers four stacks, not arbitrary onboarding.** No `php-library` /`node-react`
  *named combination* manifest historically (php-library added in v0.1.16; node-react uses the
  `react` profile). Symfony/Go/Python have profiles but no install manifests.
- **Severity fidelity is best-effort** for OSV/CodeQL/Grype/Dependency-Check.
- **No tool image/action is pinned to a digest by default** — the consumer must pin
  (`pinned-tool-references.md`).
- **Finding-scoped suppression is `unsafe_docker`-only**; other count gates support broad
  `scope:gate` only.
- **DAST/AI never validated end-to-end** against a live target (by design they need an operator).

## 8. Recommended adoption path

1. Install in **`report-only`** (`install-baseline.sh --mode report-only`).
2. Wire the **PR-fast gate** (`proven`) and pin its actions/images.
3. Move to **`baseline`** once new code stops adding risk.
4. Add **main-gate** scanners as **advisory** first; treat `experimental` severities as review prompts.
5. Tighten to **`strict`**; keep DAST/AI manual/non-gating.
6. Use `regulated` only when audit evidence is required.

See [`roadmap.md`](roadmap.md) and [`product-readiness-checklist.md`](product-readiness-checklist.md).

## v0.1.19 — main-gate execution hardening (no promotions)
Grype (SBOM-first/fs + container), OWASP Dependency-Check (disabled-default, cache, nightly),
and Dockle (built-image-gated) now run predictably from the harness/templates — but remain
**supported / experimental, NOT live-validated** (no consumer artifact yet). Semgrep
`1.165.0` is **fixture-verified** (0 parser errors on modern PHP via `verify-semgrep-image.sh`),
**not** consumer-verified. Deptrac/IaC stay not-configured-unless-provided. See
[`main-gate-execution-hardening-v0.1.19.md`](main-gate-execution-hardening-v0.1.19.md).

## v0.1.20 — main-gate execution-path promotions (zenchron run 27239206382)
**Promoted to live-validated** with real artifacts (see [`main-gate-live-evidence.md`](main-gate-live-evidence.md)):
- **Grype** (SBOM-first; `grype.json` valid, collector → `*_vulnerabilities`).
- **Dockle** (built `base` image; `dockle.json` valid → `container_image_violations`=1).
- **Semgrep 1.165.0**: fixture-verified → **consumer-verified** — **0 parser errors on real app code** (was 118 on 1.90.0); 25 medium findings visible for triage.

**Still NOT promoted:** **OWASP Dependency-Check** (attempted; cold NVD exceeds CI budget — run nightly with a warm cache). Deptrac/IaC remain not-configured. No Sentinel Shield bug surfaced; all wrappers/collectors parsed real artifacts correctly.

## v0.1.21 — Dependency-Check nightly hardening + scanner digest pinning (no promotions)
- **OWASP Dependency-Check:** still **attempted, NOT live-validated** — no real `dependency-check.json`
  exists. v0.1.21 builds the validation *path*: a cached nightly job (monthly NVD `actions/cache`,
  foreground execution, `if: always()` artifact upload) and a hardened audit wrapper that preserves a
  valid-JSON-with-non-zero-exit report and discards partial output (never fake-clean). See
  [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md). Promotion still
  requires a real cited nightly run in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
## v0.1.29 — CLEAN strict CI run (delta visible) + DC propertyfile fix (no v1.0 RC yet)
- **Clean strict CI evidence.** Live run `27513388096` (zenchron-tools, success, ~41 min) with **3
  attributable views**: baseline FAIL `[high]`; **strict-EVIDENCE FAIL `[high, medium]`** (pure
  mode-default → strict-only delta VISIBLE, medium `enabled:true,fail`); strict-CONSUMER FAIL `[high]`
  (medium skipped by the consumer's own `fail_on.medium_vulnerabilities:false`, shown transparently —
  SS suppressed nothing). [`clean-strict-ci-evidence-v029.md`](clean-strict-ci-evidence-v029.md).
- **DC propertyfile bug FIXED.** v0.1.28's CI failure was a real bug — the leak-safe propertyfile was
  `0600`/`0700` owned by the host UID, unreadable by the DC container's UID on Linux Docker. Now
  container-readable (key still off cmdline/logs/report/commits). DC ran the full cold NVD download
  this time.
- **DC-in-CI still blocked (documented).** After the perms fix, DC hit OWASP's **H2 database-lock /
  "No documents exist"** (stale cache) → exit 13, **no fake-clean report**. Local DC evidence (v0.1.27,
  6 high/3 medium) stands. Remaining DC-in-CI work is operational (clean cache seed), not engine.
- **Override precedence documented + guarded** (mode defaults → profile overrides win).
- **v1.0 RC: NOT yet.** Holds the v0.1.28 bar (delta visible AND DC completes): delta now met, DC-in-CI
  not. Next is **v0.1.30** (close DC-in-CI), then `v1.0.0-rc.1`. Self-test **470 → 484**. v1.0 NOT reached.

## v0.1.28 — Strict CI evidence + install/sync breadth + digest policy (no v1.0 RC)
- **Live strict CI evidence.** Real GitHub Actions run on `zenchron-tools` (run `27512789768`,
  success): baseline + strict both ran; baseline FAIL `[high]` / strict FAIL `[high]` (real OSV/Trivy:
  6 high, 4 medium; SBOM present). **Honest residuals:** strict not green (real highs); the consumer's
  explicit `fail_on.medium_vulnerabilities:false` masked the strict delta (shown via pure mode-default
  resolve → strict adds medium); **DC did not complete in CI** (1-min run; local v0.1.27 DC evidence
  stands). Nothing suppressed by SS. Strict **NOT production-ready**.
  [`strict-ci-and-install-sync-evidence-v028.md`](strict-ci-and-install-sync-evidence-v028.md).
- **Install/sync breadth CLOSED.** 8 profiles round-tripped (laravel-react-docker, laravel, react,
  node, node-react, symfony, php-library, docker): dry-run no-op, apply, accepted-risks never
  touched, full drift detect→resolve, unmanaged files untouched. Guarded by `v028-live`.
- **Digest-pinning policy decided.** dev/onboarding = readable tags; production/hardened =
  digest-pinned overrides. Digests re-verified (all MATCH); hardened example added
  (`examples/hardened/sentinel-shield-hardened.snippet.yml`).
- **v1.0 RC: NOT recommended.** (4)(5)(6) closed; (7) has a live CI run with residuals → next is
  **v0.1.29** (clean strict CI run: no masking override + DC completes). Self-test **413 → 470**. v1.0 NOT reached.

## v0.1.27 — Dependency-Check consumer CVE coverage + npm-vocab fix + local strict evidence
**Maturity: OWASP Dependency-Check live-validated on a DEPENDENCY-RICH consumer (non-zero CVE buckets).**
- **Consumer run.** Real DC on `zenchron-tools` (private; 218 Composer + 610 npm → 9,289 analyzed
  deps): **7 vulnerable deps / 11 vulns**, collector → **6 high / 3 medium** (`fail`), 89 s (warm
  cache). Closes the v0.1.26 thin-self-scan caveat. Raw artifact kept **local/gitignored** (consumer
  private, this repo public); aggregate counts only. [`dependency-check-consumer-evidence-v027.md`](dependency-check-consumer-evidence-v027.md).
- **Real bug fixed.** Collector dropped npm `MODERATE` severities → **3 real moderate CVEs invisible**
  to the strict `medium` gate. Now mapped `MODERATE→medium` (strengthens the gate; not a weakening).
  Guarded by `npm-vocab.json` fixture + `self-test v027-live`.
- **npm caveat.** Node-Audit online analyzer was HTTP-429 rate-limited → npm-source coverage partial
  (NVD/RetireJS complete). External limit, not a SS failure.
- **Strict — LOCAL consumer evidence.** Real engine on the consumer summary: baseline FAIL (6 high),
  strict FAIL (6 high + 3 medium + missing_sbom). Nothing suppressed. **Live strict CI run still
  outstanding; strict NOT production-ready.**
- **Digest pinning re-verified** (2026-06-15): DC/Semgrep/Grype/Dockle digests all **MATCH** prior
  records (reproducible).
- Self-test **397 → 413** (`v027-live`). **v1.0 NOT reached; NOT recommending RC** — next is v0.1.28
  (install/sync breadth + live strict CI).

## v0.1.26 — Dependency-Check live validation (NVD-key) + strict consumer evidence
**Maturity change: OWASP Dependency-Check `experimental` → `live-validated` (execution path).**
- **First real `dependency-check.json`.** A real OWASP Dependency-Check run, authenticated with an
  **NVD API key** (`SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`, passed via a `0600 --propertyfile`),
  produced a **valid 4.2 KB artifact** (5 deps, 0 vulns), collector-parsed to `pass` 0/0/0. Runtime
  **153 s**; NVD full dataset (357,201 records) downloaded with the key — **no HTTP 429** (the v0.1.25
  blocker is gone). Committed evidence: `tests/fixtures/live-evidence/dependency-check-real.json`;
  full record in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
  **Caveat:** thin **self-scan** surface — non-zero severity buckets not yet exercised on a
  dependency-rich consumer, so the promotion is execution-path live-validation, not full severity proof.
- **NVD key handling:** never logged, never in the report, never committed (verified). Leak-safe
  plumbing regression-guarded by `self-test v026-live` (key off argv / off logs / propertyfile).
- **Strict consumer evidence:** real engine baseline-PASS / strict-FAIL **dry-run** on a controlled
  fixture (strict fails only on `medium_vulnerabilities` + `style_violations`, nothing suppressed) —
  [`strict-mode-consumer-evidence-v026.md`](strict-mode-consumer-evidence-v026.md). **Strict is NOT
  marked production-ready** (needs a live strict CI run on a real consumer).
- Self-test **375 → 397** (`v026-live`: real NVD-backed artifact, leak-safe key, preserve-on-nonzero,
  no-fake-clean, strict baseline/strict flip).
- **v1.0 NOT reached.** Chief-blocker execution path CLOSED; remaining: DC on a dependency-rich
  consumer, install/sync beyond `laravel-react-docker`, full default digest pinning, a live strict run.

## v0.1.25 — live evidence closure (real local scanner runs; no consumer-CI promotions)
This sprint ran **real scanners** and produced **real artifacts** (a step beyond fixtures):
- **Checkov 3.3.0** → 16 real iac_violations; **Grype 0.114.0** → 1 real medium; **Deptrac 4.6.1** →
  real deptrac.json (2 violations / 0 clean). All parsed by their collectors. Real **strict-mode
  engine** run: baseline PASS / strict FAIL. See [`live-evidence-v025.md`](live-evidence-v025.md).
  These are **local tool-execution validations**, NOT consumer-CI promotions (maturity labels unchanged).
- **OWASP Dependency-Check:** real cold run **failed on NVD HTTP 429** (API key required); wrapper
  correctly reported `unavailable` (no fake-clean). **Attempted, NOT live-validated — proven blocked
  by an external constraint.** Anti-fake hardening confirmed under real failure.
- **Real code fixes:** zap-full collector input gap CLOSED; code-enforced Nuclei template-path guard
  (`ss_nuclei_template_check`; `ss_dast_check` unchanged).
- Self-test 349 → **375** (`v025-live`: real artifacts, zap-full, nuclei guard, regulated, 3 workflow rules).
- **v1.0 NOT reached** (5/7 hard gates; Dependency-Check live validation + strict-on-consumer outstanding).

## v0.1.24 — enterprise production closure (no promotions)
Fifteen-agent sprint. No maturity promotions; blocker burn-down + evidence depth:
- **Dependency-Check:** real live-evidence ATTEMPT — evidence workflow pushed to a non-default
  consumer branch; dispatch blocked (workflow_dispatch needs default branch); **no artifact →
  still attempted, NOT live-validated.** See `dependency-check-live-evidence-v024.md`.
- **Self-test:** grown with `v024-collectors` (full 34-collector fixture library iterated),
  `v024-coverage` (dep-check hardening, modes-v024 strict/regulated enforcement, IaC/deptrac/arch,
  DAST incl. the zap-full explicit-input gap, every workflow upload guarded), `v024-docs` (doc honesty).
- **Adoption:** per-profile install/sync productization matrix + quickstart; profile adoption guides +
  override examples for all 5 stacks + every mode.
- **Realism fixtures:** strict/regulated, ZAP baseline/full, Nuclei, IaC (tf/k8s/compose +
  checkov/conftest/terrascan), Deptrac, architecture — collector mappings tested (experimental/manual unchanged).
- **Supply-chain:** all 3 scanner digests re-verified live = MATCH; reproducibility/update/rollback.
- **Docs hygiene:** maturity audit found **0 contradictions**; fixed stray cruft tags + 6 broken links.
- **v1.0:** `v1-closure-v024.md` — explicitly **NOT reached**; Dependency-Check live validation is the chief blocker.

## v0.1.23 — enterprise readiness burn-down (no promotions)
Ten-lane sprint. No maturity promotions; blocker burn-down + evidence prep:
- **Dependency-Check:** real consumer run **attempted** (gh auth + network confirmed) — blocked
  because the evidence workflow is not yet deployed on the consumer; **still attempted, NOT
  live-validated**. Plan + clean/warm fixtures added ([`dependency-check-evidence-plan.md`](dependency-check-evidence-plan.md)).
- **Adoption:** Symfony install fixture; profile-compatibility table; install/sync reliability
  (audit/rollback/troubleshooting/checklist).
- **Strict/regulated:** gate-promotion policy + 24-gate readiness matrix (verified vs resolve-gates);
  executable mode fixtures now enforced in self-test (strict fails style/iac/medium; regulated fails dast).
- **DAST:** controlled-pilot readiness + approval template (DAST still never enabled; fail-closed proven in self-test incl. non-http rejection).
- **IaC/architecture:** Terraform/k8s/compose/deptrac/architecture fixtures + readiness doc; collector mappings tested (experimental/only-if-configured).
- **Supply-chain:** all 3 scanner digests re-verified live against Docker; reproducibility + version-update process; self-test asserts no validated scanner pinned to `:latest`.
- **v1.0:** [`v1-readiness.md`](v1-readiness.md) defines the path — **v1.0 NOT reached**; Dependency-Check live validation is the chief outstanding blocker.
- **Self-test:** 271 → **312 checks** (`v023-coverage`, `v023-regression`, `install-matrix`+symfony).
- **No v1.0 claim.** Engine `proven`; most non-core scanners `supported`/`experimental`.

## v0.1.22 — acceleration sprint (adoption/evidence/hardening; no promotions)
No maturity promotions. Closure work only:
- **Dependency-Check:** still **attempted, NOT live-validated**. Added the dedicated evidence
  workflow `sentinel-shield-dependency-check.yml` (the path to the first real artifact). Not faked.
- **Adoption:** new `symfony` + `node-react` profile manifests; all manifests enriched with
  recommended PR-fast/main-gate/scheduled tool lists; install/sync productization guide.
- **Strict/regulated readiness:** `strict-mode-readiness.md` + `regulated-mode-readiness.md` define
  pre-flight conditions and name the gates too immature to enable by default (OSV/CodeQL coarse
  severity, Dependency-Check attempted, Deptrac/IaC only-if-configured, DAST/AI manual/non-gating).
- **Product contract:** `product-contract.md` declares stable vs experimental surfaces + pre-1.0
  migration policy. README links the core docs.
- **Hardening:** `if: always()` uploads + digest-override env vars across all templates; self-test
  grown to 271 checks (install-matrix, mode-readiness, v022-fixtures, workflow-sanity hardening).
- **No v1.0 claim.** Engine stays `proven`; most non-core scanners stay `supported`/`experimental`.

- **Scanner image digests resolved (not invented), 2026-06-10:** Semgrep 1.165.0
  (`sha256:f4791a54…bfed1b`, consumer-verified), Grype v0.114.0 (`sha256:7a9fc7f8…01dd28`,
  live-validated), Dockle v0.4.15 (`sha256:eade932f…7abe6b9`, live-validated). Templates keep
  readable tags + digest overrides; consumers pin by digest before production
  ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)). This is supply-chain
  hardening, **not** a maturity change — Grype/Dockle/Semgrep stay as promoted in v0.1.20.
