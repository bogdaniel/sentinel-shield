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
| Main-branch gate (`sentinel-shield-main.yml`) | `template-only` | `workflow_dispatch`-only; not dispatchable from a feature branch; never live-run |
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

## 5. Supported but not yet proven

Collector + deterministic self-test fixture exists; **no live consumer run** yet:

- npm audit, ESLint, Vitest/Jest adapters, Deptrac, Syft (SBOM evidence), Psalm,
  third-party Semgrep channel.

These were `not-configured` on the pilot (the runners correctly reported `unavailable` — no fake
output). To promote: run on a consumer that configures them and cite the run.

## 6. Experimental / template-only capabilities

- **Experimental** (coarse parser, live-validate before trusting severity): CodeQL (SARIF
  `level→severity`), OSV-Scanner (all→high unless normalized), Grype, OWASP Dependency-Check,
  OpenSSF Scorecard, TruffleHog, Checkov, Conftest/OPA, Terrascan, Dockle, Trivy-image.
  actionlint/zizmor run **advisory** in self-test.
- **Template-only**: `sentinel-shield-main.yml`, `sentinel-shield-scheduled.yml` (and the
  combined `sentinel-shield.yml` against a real consumer pipeline).

## 7. Known product gaps

- **Main-gate has no live validation path.** `sentinel-shield-main.yml` is `workflow_dispatch`-only
  and cannot be dispatched from a feature branch before merge — so its scanners cannot be promoted
  past `experimental`. Needs a product-level validation strategy (Phase 3 in the roadmap).
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
</content>
</invoke>
