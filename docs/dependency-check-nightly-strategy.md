# OWASP Dependency-Check — Nightly / Cached Strategy (v0.1.21)

OWASP Dependency-Check is the one main-gate scanner Sentinel Shield has **not** been able to
live-validate, for a concrete operational reason: the cold NVD download is too slow and too
fragile for a PR or one-shot evidence run. This doc defines the **only** reliable way to run it —
a scheduled/nightly job with a persisted NVD cache — and the honesty rules that keep it from ever
emitting a fake-clean report.

> Status (v0.1.21): **attempted, NOT live-validated.** No real `dependency-check.json` artifact
> exists yet. Promotion happens only when a nightly run produces a valid artifact and its collector
> parses it — recorded in [`main-gate-live-evidence.md`](main-gate-live-evidence.md). This document
> is the validation *path*, not a validation claim.

## Why Dependency-Check is not PR-fast

The PR gate targets < 10–15 min wall-clock ([`ci-runtime-budget.md`](ci-runtime-budget.md)). Slow
gates get bypassed. Dependency-Check is disqualified from PR-fast because:

- It needs the **full NVD dataset** (network DB, hundreds of MB) before it can analyze anything.
- Its findings **duplicate** OSV-Scanner / Trivy / Grype (overlapping CVE sources) — it adds
  latency without adding unique PR signal.
- Analysis itself (evidence collection across the dependency tree) takes minutes, not seconds.

So Dependency-Check stays: **PR-fast: disabled · Main: optional/manual · Scheduled: recommended.**

## Why the cold NVD download fails CI budgets

On a fresh runner with an empty data directory, Dependency-Check pulls and indexes the entire NVD
feed before the scan. On the v0.1.20 evidence run (zenchron run 27239206382) this:

- exceeded the CI step budget (cold download + index = many minutes, network-dependent), and
- the **detached** scanner container did not reliably honor the step `timeout-minutes` — a
  `docker run -d` keeps running after the step "times out", burning the job and losing artifacts.

The fix is twofold and both halves are required:

1. **Persist the NVD data dir** across runs so the cold download happens at most once a month.
2. **Run foreground** (never `docker run -d`) so `timeout-minutes` and the wrapper's
   `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT` actually apply. The hardened
   [`scripts/audits/dependency-check.sh`](../scripts/audits/dependency-check.sh) only ever runs
   foreground.

## How to use `actions/cache`

Cache the NVD data directory keyed on the calendar month. The wrapper reads/writes it via
`SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE` (default `.sentinel-shield/cache/dependency-check`), which
the container mounts at `/usr/share/dependency-check/data`.

```yaml
- name: Restore NVD cache (monthly)
  id: nvd-cache
  uses: actions/cache@v4   # pin to a SHA before production
  with:
    path: .sentinel-shield/cache/dependency-check
    # Month/year in the key forces a fresh dataset every month; the restore-key
    # below lets a partially-warm prior cache seed the run so it is never fully cold.
    key: nvd-${{ runner.os }}-${{ steps.month.outputs.ym }}
    restore-keys: |
      nvd-${{ runner.os }}-
```

`steps.month.outputs.ym` is a `YYYY-MM` stamp (e.g. `date -u +%Y-%m` in a prior step). See the
ready-made job in [`templates/workflows/sentinel-shield-scheduled.yml`](../templates/workflows/sentinel-shield-scheduled.yml).

## How to rotate the NVD cache monthly

- The **exact** key embeds `YYYY-MM`, so on the first run of a new month there is no exact hit.
- The **restore-key** prefix (`nvd-<os>-`) restores the most recent prior month's cache, so the run
  starts warm and only fetches the NVD *delta*, not the whole feed.
- `actions/cache` saves the new month's cache under the new exact key at job end.
- GitHub evicts caches not read in 7 days / over the repo size budget — monthly rotation keeps the
  set small (one or two live caches) and guarantees the data never silently goes stale beyond ~1 month.

## How to run manually with `workflow_dispatch`

The scheduled template enables `workflow_dispatch`, so an operator can trigger an on-demand
Dependency-Check run (e.g. to warm the cache for the first time, or to re-scan after a dependency
bump) without waiting for the nightly cron. The first manual run pays the cold-download cost once;
every run after that reuses the cache.

## How to preserve artifacts even on findings

Dependency-Check exits **non-zero when it finds vulnerabilities**. That must not erase the report:

- The wrapper runs the tool with `|| rc=$?` and then **keeps `dependency-check.json` whenever it is
  valid JSON, regardless of exit code** — the Sentinel Shield gate (not the scanner's exit code)
  decides pass/fail.
- The workflow's `actions/upload-artifact` step uses **`if: always()`** so the raw report is
  uploaded even when a later step (summary/enforce) fails the job on real findings.
- A scanner failure therefore **never** erases the raw artifact.

## How to mark unavailable honestly

If the tool cannot run or cannot finish, the result is `unavailable`, **not** clean:

- `MODE=disabled` (default), or no local binary **and** no `…_IMAGE`+docker → wrapper writes **no
  file**; the collector reports `status: unavailable`, counts 0. That means "not scanned," not "clean."
- Tool exits **before producing valid JSON** (timeout, incomplete NVD download, crash) → the wrapper
  **discards any partial/empty/invalid file** and reports `unavailable` with a reason. A half-written
  report can never masquerade as a clean pass.

## How to avoid fake clean reports

The anti-fake rules, enforced by the wrapper and exercised by `scripts/self-test.sh main-gate-exec`:

| Situation | Wrapper behavior | Collector result |
|---|---|---|
| disabled (default) | no file written | `unavailable` |
| enabled, no binary + no image | no file written | `unavailable` |
| enabled, valid JSON, exit 0 | keep `dependency-check.json` | parsed (pass/fail by counts) |
| enabled, valid JSON, **non-zero exit** | keep `dependency-check.json` | parsed (gate decides) |
| enabled, exits without valid JSON | discard partial, report reason | `unavailable` |

There is no code path that writes an empty/zero-finding report on the tool's behalf. "Clean" only
ever comes from the tool actually producing a valid report with zero findings.

## Promotion path

Run the scheduled job (warm cache) on a real consumer, download the resulting
`dependency-check.json`, confirm `scripts/collectors/dependency-check.sh` parses it, then record the
run ID + artifact in [`main-gate-live-evidence.md`](main-gate-live-evidence.md). Only then does
Dependency-Check move from *attempted* to *live-validated* in
[`product-status.md`](product-status.md).
