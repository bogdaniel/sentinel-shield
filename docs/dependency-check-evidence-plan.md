# OWASP Dependency-Check — Consumer Evidence Plan (v0.1.23)

Concrete, runnable plan to produce the **first real** `dependency-check.json` artifact on a real
consumer and promote OWASP Dependency-Check from *attempted* to *live-validated*. This is the
operational companion to [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)
(the *why*) and the registry [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (the *record*).

> Status (v0.1.23): **attempted, NOT live-validated.** No real `dependency-check.json` artifact exists.
> This document is the validation *path* and the promotion *checklist* — it is **not** a validation
> claim. Dependency-Check stays unpromoted until a real, cited artifact is recorded in
> `main-gate-live-evidence.md`. See "Real run attempt (task 14)" below for the honest negative result
> from this sprint.

## Target consumer

- **Consumer repo:** `bogdaniel/zenchron-tools` — the same consumer that produced the live evidence
  for CodeQL / OSV / Trivy / Syft (run `27214865086`) and the execution-path evidence for
  Semgrep / Grype / Dockle (run `27239206382`). Using the existing pilot keeps the evidence
  comparable and avoids standing up a new consumer.
- **Sentinel Shield version under test:** the `sentinel-shield-dependency-check.yml` evidence
  workflow (v0.1.22), checked out from this repo at the pinned `SENTINEL_SHIELD_REF`.

## Prerequisites

1. The evidence workflow `templates/workflows/sentinel-shield-dependency-check.yml` is copied into the
   consumer at `.github/workflows/sentinel-shield-dependency-check.yml` (it is **not** deployed there
   yet — see the real-run attempt section).
2. In that copy, set `SENTINEL_SHIELD_REPOSITORY` to this repo (`YOUR_ORG/sentinel-shield` → the real
   slug) and pin `SENTINEL_SHIELD_REF` to a full SHA before production.
3. `gh` authenticated with `workflow` + `repo` scope for the consumer (the sprint sandbox has this; it
   does **not** have write access to push a workflow into the consumer — see below).

## How to dispatch the workflow

The workflow declares `on: workflow_dispatch` (task 3 — verified below), so once it is committed to the
consumer's default branch a maintainer triggers it with:

```sh
gh workflow run sentinel-shield-dependency-check.yml -R bogdaniel/zenchron-tools
# then find the run:
gh run list -R bogdaniel/zenchron-tools --workflow sentinel-shield-dependency-check.yml -L 1
RUN_ID=$(gh run list -R bogdaniel/zenchron-tools \
  --workflow sentinel-shield-dependency-check.yml -L 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" -R bogdaniel/zenchron-tools
```

## First-run warming strategy (task 13)

The **first ever** dispatch on this consumer is a **cold run**: the NVD `actions/cache` has no entry
under `nvd-<os>-<YYYY-MM>` and no prior-month entry for the `restore-keys` prefix to seed from, so
Dependency-Check downloads and indexes the **entire NVD feed** (hundreds of MB) before it analyzes
anything. Plan for it deliberately:

1. **Warming dispatch (cold, expected slow).** Trigger the workflow once with no expectation of usable
   timing. Its only job is to populate `.sentinel-shield/cache/dependency-check` and let `actions/cache`
   save it under this month's exact key at job end. This run may legitimately approach the
   `timeout-minutes: 45` cap (task 9). Treat a timed-out cold run as *cache-not-yet-warm*, not as a
   tool defect — the wrapper discards any partial output and reports `unavailable` (never fake-clean).
2. **Confirm the cache was saved.** After the warming dispatch, check the run's "Restore NVD cache" step
   log for a cache **save** at job end (or `gh cache list -R bogdaniel/zenchron-tools` if available) and
   confirm a `nvd-Linux-<YYYY-MM>` entry now exists.
3. **Evidence dispatch (warm, the run you actually cite).** Re-trigger the workflow. This run restores
   the just-saved cache under the **exact** monthly key, fetches only the NVD **delta**, and finishes in
   a few minutes. **This warm run is the one whose `dependency-check.json` you download and cite** — its
   timing is representative of steady state, and its artifact is the clean signal for promotion.
4. **Month-rollover note.** On the first dispatch after the calendar month rolls over there is no exact
   key, so the `restore-keys` prefix (`nvd-Linux-`) restores last month's cache (partial-warm: between
   warm and cold). Budget one partial-warm run per month; everything else in-month is warm.

