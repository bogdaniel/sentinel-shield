# Dependency-Check Live-Evidence Attempt — v0.1.24 (HONEST RESULT)

**Date:** 2026-06-10
**Agent:** Agent A (Lane A, tasks 1-20)
**Outcome (headline):** **ATTEMPTED.** A real, dispatchable evidence-only workflow was pushed to a
**non-default** consumer branch on `bogdaniel/zenchron-tools`. The workflow **could not be
dispatched** because GitHub only registers a `workflow_dispatch` workflow once it exists on the
repository's **default branch** (`main`), and merging to the consumer default branch is explicitly
out of scope (no consumer app/default-branch changes). **No `dependency-check.json` artifact was
produced. Dependency-Check remains ATTEMPTED, NOT live-validated. Nothing was promoted. No run ID
was invented.**

---

## 1-2. Consumer selection & verification (read-only `gh`)

Best consumer: **`bogdaniel/zenchron-tools`** (the established Sentinel Shield pilot; a real
Laravel/PHP + React + Docker app with existing SS workflows).

```
$ gh auth status
github.com
  ✓ Logged in to github.com account bogdaniel (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************
  - Token scopes: 'delete_repo', 'gist', 'read:org', 'repo', 'workflow', 'write:packages'
```

`workflow` scope present → a workflow-only change is permitted by the token.

```
$ gh api repos/bogdaniel/zenchron-tools --jq '{name,default_branch,permissions,private,archived}'
{"archived":false,"default_branch":"main","name":"bogdaniel/zenchron-tools",
 "permissions":{"admin":true,"maintain":true,"pull":true,"push":true,"triage":true},
 "private":true}
```

Admin + push, not archived → can receive a workflow-only change on a branch.

```
$ gh workflow list -R bogdaniel/zenchron-tools
build-and-deploy                      active  279133481
gitleaks                              active  288669723
sentinel-shield-main-gate-evidence    active  292422298
sentinel-shield-main-validation       active  292153936
sentinel-shield-pr-fast-validation    active  291631143
sentinel-shield                       active  290117145
```

No Dependency-Check evidence workflow is deployed (confirms the prior-sprint finding). On the
**default branch `main`** only 5 workflows exist (the `main-gate-evidence` one lives on a
non-default branch):

```
$ gh api "repos/bogdaniel/zenchron-tools/contents/.github/workflows?ref=main" --jq '.[].name'
deploy.yml
gitleaks.yml
sentinel-shield-main-validation.yml
sentinel-shield-pr-fast-validation.yml
sentinel-shield.yml
```

## 3-12. The evidence-only workflow that WAS added (workflow-only, non-default branch)

Source repo & full SHA pin verified against the **published** `bogdaniel/sentinel-shield`
(the consumer checks out SS from there, not from the local dev checkout):

```
$ gh api repos/bogdaniel/sentinel-shield/git/refs/tags/v0.1.23 --jq '{ref,sha:.object.sha,type:.object.type}'
{"ref":"refs/tags/v0.1.23","sha":"854a58dcd13d9decd246c71673ff69a06a8c7ce4","type":"tag"}
$ gh api repos/bogdaniel/sentinel-shield/git/tags/854a58dcd13d9decd246c71673ff69a06a8c7ce4 --jq '{tag,commit:.object.sha,type:.object.type}'
{"commit":"d06c494e2ed25e13704ef9f5b0b2991fc672b989","tag":"v0.1.23","type":"commit"}
```

→ **v0.1.23 commit SHA = `d06c494e2ed25e13704ef9f5b0b2991fc672b989`** (used as the `actions/checkout` ref pin).

File: `.github/workflows/sentinel-shield-dependency-check-evidence.yml`. Design (matches the
v0.1.24 plan and the prior consumer evidence-workflow conventions):

- **Full SHA pin** of Sentinel Shield v0.1.23: `ref: d06c494e2ed25e13704ef9f5b0b2991fc672b989`,
  `repository: bogdaniel/sentinel-shield`.
