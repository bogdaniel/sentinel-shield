# Main-Gate Validation Strategy (v0.1.17)

How a consuming project validates Sentinel Shield's **main-gate scanners** (CodeQL, OSV-Scanner,
Trivy-fs, Syft, Grype, Dependency-Check, Deptrac, architecture tests, Checkov, Conftest, Terrascan,
Dockle) **from a branch or PR**, without first merging an unproven workflow to the default branch.

## 1. Why `workflow_dispatch` workflows can't run from a branch first

GitHub Actions only makes a `workflow_dispatch` workflow **dispatchable once a version of that
workflow file — containing the `workflow_dispatch` trigger — exists on the repository's default
branch.** Concretely:

- The "Run workflow" button and the `POST .../workflows/{id}/dispatches` API enumerate workflows
  from the **default branch**. A workflow that exists only on a feature branch is not listed and
  cannot be dispatched.
- Even when you later pick a non-default branch as the dispatch *ref*, the trigger must already be
  registered from the default branch for the workflow to be eligible at all.

So a brand-new `sentinel-shield-main.yml` added **only on a PR branch** has no way to be run before
that PR merges.

## 2. Why this blocks first-time validation of `sentinel-shield-main.yml`

It is a chicken-and-egg problem:

- To **dispatch** `sentinel-shield-main.yml` you must first **merge** it to the default branch.
- But you don't want to **merge** an **unvalidated** main-gate workflow (it could be misconfigured,
  mis-wire artifacts, or gate incorrectly) — merging-to-validate inverts the safety order.

That is exactly why every main-gate scanner has stayed `experimental`/`template-only`: there was no
branch-safe way to run them once and capture real `reports/raw/*` evidence.

## 3. Why permanently leaning on zenchron-tools is wrong

zenchron-tools is a **pilot evidence source**, not the product
([`pilot-consumers.md`](pilot-consumers.md)). Using one specific consumer's repo as a permanent
validation rig:

- Couples a product capability to one project's branch/secret/runner state.
- Doesn't generalize — the next consumer hits the same dispatch wall.
- Risks "validated on zenchron" masquerading as "the product validates this," which is the exact
  honesty trap this release avoids.

The product must own a validation path that works for **any** consumer.

## 4. What Sentinel Shield provides instead

A **Sentinel-Shield-owned local/CI harness** —
[`scripts/run-main-gate-validation.sh`](../scripts/run-main-gate-validation.sh) — that runs the
same deterministic main-gate **wrappers/audits** the workflow would run, from **any branch or PR**,
producing the **identical `reports/raw/*` contracts** the summary builder consumes. No
`workflow_dispatch`, no merge-first, no per-consumer rig. It never fakes a report: a missing binary
or unmet precondition is recorded `unavailable`.

## Option comparison

| Option | What it is | Verdict |
| --- | --- | --- |
| **A — Merge workflow first, then dispatch** | Land `sentinel-shield-main.yml` on default, then dispatch from branches. | **Correct steady-state**, but cannot do the **first** validation (merge-before-validate). Use *after* A first run via D. |
| **B — Reusable workflow on default branch** | A `workflow_call` reusable workflow already on default. | Still needs the reusable workflow on the **default branch** first → same chicken-and-egg for the *first* landing. |
| **C — One workflow + `validation_scope` input** | Add `validation_scope: baseline\|pr-fast\|main` to the already-present managed workflow. | Avoids a new file, but bolts heavy main-gate scanners onto the PR-safe managed workflow and risks accidental gating. **Optional, documented, not default.** |
| **D — Local script harness** | `run-main-gate-validation.sh` runs wrappers from any branch/CI step. | **Recommended for first validation.** Branch-safe, no merge, no dispatch, deterministic, honest unavailability. |
| **E — Sandbox fixture repository** | A throwaway repo that hosts the workflow to dispatch. | Works but heavyweight, drifts from the real consumer, extra repo to maintain. Fallback only. |

## Recommended product strategy

1. **First validation: Option D.** Run `run-main-gate-validation.sh --all` on the consumer's branch
   (locally or as a normal PR job — `on: pull_request`, which has **no** dispatch limitation).
   Capture real `reports/raw/*` + `main-gate-validation-tools.json`, feed the summary builder,
   resolve + enforce. Record cited evidence to promote a tool from `supported`→`live-validated`.
2. **Steady-state: Option A.** Once `sentinel-shield-main.yml` is validated by D and merged to the
   default branch, normal `workflow_dispatch` / `push` runs take over.
3. **Optional: Option C** only if a team explicitly wants a single workflow with a scope input —
   documented as advisory, never auto-enabling main gating on PRs.

> The harness existing does **not** make any scanner `live-validated`. It makes validation
> *possible from a branch*. A tool is promoted only when it actually ran and produced a real report
> with cited evidence — see [`production-readiness-audit.md`](production-readiness-audit.md) and
> [`product-status.md`](product-status.md).

## Branch-safe PR validation job (sketch)

```yaml
# .github/workflows/main-gate-validation.yml  (on: pull_request — no dispatch limitation)
name: main-gate-validation
on: pull_request
permissions: { contents: read }
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@<pinned-sha>
        with: { persist-credentials: false }
      # check out Sentinel Shield at a pinned ref into tools/sentinel-shield, then:
      - run: sh tools/sentinel-shield/scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all
      - run: sh tools/sentinel-shield/scripts/build-security-summary.sh --raw-dir reports/raw --output reports/security-summary.json --project-name "$GITHUB_REPOSITORY" --project-type laravel
      - uses: actions/upload-artifact@<pinned-sha>
        with: { name: main-gate-validation, path: reports }
```

This runs every main-gate tool that the runner has installed, records the rest as `unavailable`,
and uploads real evidence — all before `sentinel-shield-main.yml` is ever merged.
</content>
