# Sentinel Shield v2.0.0-beta.2 — Release Candidate Report

**Status: RELEASE CANDIDATE — UNPUBLISHED.** No tag, no push, no GitHub release.
`v2.0.0-beta.1` is untouched.

- Branch: `macro-beta2/integration`
- Integration HEAD (pre-merge): `439f8a59bf1d743ed8501a803dc121b9e71a76a6`
- Range: `master..HEAD` — 21 commits, 129 files, +16803 / -567

This report describes what the RC contains, the verification evidence captured, and the
explicit authorization state for each release track. Authorization itself lives in
`docs/beta2-release-authorization.md`.

---

## 1. What the RC contains

Four integration waves (see `integration/combined-diff.json` for the per-file,
subsystem-grouped, risk-tagged breakdown):

| Wave | Content | Key subsystems (risk) |
|---|---|---|
| A | php-library + node/react real-consumer harnesses; installer hardening | installer-hardening (**high**), consumer-output-contract (medium) |
| B | CI workflow-runtime audit; scanner bumps + provenance/health gate; required-checks + merge-safety governance | security-scanners (**high**), governance-audits (medium), ci-workflows (medium) |
| C | engine_ci collection from GitHub API; safe artifact download + verification; reproducible release manifest; two-commit finalization | release-evidence-tooling (**high**), release-artifact-safety (**high**) |
| D-05 / 09 | adopter/output contract; docs (release notes, migration, support policy, status matrix) | consumer-output-contract (medium), docs (low) |

Subsystem churn (from `combined-diff.json`):

| Risk | Subsystem | Files | +add / -del |
|---|---|---|---|
| high | installer-hardening | 3 | +533 / -0 |
| high | release-artifact-safety | 1 | +126 / -0 |
| high | release-evidence-tooling | 6 | +886 / -0 |
| high | security-scanners | 2 | +122 / -14 |
| medium | consumer-output-contract | 3 | +540 / -0 |
| medium | governance-audits | 6 | +847 / -1 |
| medium | ci-workflows | 2 | +40 / -2 |
| medium | scripts-other | 10 | +377 / -538 |
| low | schemas (release/consumer + governance) | 11 | +916 / -0 |
| low | tests (prod + fixtures) | 70 | +10806 / -0 |
| low | docs / config / changelog | 15 | +1610 / -12 |

### RC artifacts produced by this package

- `evidence/releases/v2.0.0-beta.2.json` — honest **no-proof draft** (see §3).
- `evidence/manifests/v2.0.0-beta.2.manifest.json` — reproducible release manifest (see §4).
- `integration/combined-diff.json` — master..HEAD grouped by subsystem + risk.
- `integration/conflict-resolution-log.md` — merge + regression + schema-unification log.
- `docs/beta2-release-authorization.md` — authorization checklist + unexecuted commands.

---

## 2. Verification evidence

All commands run locally against the integration HEAD.

### 2.1 Regression suite — GREEN

- `sh scripts/self-test.sh production-readiness` → **33/33** standalone `tests/prod/*.sh`
  suites pass (including the evidence suites `80` command-contract, `90` evidence,
  `91` evidence-semantic, `92` release-binding). Captured post-commit in §6.
- `self-test all` (macro-regression) PASS — exercised end-to-end by the genuine engine-only
  readiness run in §5, whose `[alpha]` gate executes `syntax`, `production-readiness`, `e2e`,
  and `all` as separate gates, all PASS.

### 2.2 Static analysis — clean

