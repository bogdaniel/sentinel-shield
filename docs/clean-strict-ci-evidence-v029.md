# Clean Strict-Mode CI Evidence (v0.1.29)

> **Scope.** A **clean** live consumer CI run of the Sentinel Shield gate — baseline and strict
> behavior clearly attributable, the strict-only delta **visible**, the Dependency-Check CI status
> documented exactly, artifacts uploaded, nothing suppressed. "Clean" does **not** mean "green."
> Canonical registry: [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## Run

| Field | Value |
|---|---|
| Consumer | `bogdaniel/zenchron-tools` (private) |
| **Run ID** | **`27513388096`** — conclusion **success** (evidence-only; enforce steps capture exit without failing the job) |
| Branch | `ss-v029-strict-evidence` (push-triggered; off `main` — consumer `deploy.yml` triggers on push to main) |
| SS version | pinned `43bf2ce92b8e7c53eedfd6bdfc27c9ab6d3bf3c7` (v0.1.29 integration — propertyfile container-readable fix) |
| Wall-clock | ~41 min (DC ran the full cold NVD download this time — see below) |
| Real scanners in summary | OSV-Scanner, Trivy-fs, Syft SBOM → **6 high, 4 medium**, SBOM present |

## Three attributable views (the clean delta)

The workflow resolves gates in **three** clearly-labelled views so the strict-only delta is visible
even though the consumer's profile masks it:

| View | Resolve | Result | Failed gates | medium gate |
|---|---|---|---|---|
| **baseline** | pure mode default | **fail** | `high_vulnerabilities` | n/a (not gated in baseline) |
| **strict (EVIDENCE)** | pure mode default (bypasses consumer profile) | **fail** | `high_vulnerabilities`, **`medium_vulnerabilities`** | `enabled:true, value:4, result:fail` |
| **strict (CONSUMER)** | consumer-effective (honors `.sentinel-shield/profile.yaml`) | **fail** | `high_vulnerabilities` | `enabled:false, value:4, result:skipped` |

**The strict-only delta is the 4 medium CVEs** — gated in the EVIDENCE view, skipped in the CONSUMER
view. Nothing is suppressed by Sentinel Shield: the CONSUMER skip is the consumer's **own explicit**
`fail_on.medium_vulnerabilities: false`, shown transparently next to the EVIDENCE view.

### Override precedence (documented)

`resolve-gates.sh` resolution order is **mode defaults → profile/consumer overrides win** (overrides
are never hidden; the resolver reports them). So an explicit `fail_on.<key>: false` in a consumer
profile overrides even `--mode strict`. The EVIDENCE view resolves with **no consumer profile**
(pure mode default) so strict's true gating is visible; the CONSUMER view honors the override so the
consumer's real posture is also recorded. Regression-guarded by `self-test v029-live` (56)/(57).

## Dependency-Check CI status — exact blocker (honest)

**The v0.1.28 blocker is FIXED.** That run failed at 14 s with
`FileNotFoundException ... /ss-secret/dependency-check.properties (Permission denied)` — the leak-safe
propertyfile was `0600`/`0700` owned by the host UID, unreadable by the DC **container's** different
UID on Linux Docker. v0.1.29 makes the ephemeral propertyfile **container-readable** (the key stays
off the command line / logs / report / commits). In this run DC got **past** that error and ran the
full ~40-min cold NVD download.

**DC then hit a different, known operational error and produced no report:**

```
[WARN] Unable to update 1 or more Cached Web DataSource, using local data instead.
[ERROR] Unable to obtain an exclusive lock on the H2 database to perform updates
[ERROR] No documents exist
[ERROR] Unable to continue dependency-check analysis.  (exit 13)
[sentinel-shield] dependency-check unavailable: ... no fake-clean report (no report written).
```

This is OWASP Dependency-Check's **H2 database lock / empty-datastore** failure — the `actions/cache`
`restore-keys: nvd-Linux-` restored the **partial/empty** cache the failed v0.1.28 run left behind,
so the H2 datastore could not be locked/updated and held no documents. The wrapper correctly wrote
**no fake-clean report** (anti-fake behavior held under a real failure).

- **The Sentinel Shield code blocker (propertyfile perms) is closed.** The remaining issue is
  **operational** (seed a clean NVD/H2 cache via a dedicated warming run, then restore it), not a gate
  -engine defect.
- **Local DC evidence stands** as the real DC findings: v0.1.27, `zenchron-tools`, 9,289 deps →
  **6 high / 3 medium** ([`dependency-check-consumer-evidence-v027.md`](dependency-check-consumer-evidence-v027.md)).
- **Next:** a cache-warming workflow run (DC alone, fresh cache key, completes the H2 build), then
  restore it in the evidence run so DC completes in CI.

## What this is / is NOT

- **IS:** a clean, attributable live strict CI run with the strict-only delta visible and the
  consumer-mask shown transparently; DC's exact CI blocker documented; nothing suppressed.
- **IS NOT:** a "green" strict run (it correctly fails on 6 real high CVEs — consumer remediation is
  out of scope), and **not** a DC-completes-in-CI result. Strict mode is **not production-ready** for
  this consumer until they remove the medium override and triage the high/medium findings.

## Reproduce

Workflow: consumer `.github/workflows/sentinel-shield-strict-evidence.yml` (branch
`ss-v029-strict-evidence`). Locally, the 3 views on the real CI summary:

```sh
S=/path/to/security-summary.json   # high=6, medium=4
for v in "baseline|baseline" "strict|strict-evidence"; do
  m=${v%%|*}; d=$(mktemp -d)
  sh scripts/resolve-gates.sh --mode "$m" --profile "$d/none.yaml" --output-dir "$d" --format env   # pure default
  sh scripts/enforce-gates.sh --gates-env "$d/sentinel-shield-gates.env" --summary "$S" --output-dir "$d" --format json
done
# consumer-effective: resolve WITHOUT --profile override-bypass (reads .sentinel-shield/profile.yaml)
```