## Cold-run CI-budget reality (task 8)

A cold run **will not** fit a PR-fast budget and can consume most of the 45-minute window on its own:

- The cold NVD download + index is **many minutes**, network- and NVD-API-dependent, and can approach
  `timeout-minutes: 45`. That cap is intentional: it bounds a stuck cold download so the job fails
  cleanly (wrapper discards partial output → honest `unavailable`) instead of hanging.
- This is exactly why Dependency-Check is **PR-fast: disabled · scheduled/manual only** — see
  [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md) ("Why the cold NVD
  download fails CI budgets"). Do **not** attempt to make a cold run fit a PR budget; warm it first
  (task 13) and cite the warm run.
- CI-minute guidance: budget **one cold run per brand-new consumer** + **one partial-warm run per
  month** (rollover) + **fast warm runs** for everything else.

## How to download the artifact

The upload step is `if: always()` (task 7), so the artifact exists even when the scan exits non-zero on
findings:

```sh
gh run download "$RUN_ID" -R bogdaniel/zenchron-tools \
  -n sentinel-shield-dependency-check -D ./dc-evidence
# the native report lands at:
ls -l ./dc-evidence/reports/raw/dependency-check.json
```

## How to confirm the collector parses it

Run the real collector against the downloaded artifact and confirm it emits the vuln buckets (not
`unavailable`):

```sh
scripts/collectors/dependency-check.sh --input ./dc-evidence/reports/raw/dependency-check.json
```

Expected: a JSON object with `status` plus `critical` / `high` / `medium` counts. A clean scan looks
like `{"status":"pass","critical":0,"high":0,"medium":0}` **with a `dependencies` array present** —
that is a real clean scan, distinct from `unavailable` (no file). The
[`tests/fixtures/dependency-check/clean.json`](../tests/fixtures/dependency-check/clean.json) fixture
encodes exactly this warm-cache clean shape (a dependency with an empty `vulnerabilities: []`), and its
sibling [`with-findings.json`](../tests/fixtures/dependency-check/with-findings.json) encodes the
findings shape. The warm-cache marker
[`tests/fixtures/dependency-check/warm-cache/.nvd-cache-marker`](../tests/fixtures/dependency-check/warm-cache/.nvd-cache-marker)
simulates a populated NVD data dir so a self-test can assert "cache present → warm path."

Quick local sanity of the parse logic (no scanner needed):

```sh
jq 'if has("dependencies") then ([.dependencies[]?.vulnerabilities[]?.severity // empty | ascii_upcase]) as $s | {critical:([$s[]|select(.=="CRITICAL")]|length), high:([$s[]|select(.=="HIGH")]|length), medium:([$s[]|select(.=="MEDIUM")]|length)} else {critical:(.critical//0), high:(.high//0), medium:(.medium//0)} end' \
  tests/fixtures/dependency-check/clean.json
# -> {"critical":0,"high":0,"medium":0}
```

## What to record in `main-gate-live-evidence.md` to promote

Only after a **real warm run** produces a **real** `dependency-check.json` that the collector parses,
update the OWASP Dependency-Check row in [`main-gate-live-evidence.md`](main-gate-live-evidence.md) with:

| Field | Value to record |
|---|---|
| Consumer | `bogdaniel/zenchron-tools` |
| Workflow / Run ID | `sentinel-shield-dependency-check.yml` / **`<real RUN_ID>`** (the **warm** evidence run, not the warming dispatch) |
| Artifact (size, validity) | `reports/raw/dependency-check.json` (`<KB>`, valid native DC JSON, `reportSchema`/`scanInfo.engineVersion` present) |
| Summary mapping | the collector's `critical/high/medium` output on that artifact (e.g. `0/0/0` clean, or the real counts) |
| Promoted maturity | **live-validated** — only with the cited real artifact |
| Known limitations | warm-cache required (cold run not PR-viable); severity buckets best-effort; findings may DUPLICATE OSV/Trivy/Grype |
| Next validation target | monthly rollover (partial-warm) timing; triage any real findings |

Then, and only then, flip Dependency-Check to *live-validated* in `product-status.md` (Agent A does
**not** edit shared docs in this sprint — hand the cited run to the captain to record).

Promotion rule (unchanged, honesty-first): **no run ID or artifact is ever invented.** If no real
artifact exists, the row stays `PENDING` / *attempted, NOT live-validated*.

## Workflow conformance verification (tasks 3–9)

Verified against `templates/workflows/sentinel-shield-dependency-check.yml` (v0.1.22). All quoted lines
are present; **no edit was made** — this is a read-only audit.

- **task 3 — `workflow_dispatch` present:** `on:` block contains
  `  workflow_dispatch:   # maintainer-triggered: produce the first real dependency-check.json artifact`.
- **task 4 — cache key uses month/year:** the month stamp step
  `run: echo "ym=$(date -u +%Y-%m)" >> "$GITHUB_OUTPUT"` feeds the cache key
  `key: nvd-${{ runner.os }}-${{ steps.month.outputs.ym }}` (`ym` = `YYYY-MM`).
- **task 5 — restore-keys allow warm reuse:**
  ```yaml
  restore-keys: |
    nvd-${{ runner.os }}-
  ```
  the OS-prefixed restore key seeds a partial-warm run from the most recent prior cache.
- **task 6 — foreground container only:** the scan step invokes the audit wrapper directly
  (`sh ${{ env.SENTINEL_SHIELD_PATH }}/scripts/audits/dependency-check.sh reports/raw/dependency-check.json || true`);
  the wrapper runs `docker run --rm` (foreground), **never** `docker run -d`. The step header comment
  states: "FOREGROUND only — timeout-minutes + SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT only work when
  the scanner is not detached."
- **task 7 — artifact upload `if: always()`:**
  `- uses: actions/upload-artifact@v4` with `if: always()   # scanner failure/findings must NOT erase the raw dependency-check.json`.
- **task 9 — max-runtime guard that does NOT kill the upload:** the scan step carries
  `timeout-minutes: 45`. Crucially, `timeout-minutes` is scoped to **that step only** — the upload is a
  **separate** step gated by `if: always()`, so a scan that hits the cap still runs the upload. The
  in-container cap `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT: 40m` (< 45) lets the wrapper stop and
  discard partial output *before* GitHub force-kills the step, keeping the result an honest
  `unavailable` rather than a lost job. **All checks pass; nothing to report to the captain.**

## Real run attempt (task 14) — honest result

A real consumer run was **attempted** from this sprint environment on **2026-06-10**:

- `gh auth status` → authenticated as `bogdaniel` (scopes include `repo`, `workflow`).
- `gh run list -R bogdaniel/zenchron-tools -L 1` → succeeded (network + read access work).
- `gh api repos/bogdaniel/zenchron-tools/actions/workflows` → the consumer has
  `sentinel-shield`, `sentinel-shield-main-validation`, `sentinel-shield-main-gate-evidence`,
  `sentinel-shield-pr-fast-validation` (plus `deploy`, `gitleaks`) — but **NOT**
  `sentinel-shield-dependency-check.yml`. The evidence workflow is **not deployed** on the consumer.
- `gh api repos/bogdaniel/zenchron-tools/actions/artifacts` filtered for `dependency-check` → **no
  artifact** named `dependency-check` / `sentinel-shield-dependency-check` exists.

Dispatching the evidence workflow would first require committing
`sentinel-shield-dependency-check.yml` into the consumer's `.github/workflows/` (a write to another
repo) and then paying the cold-NVD warming cost — neither is in scope for this lane, and the cold run
cannot be completed/verified inside this sprint.

**Honest negative result:** real run attempted via `gh`; not possible to complete in this environment
(evidence workflow not deployed on the consumer; producing a real artifact requires deploying it +
a cold NVD warm-up + a follow-up warm run). **Dependency-Check remains attempted, NOT live-validated.**
No run ID or artifact was fabricated. The PENDING row in `main-gate-live-evidence.md` stands.
