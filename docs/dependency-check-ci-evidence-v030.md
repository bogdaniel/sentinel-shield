# Dependency-Check CI Evidence (v0.1.30)

> **Headline.** OWASP Dependency-Check now **completes in GitHub Actions CI** — the final v1.0 CI
> blocker is closed. Canonical registry: [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
> Cache/H2 mechanics: [`dependency-check-ci-cache.md`](dependency-check-ci-cache.md).

## Root cause (why v0.1.28/29 failed) and the fix

The v0.1.28 failure was a propertyfile permission bug (fixed v0.1.29). The v0.1.29/30 failure —
`Unable to obtain an exclusive lock on the H2 database` / **`No documents exist`**, even on a **fresh
cache** — was the **same UID class**: the OWASP Dependency-Check container runs as a **non-root**
user, but the bind-mounted NVD data dir + report dir are owned by the host runner UID. Without write
access the container **cannot create or lock the H2 database**, so no NVD records ever load.

**Fix (v0.1.30):** the wrapper `chmod a+rwX` the mounted data + report dirs before the `docker run`
(NVD data and reports are not secret; the key stays only in the propertyfile). Plus cache-reliability
scaffolding: fresh `nvd-v030-*` namespace, conditional cache save (only on a produced report), a
`reset_dependency_check_cache` dispatch input, and stale-lock cleanup.

## Run — DC completes

| Field | Value |
|---|---|
| Consumer | `bogdaniel/zenchron-tools` (private) |
| **Run ID** | **`27530386965`** — conclusion **success** |
| Branch | `ss-v030-strict-evidence` (push-triggered; off `main`) |
| SS version | pinned `7044804bbf3be76ec659abb95409f2bfffe6a799` (v0.1.30 — container-writable data dir) |
| **NVD download** | **357,832 / 357,832 records (100%)** via the API key — **no HTTP 429, no H2 lock** |
| **Artifact** | `reports/raw/dependency-check.json` — **valid, 67 KB**, uploaded |
| Analyzed deps | **69** (committed dependency surface — the CI checkout has no installed `vendor/`/`node_modules`; see limitation) |
| Findings | **3 vulnerabilities** — 1 critical, 1 high, 1 low |
| **Collector** | `dependency-check.sh` → **`status: fail`, 1 critical / 1 high / 0 medium** |
| Runtime | ~4 min (NVD via API + 69-dep analysis in 9 s) |
| Key handling | full NVD download with the key; **0 key occurrences** in artifact/log/commits |

## Strict evidence (DC now contributes; delta still visible)

Merged summary (DC + OSV + Trivy): **1 critical, 7 high, 4 medium**, SBOM present.

| View | Result | Failed gates |
|---|---|---|
| baseline (pure default) | **fail** | `critical_vulnerabilities`, `high_vulnerabilities` |
| **strict (EVIDENCE)** | **fail** | `critical_vulnerabilities`, `high_vulnerabilities`, **`medium_vulnerabilities`** |

DC's critical gates in **both** modes (correct); the strict-only delta is the **4 medium**. Nothing
suppressed.

## Cold vs warm cache

- **Cold** (first attempt): `cache-hit: false` → full **357,832-record** NVD download → valid report →
  the conditional save persisted a **good** cache under `nvd-v030-Linux-2026-06` (a failed run never
  saves, so the cache cannot be poisoned).
- **Warm** (rerun of `27530386965`): **`Cache hit for: nvd-v030-Linux-2026-06` → "Cache restored
  successfully"** → DC completed **without** the full re-download (report written ~30 s after restore),
  conclusion **success**. Cache reuse confirmed end-to-end; no H2 lock, no poisoning.

## Honest limitations

- **CI dependency surface is the committed manifests (69 deps)** — the evidence workflow does not run
  `composer install` / `npm ci`, so transitive `vendor/`/`node_modules` aren't scanned in CI. DC is
  **also** live-validated locally on the **full 9,289-dep** surface (v0.1.27, 6 high / 3 medium). For
  full transitive CI coverage, add an install step before DC (a documented enhancement, not a blocker).
- **Strict is not "green"** — it correctly fails on real critical/high findings; strict stays opt-in /
  non-required by default. Consumer remediation is out of scope.