- **`workflow_dispatch`** only (maintainer-triggered; no schedule, no `pull_request_target`).
- **Monthly NVD cache key + restore-keys** via `actions/cache` (SHA-pinned `v4.2.0`):
  `key: nvd-${{ runner.os }}-<YYYY-MM>`, `restore-keys: nvd-${{ runner.os }}-`.
- **Foreground execution** — calls `scripts/audits/dependency-check.sh` directly (no `docker run -d`);
  the wrapper uses the container path (`SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE: owasp/dependency-check:latest`,
  readable tag — pin by digest before production) so `timeout-minutes` actually applies.
- **45-60 min timeout window**: job `timeout-minutes: 60`, scan step `timeout-minutes: 55`,
  wrapper `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT: 50m`.
- **`if: always()` artifact upload** (`actions/upload-artifact` SHA-pinned `v4.6.0`), name
  `sentinel-shield-dependency-check`, `path: reports/**`, `retention-days: 30` — a scanner
  failure/findings must NOT erase a valid raw `dependency-check.json`.
- **NO dependency remediation**; **accepted-risks / suppressions untouched**; `permissions: contents: read` only.

The wrapper's honest contract (`scripts/audits/dependency-check.sh`) is unchanged: enabled + valid
JSON → keep it (even on non-zero exit / findings); enabled + no valid JSON (timeout / incomplete NVD
download / crash) → discard the partial file and report `unavailable` — it **never** fakes a clean report.

### Push (workflow-only, NON-default branch, reversible)

A branch was created **from `main`** and the workflow committed to it. **`main` was NOT modified;
no consumer application code was touched.**

```
$ gh api repos/bogdaniel/zenchron-tools/git/refs/heads/main --jq '.object.sha'
0df8316ce6e85fe1d9a8b2ec5c3d45256c514b1a

$ gh api repos/bogdaniel/zenchron-tools/git/refs -X POST \
    -f ref="refs/heads/validate-ss-v024-dependency-check-evidence" \
    -f sha="0df8316ce6e85fe1d9a8b2ec5c3d45256c514b1a"
{"ref":"refs/heads/validate-ss-v024-dependency-check-evidence","sha":"0df8316ce6e85fe1d9a8b2ec5c3d45256c514b1a"}

$ gh api repos/bogdaniel/zenchron-tools/contents/.github/workflows/sentinel-shield-dependency-check-evidence.yml -X PUT \
    -f message="ci: add Sentinel Shield Dependency-Check evidence workflow (v0.1.24 attempt, workflow-only, evidence-dispatch)" \
    -f branch="validate-ss-v024-dependency-check-evidence" -f content="<base64 yml>"
{"commit":"3bd6efae5835ebd228773a9fa733f595114fb7c6",
 "path":".github/workflows/sentinel-shield-dependency-check-evidence.yml"}
```

File confirmed present on the evidence branch:

```
$ gh api "repos/bogdaniel/zenchron-tools/contents/.github/workflows?ref=validate-ss-v024-dependency-check-evidence" --jq '.[].name'
deploy.yml
gitleaks.yml
sentinel-shield-dependency-check-evidence.yml
sentinel-shield-main-validation.yml
sentinel-shield-pr-fast-validation.yml
sentinel-shield.yml
```

**Consumer-side artifacts of this attempt:**
- Branch: `validate-ss-v024-dependency-check-evidence` (base `main` @ `0df8316c…`)
- Workflow commit on that branch: `3bd6efae5835ebd228773a9fa733f595114fb7c6`

## 13-18. Run attempt — BLOCKED (no artifact)

`workflow_dispatch` workflows are only registered/dispatchable once the file exists on the
repository's **default branch**. The file is on a non-default branch, so the dispatch endpoint
returns 404. Confirmed three ways:

```
$ gh workflow run sentinel-shield-dependency-check-evidence.yml -R bogdaniel/zenchron-tools \
    --ref validate-ss-v024-dependency-check-evidence
HTTP 404: workflow sentinel-shield-dependency-check-evidence.yml not found on the default branch
(https://api.github.com/repos/bogdaniel/zenchron-tools/actions/workflows/sentinel-shield-dependency-check-evidence.yml)

$ gh api repos/bogdaniel/zenchron-tools/actions/workflows/sentinel-shield-dependency-check-evidence.yml/dispatches \
    -X POST -f ref="validate-ss-v024-dependency-check-evidence"
{"message":"Not Found","documentation_url":".../create-a-workflow-dispatch-event","status":"404"}

# Polled the workflows API 5×3s — the workflow never registers from a non-default branch:
$ gh api repos/bogdaniel/zenchron-tools/actions/workflows \
    --jq '.workflows[] | select(.path==".../sentinel-shield-dependency-check-evidence.yml")'
(empty — not registered)
```