- `shellcheck -x -S error` (the repo's `syntax`-group severity) on every changed script
  (`master..HEAD`) → **clean** (exit 0, no findings). Sub-error notes (SC1091 "not
  following sourced file", SC1007 on the pervasive `CDPATH= cd` idiom) are info/warning
  only and below the `-S error` threshold the project gates on.
- `actionlint` (repo-wide) → **clean** (exit 0).
- `sh -n` across every tracked `*.sh` → **all clean** (no parse errors).
- No new shell scripts were introduced into the repo by this RC assembly step
  (the diff generator lives only in the scratchpad), so there is nothing new to `sh -n`.

### 2.3 Evidence + manifest integrity

- `jq -e .` on `evidence/releases/v2.0.0-beta.2.json` and
  `evidence/manifests/v2.0.0-beta.2.manifest.json` → both valid JSON.
- `validate-release-evidence.sh --file evidence/releases/v2.0.0-beta.2.json --offline`
  → **exit 0** (structural OK) with the engine-only "FRAMEWORK LIVE-VALIDATION NOT
  INCLUDED" disclaimer.
- `verify-release-manifest.sh` on the manifest → **exit 0** (self-consistency + reconstruction OK).

---

## 3. The draft evidence file is an HONEST no-proof draft

`evidence/releases/v2.0.0-beta.2.json`:

```
stage=beta  release_scope=engine-only  engine_commit="unknown"
engine_ci=[]  consumer_runs=[]  required_evidence: all false
```

- `engine_commit` uses the literal **`unknown`** — the only non-40-hex value the schema
  permits, and only for a no-evidence draft. The real release-source commit is unknowable
  until this branch merges to the default branch (see authorization doc §B). It is a
  documented placeholder, not a fabricated SHA.
- **Fail-closed proof.** The file passes `--offline` structural validation yet satisfies
  **no** stage gate:

  ```
  validate-release-evidence.sh --require-stage beta --scope engine-only --offline
    → exit 1: "engine_ci is empty (engine-only beta+ requires the engine default-branch
               CI runs at engine_commit)"
  ```

- No Laravel/Symfony/consumer production runs are claimed; no external adoption is claimed.
  This is the legitimate "no proof yet" state.

Existing evidence suites remain green: tests `90`/`91`/`92` reference the shipped
`v2.0.0.json` and `v2.0.0-beta.1.json` by name (not a directory glob), so the new draft
does not perturb them.

---

## 4. Release manifest — reproducible

`evidence/manifests/v2.0.0-beta.2.manifest.json`, generated with:

```sh
sh scripts/generate-release-manifest.sh \
  --evidence evidence/releases/v2.0.0-beta.2.json \
  --repo-root . \
  --source-commit 439f8a59bf1d743ed8501a803dc121b9e71a76a6 \
  --output evidence/manifests/v2.0.0-beta.2.manifest.json
```

| Field | Value |
|---|---|
| `body.source_commit` | `439f8a59bf1d743ed8501a803dc121b9e71a76a6` (integration HEAD) |
| `body.tree_hash` | `5ed47e11d77bae3ec72cac1c848e8765dd9e38d1` |
| `body.tag_target` | `unknown` (post-merge decision — honest) |
| `body.workflow_runs` | `0` (empty engine_ci — honest, no CI proof yet) |
| **reproducibility.hash** (sha256 of canonical `body`) | `03c3586d54cab5e042a1b757dc96166b2454654024b7f18caf076d1e03474657` |

- **Reproducibility confirmed:** two independent regenerations from identical inputs
  yielded the identical hash `03c3586d…d1e03474657`; `metadata.generated_at` (a timestamp)
  is outside the hashed body and does not perturb it.
- **Verify:** `verify-release-manifest.sh --manifest …` → exit 0 ("manifest
  self-consistency OK", "release manifest verified").

> The manifest honestly fingerprints the pre-merge integration HEAD tree. It MUST be
> regenerated against the real, CI-proven release-source commit after merge (authorization
> doc §D) before it backs a tag.

---

## 5. Readiness checks (STRUCTURAL / offline)

### 5.1 Engine-only beta — NON-AUTHORITATIVE

```sh
sh scripts/check-release-readiness.sh --version 2.0.0-beta.2 --stage beta \
  --scope engine-only --offline --evidence evidence/releases/v2.0.0-beta.2.json
```

<!-- ENGINE_ONLY_RESULT -->

> **NON-AUTHORITATIVE.** `--offline` proves structure only. The readiness banner itself
> states: *"offline (structural-only; --verify-github required to authorize a beta/rc/ga
> tag)"* and *"FRAMEWORK LIVE-VALIDATION NOT INCLUDED"*. An engine-only beta tag is
> authorized **only** after the post-merge default-branch `--verify-github` evidence
> refresh (authorization doc §C). This offline result carries no tag authority.

### 5.2 Framework-validated beta / rc / ga — BLOCKED (fail closed)

To isolate the **evidence gate** without re-running the multi-minute structural self-test
groups, these three were run with the self-test invocation stubbed (`SELF_TEST=true`); the
real structural gate is proven genuinely by §5.1 and the 33/33 in §6. The evidence
validation below is **not** stubbed — it is the real fail-closed result.

| Track | Command scope/stage | Result | Blocking reason (verbatim) |
|---|---|---|---|
| framework-validated **beta** | `--stage beta --scope framework-validated --offline` | **NOT READY — exit 1** | `release evidence does not meet stage 'beta' (scope=framework-validated); unmet: laravel symfony` + `stage 'beta' requires GitHub-verified evidence (--verify-github); structural-only evidence is INSUFFICIENT (fail closed)` |
| **rc** | `--stage rc --scope framework-validated --offline` | **NOT READY — exit 1** | `release evidence declares stage 'beta' which is below the requested stage 'rc'; a lower-stage document cannot satisfy a higher-stage request` + `--verify-github required` |
| **ga** | `--stage ga --scope full-platform --offline` | **NOT READY — exit 1** | `release evidence declares stage 'beta' which is below the requested stage 'ga'` + `--verify-github required` |

All three fail closed (`NOT READY (1 unmet gate(s)); fail closed`). No override record was
supplied (and none should be).

---

## 6. Post-commit regression confirmation

Captured after committing the RC deliverables (so the working tree is clean — test
`240-evidence-collection.sh` asserts `git status --porcelain evidence/releases` is empty):

<!-- POST_COMMIT_PROD -->

---

## 7. Authorization state (explicit)

| Track | State | Why |
|---|---|---|
| **engine-only beta** | **NOT AUTHORIZED** | Draft has empty `engine_ci[]` / `engine_commit: unknown`. Offline readiness is NON-AUTHORITATIVE. Needs post-merge `--verify-github` refresh. |
| **framework-validated beta** | **BLOCKED** | No Laravel/Symfony consumer runs exist (none claimed). |
| **rc** | **BLOCKED** | Below-stage document; rc consumer runs unmet. |
| **ga** | **BLOCKED** | Below-stage document; ga bootstrap/rollback runs unmet. |

**Nothing is authorized for tag or publish.** The full authorization checklist and the
exact (unexecuted) signed-tag + `gh release` commands are in
`docs/beta2-release-authorization.md`.
