# Sentinel Shield v2.0.0-beta.2 — Release Authorization Checklist

**Status: NOT AUTHORIZED — release candidate assembled, unpublished.**

This branch (`macro-beta2/integration`) contains a **release candidate package** only.
No tag exists, nothing is pushed, and no GitHub release has been created. The draft
evidence file `evidence/releases/v2.0.0-beta.2.json` is a **transparent no-proof draft**
(`engine_commit: "unknown"`, empty `engine_ci[]`/`consumer_runs[]`, all
`required_evidence` flags `false`) — it is structurally valid but satisfies **no** stage
gate. Authorization to tag/publish requires the post-merge evidence refresh below.

---

## Why authorization is blocked

The evidence machinery is fail-closed and **two-commit** by design:

- The real **release-source commit** (`engine_commit`) is only known **after** this branch
  merges into the default branch — that merge commit is what the default-branch GitHub
  Actions runs execute against. It cannot be recorded honestly *before* the merge (the
  schema permits `engine_commit: "unknown"` **only** for a no-evidence draft).
- `engine_ci[]` must be **collected from real GitHub Actions runs** at that commit and then
  **verified** via the GitHub API. Offline/structural validation proves shape only, never
  that the runs exist. An empty `engine_ci[]` fails the engine-only beta gate closed.

Therefore any tag/publish is **BLOCKED** until the default-branch evidence refresh runs and
passes `--verify-github` / `--verify-binding`.

---

## Authorization checklist (must ALL pass, in order)

> Ordering matters: nothing below the "AUTHORIZATION GATE" line may run until every box
> above it is checked with real, verified output.

### A. Pre-merge (already satisfied on this branch)

- [x] `self-test all` PASS (macro-regression GREEN).
- [x] `sh scripts/self-test.sh production-readiness` → **33/33** suites pass.
- [x] `shellcheck -S error` clean on all changed scripts; `actionlint` clean; `sh -n` clean.
- [x] Draft evidence `evidence/releases/v2.0.0-beta.2.json` passes
      `validate-release-evidence.sh --offline` (structural) **and** satisfies **no** stage
      gate (honest no-proof draft).
- [x] Release manifest generated + verified for the integration HEAD
      (`evidence/manifests/v2.0.0-beta.2.manifest.json`); reproducibility hash recorded in
      `integration/release-candidate-report.md`.
- [x] Engine-only beta readiness run in **offline/structural** mode and explicitly labelled
      **NON-AUTHORITATIVE** (see RC report).

### B. Merge to the default branch

- [ ] Merge `macro-beta2/integration` → `master` (default branch). Record the resulting
      **merge commit SHA** — call it `<RELEASE_SOURCE_COMMIT>` (40-hex). This is the commit
      the default-branch CI will run against and the value `engine_commit` must take.

### C. Post-merge default-branch evidence refresh (THE gate)

- [ ] Confirm the default-branch GitHub Actions runs for `<RELEASE_SOURCE_COMMIT>` completed
      **successfully** (`ci-self-test`, `ci-pipeline`, and the rest of the engine CI matrix).
- [ ] **Collect** real `engine_ci[]` from the GitHub API for that commit:

  ```sh
  sh scripts/collect-release-evidence.sh \
    --repo bogdaniel/sentinel-shield --commit <RELEASE_SOURCE_COMMIT> \
    --workflow ci-self-test --workflow ci-pipeline \
    --version 2.0.0-beta.2 --stage beta --scope engine-only \
    --output /tmp/candidate-beta2.json
  ```

- [ ] **Verify artifacts** (fail-closed download + SHA-256 inventory):

  ```sh
  sh scripts/verify-release-artifacts.sh --evidence /tmp/candidate-beta2.json --repo bogdaniel/sentinel-shield
  ```

- [ ] Replace the draft with the collected candidate at
      `evidence/releases/v2.0.0-beta.2.json` (now carrying the real 40-hex `engine_commit`
      and a populated, verified `engine_ci[]`). Commit it as **metadata-only** (evidence file
      only — no executable/schema/workflow/test change).
- [ ] **Structural re-validate** the real file:

  ```sh
  sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0-beta.2.json --offline
  ```

- [ ] **GitHub-verify** the runs exist and are green at `engine_commit`:

  ```sh
  sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0-beta.2.json \
    --require-stage beta --scope engine-only --verify-github --repo bogdaniel/sentinel-shield
  ```