Dispatching it would require merging the workflow to the consumer **default branch `main`**, which
is **explicitly out of scope** for this sprint (no merge to consumer default, no destructive ops).
I therefore did **not** merge and did **not** trigger a run.

No run exists, so the artifact download is empty (attempted to honor tasks 13-18):

```
$ gh run list -R bogdaniel/zenchron-tools --workflow=sentinel-shield-dependency-check-evidence.yml
HTTP 404: workflow ... not found on the default branch
$ gh run list -R bogdaniel/zenchron-tools --limit 5   # most recent activity is 2026-06-09 (unrelated)
2026-06-09T22:11:32Z | sentinel-shield-pr-fast-validation | completed | ...
2026-06-09T22:11:32Z | sentinel-shield-main-gate-evidence | completed | ...
...
$ gh run download -R bogdaniel/zenchron-tools -n sentinel-shield-dependency-check
no artifact matches any of the names or patterns provided   # exit 1 — expected
```

There is **no `dependency-check.json` artifact**. The collector
`scripts/collectors/dependency-check.sh --input <file>` was **NOT** run, because there is no real
artifact to feed it (running it on a fixture would not be live evidence, and would be dishonest).

## 19-20. Registry — NOT updated (no real artifact)

`docs/main-gate-live-evidence.md` is **NOT** updated and Dependency-Check is **NOT** promoted.

> **ATTEMPTED** — Verified consumer `bogdaniel/zenchron-tools` (admin/push, `workflow` scope) has no
> Dependency-Check evidence workflow; authored an evidence-only, foreground, monthly-NVD-cached,
> 60-min-timeout, `if:always()`-upload workflow pinned to SS v0.1.23 (`d06c494e…`); pushed it to a
> **non-default** consumer branch `validate-ss-v024-dependency-check-evidence`
> (commit `3bd6efae…`) without touching `main` or app code. **Could not dispatch** — GitHub
> requires `workflow_dispatch` workflows on the default branch, and merging to consumer default is
> out of scope. **No completed `dependency-check.json` artifact exists; Dependency-Check remains
> attempted, NOT live-validated.** No run ID was fabricated.

## Precise next manual step (to close this)

A maintainer with rights to change the consumer default branch must:

1. Open a PR from `validate-ss-v024-dependency-check-evidence` → `main` on `bogdaniel/zenchron-tools`
   (workflow-only diff: one new `.github/workflows/sentinel-shield-dependency-check-evidence.yml`),
   review, and **merge to `main`** so GitHub registers the `workflow_dispatch` trigger.
2. Dispatch it:
   `gh workflow run sentinel-shield-dependency-check-evidence.yml -R bogdaniel/zenchron-tools --ref main`
   Expect a **cold NVD run of ~45-60 min** (first run downloads the full NVD feed; subsequent runs
   reuse the monthly `actions/cache`). Let it run to completion — do not cancel early.
3. After it completes:
   `gh run download -R bogdaniel/zenchron-tools -n sentinel-shield-dependency-check`
   then validate: `jq -e . reports/raw/dependency-check.json` (must be non-empty valid JSON), and
   `scripts/collectors/dependency-check.sh --input reports/raw/dependency-check.json`.
4. **Only then**, with that real, cited artifact (run ID + size + validity + collector mapping),
   add the row to `docs/main-gate-live-evidence.md` and promote Dependency-Check to **live-validated**.

(Alternative to a default-branch merge: a maintainer may temporarily make this branch the default,
dispatch, then revert — but the PR-merge path above is the clean, non-destructive route.)

**Until that real artifact exists and is cited, Dependency-Check stays ATTEMPTED, NOT
live-validated. Nothing here was faked; no run ID was invented.**
