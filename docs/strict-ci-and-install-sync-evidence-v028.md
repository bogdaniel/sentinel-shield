# Strict-Mode CI + Install/Sync Breadth Evidence (v0.1.28)

> **Scope.** (A) First **live consumer CI** run of the Sentinel Shield gate in baseline AND strict,
> and (B) install/sync **breadth** validation across 8 profiles. Maturity claims defer to
> [`product-status.md`](product-status.md); canonical registry is
> [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## A. Strict-mode live CI evidence (Lane A)

**Real GitHub Actions run on a consumer.** Evidence-only, non-required, push-triggered on a dedicated
branch (NOT `main` — the consumer's `deploy.yml` triggers on push to `main`, so the workflow was kept
off the default branch deliberately). No app code, accepted-risks, or findings were touched.

| Field | Value |
|---|---|
| Consumer | `bogdaniel/zenchron-tools` (private) |
| Workflow | `.github/workflows/sentinel-shield-strict-evidence.yml` (evidence-only, non-required) |
| Branch | `ss-v028-strict-evidence` (push-triggered; off `main`) |
| **Run ID** | **`27512789768`** — conclusion **success** (job succeeds; enforce steps capture exit without failing the job) |
| SS version | pinned `84b5257f1d97e15ef5a4f76d4825787da3f1ed7a` (v0.1.27) |
| Scanners that ran | OSV-Scanner, Trivy-fs, Syft SBOM |
| Summary | **6 high, 4 medium**, SBOM **present** |

### Enforcement result (consumer's EFFECTIVE config)

The consumer's committed `.sentinel-shield/profile.yaml` is `mode: baseline` with an **explicit
`fail_on.medium_vulnerabilities: false`** override.

| Mode | Result | Failed gates |
|---|---|---|
| `baseline` | **fail** | `high_vulnerabilities` |
| `strict` | **fail** | `high_vulnerabilities` |

**Strict == baseline here** — *not* because strict is weak, but because the consumer **explicitly
disabled the medium gate** in their profile, and `resolve-gates.sh` resolution order is
"mode defaults → **profile overrides win**" (by design). **Sentinel Shield suppressed nothing** —
the medium gate shows `enabled:false, result:skipped` purely from the consumer's own override.

### Strict delta on the SAME real CI summary (pure mode-default resolve)

Resolving with mode defaults (no consumer override) against the real CI summary shows the gate strict
*would* add:

| Mode | Failed gates |
|---|---|
| `baseline` | `high_vulnerabilities` |
| `strict` | `high_vulnerabilities`, **`medium_vulnerabilities`** |

So strict's real delta is the 4 medium CVEs — masked in the consumer run by their explicit override.

### Honest residuals

- **Dependency-Check did NOT complete in this CI run** (≈1 min wall-clock; a cold NVD pull needs
  10–30 min). The CI findings are from OSV/Trivy/Syft. The **local** dependency-rich DC evidence
  (v0.1.27, `zenchron-tools`, 6 high / 3 medium) stands. A warm-cache CI re-run is needed for DC in CI.
- **Strict did not run green** — it correctly failed on **6 real HIGH CVEs**. Strict-vs-baseline
  delta was masked by the consumer's explicit medium override.
- **Strict is NOT production-ready.** Before strict adoption the consumer must: (1) remove
  `fail_on.medium_vulnerabilities: false`, (2) triage/accept-risk the 6 high + 4 medium findings,
  (3) ensure DC completes (warm NVD cache in CI).

**What this closes:** a **live consumer CI run in strict now exists and is cited** (up from v0.1.27's
local-only evidence). It does **not** claim strict production-readiness.

## B. Install/sync breadth (Lane B)

Real install/sync round-trip across **8 profiles** (temp dirs, no network). Each profile: install
dry-run writes nothing; `--apply` creates the managed workflow + `profile.yaml`; `accepted-risks.json`
is **never** created; a real `accepted-risks.json` is **preserved under `--force`**; the full drift
cycle (mutate managed workflow → `sync` detects "managed drift" → `sync --apply --force` resolves);
and an unmanaged project file is **never** modified.

| Profile | dry-run no-op | apply managed | accepted-risks never created | accepted-risks preserved (--force) | drift detect→resolve | unmanaged untouched |
|---|---|---|---|---|---|---|
| laravel-react-docker | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| laravel | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| react | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| node | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| node-react | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| symfony | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| php-library | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| docker | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Regression-guarded by `scripts/self-test.sh v028-live` (and the existing `install-matrix`/`install-sync`).
**Install/sync breadth blocker: CLOSED** across the shipped profiles.

## C. Digest pinning policy (Lane C)

Digests re-verified 2026-06-15 — DC/Semgrep/Grype/Dockle all **MATCH** prior records (see
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)). **Policy:**
**development/onboarding = readable tags** (legible, easy to update); **production/hardened =
digest-pinned overrides** (reproducible, tamper-evident). A hardened digest-pinned example lives at
[`examples/hardened/sentinel-shield-hardened.snippet.yml`](../examples/hardened/sentinel-shield-hardened.snippet.yml).
Rollback + drift guidance: see the digest-pinning doc.