- [ ] If tagging a later **metadata-only** `release_commit` (two-commit model), **verify the
      binding** (compare API proves the tag-target diff is metadata-only):

  ```sh
  sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0-beta.2.json \
    --verify-binding --repo bogdaniel/sentinel-shield
  ```

- [ ] **Authoritative** engine-only beta readiness passes online:

  ```sh
  sh scripts/check-release-readiness.sh --version 2.0.0-beta.2 --stage beta \
    --scope engine-only --verify-github --evidence evidence/releases/v2.0.0-beta.2.json
  ```

### D. Regenerate + verify the release manifest against the real source commit

- [ ] Regenerate the manifest so `source_commit`/`tree_hash`/`workflow_runs` reflect the
      real, CI-proven commit (not the pre-merge integration HEAD placeholder), then verify:

  ```sh
  sh scripts/generate-release-manifest.sh --evidence evidence/releases/v2.0.0-beta.2.json \
    --repo-root . --output evidence/manifests/v2.0.0-beta.2.manifest.json
  sh scripts/verify-release-manifest.sh --manifest evidence/manifests/v2.0.0-beta.2.manifest.json
  ```

---

## ════════════════ AUTHORIZATION GATE ════════════════

**Do NOT run anything below until EVERY box in A–D is checked with real, verified output.**

Sign-off (record actuals):

- Release-source commit: `<RELEASE_SOURCE_COMMIT>` = `________________________________________`
- `--verify-github` result: `________`  · `--verify-binding` result: `________`
- Manifest reproducibility hash (real commit): `________________________________________________________________`
- Authorized by: `________________`  Date: `__________`

---

## Reference commands — FOR REFERENCE ONLY, **NOT EXECUTED**

> These are printed so the human release owner has the exact form. **None** of these have
> been run by the RC assembly. Do not run them until the AUTHORIZATION GATE above is passed.

### Sanctioned tag path — finalize-release-evidence.sh (read-only plan, then execute)

`finalize-release-evidence.sh` is the sanctioned, non-circular tagger. Without `--execute`
it is a read-only planner that prints the exact target and creates nothing.

```sh
# Plan (read-only) — prints the exact tag target, creates NOTHING:
sh scripts/finalize-release-evidence.sh --evidence evidence/releases/v2.0.0-beta.2.json \
  --mode source-tag --tag v2.0.0-beta.2

# Create the tag (explicit) — ONLY after the AUTHORIZATION GATE:
sh scripts/finalize-release-evidence.sh --evidence evidence/releases/v2.0.0-beta.2.json \
  --mode source-tag --tag v2.0.0-beta.2 --execute
```

Use `--mode metadata-tag` instead if tagging a metadata-only `release_commit` descendant.

### Explicit signed-tag command (equivalent low-level form)

```sh
# <RELEASE_SOURCE_COMMIT> = the CI-proven engine_commit (or the verified metadata release_commit)
git tag -s v2.0.0-beta.2 -m "Sentinel Shield v2.0.0-beta.2 (engine-only beta)" <RELEASE_SOURCE_COMMIT>
git push origin v2.0.0-beta.2
```

### GitHub prerelease command

```sh
gh release create v2.0.0-beta.2 \
  --repo bogdaniel/sentinel-shield \
  --verify-tag \
  --prerelease \
  --latest=false \
  --title "Sentinel Shield v2.0.0-beta.2" \
  --notes-file docs/v2.0.0-beta.2-release-notes.md
```

---

## Authorization state summary

| Track | Requirement | State |
|---|---|---|
| **engine-only beta** | real verified `engine_ci[]` at default-branch commit | **BLOCKED** — draft has empty `engine_ci[]` (`engine_commit: unknown`); offline readiness is NON-AUTHORITATIVE |
| **framework-validated beta** | real Laravel + Symfony consumer runs | **BLOCKED** — no consumer runs claimed (none exist) |
| **rc** | + php_library / node_react / combined_profile consumer runs | **BLOCKED** — requirements unmet |
| **ga** | + bootstrap / rollback (npm/pnpm/yarn) consumer runs | **BLOCKED** — requirements unmet |

No track is authorized. This package is a **release candidate awaiting the post-merge,
default-branch, GitHub-verified evidence refresh**.
