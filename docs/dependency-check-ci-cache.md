# Dependency-Check CI Cache Reliability

> **Why this exists.** OWASP Dependency-Check stores the NVD dataset in an H2 database
> (`odc.mv.db`) under its data dir. In CI that dir is an `actions/cache`. Two failure modes make DC
> fail *after* a successful NVD download:
>
> 1. **Poisoned cache** — a previous run that failed *before* populating the data dir saved an
>    **empty** cache. A later run restores it and DC reports
>    `Unable to obtain an exclusive lock on the H2 database` / **`No documents exist`** (v0.1.29).
> 2. **Stale lock** — a run killed mid-update (CI timeout / cancelled job) leaves a stale
>    `odc.update.lock` / H2 `*.lock`, so the next run cannot lock the DB.
>
> Sentinel Shield never fakes a clean report under either failure — the wrapper writes **no report**
> and the collector reports `unavailable`.

## The reliability strategy (v0.1.30)

| Layer | Mechanism |
|---|---|
| **Wrapper** (`scripts/audits/dependency-check.sh`) | Before running, deletes stale `*.lock` / `odc.update.lock` from the cache dir (never the NVD data). Keeps valid JSON on non-zero exit; writes no fake-clean report when no JSON. |
| **Fresh cache namespace** | The evidence workflow keys the cache `nvd-v030-<os>-<month>` with `restore-keys: nvd-v030-<os>-` — it can **never** restore the poisoned `nvd-Linux-*` cache from the failed v0.1.28/29 runs. |
| **Conditional save** | The cache is saved **only when `dependency-check.json` was produced** (`actions/cache/save` gated on `DC_OK == '1'`). A failed run can never poison the cache for the next run. |
| **Reset input** | `workflow_dispatch` input `reset_dependency_check_cache: "true"` wipes the data dir before the run (for maintainers dispatching from the default branch). |

## Cache reset behavior

- **Automatic (fresh namespace):** the first run on a new `nvd-v030-*` key starts cold — no stale
  data to restore. This is the default reliable path.
- **Manual:** dispatch the workflow with `reset_dependency_check_cache=true` to wipe
  `.sentinel-shield/cache/dependency-check` before the run. Use this if the v030 cache itself ever
  goes bad.

```yaml
workflow_dispatch:
  inputs:
    reset_dependency_check_cache:
      description: "Reset Dependency-Check NVD cache before run"
      required: false
      default: "false"
```

## H2 lock / "No documents exist" troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to obtain an exclusive lock on the H2 database` | stale `*.lock` from a killed run | the wrapper auto-deletes stale locks; if it persists, reset the cache |
| `No documents exist` | empty/partial cache restored (poisoned) | use the fresh `nvd-v030-*` namespace; never restore `nvd-Linux-*`; conditional-save prevents re-poisoning |
| DC exits non-zero but a valid report exists | findings (expected) | the wrapper KEEPS the report; the collector/gate decides pass/fail |
| No `dependency-check.json` at all | download incomplete / crash | **unavailable, NOT fake-clean** — fix the cause, re-run with reset |

## Key handling (unchanged)

The NVD API key is passed only via `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` → a
container-readable but ephemeral propertyfile (removed on exit). It is **never** on the command line,
in logs, in the report, or committed. See [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
