# Release provenance, artifact verification, and reproducible manifests

This document describes the beta.2 release-provenance toolchain: how release evidence is
**generated** from the GitHub API, how CI **artifacts are safely verified**, how a
**reproducible release manifest** is produced and checked, and how a release is
**finalized** into a tag under the two-commit model.

These tools sit alongside — and never bypass — the existing evidence contract:

- `schemas/release-evidence.schema.json` defines the evidence record (`engine_ci[]`,
  `engine_commit` vs `release_commit`, `consumer_runs[]`, `required_evidence`).
- `scripts/validate-release-evidence.sh` **validates/verifies** an evidence file
  (`--offline`, `--verify-github`, `--verify-binding`).
- `scripts/check-release-readiness.sh` is the stage gate that composes structural gates
  with the evidence validator.

The new tools are **generators and verifiers**; they do not alter those contracts. All of
them route GitHub access through `$GH_BIN` (default `gh`) so they are testable offline, and
all are strict POSIX `sh`.

---

## 1. Evidence generation — `scripts/collect-release-evidence.sh`

Until now `engine_ci[]` was hand-authored. `collect-release-evidence.sh` **generates** a
candidate evidence document by querying the engine repository's GitHub Actions runs for one
exact commit, and emits it to stdout or `--output`. It is a **generator, not a writer**: it
never touches `evidence/releases/*.json`.

For each expected workflow it requires, fail-closed, that a run:

- belongs to `--repo` (`repository.full_name` match),
- ran on the repository **default branch** (`head_branch == default_branch`),
- was triggered by an **approved event** (`--events`, default `push,workflow_dispatch`; a
  `pull_request`/`schedule` run is never release push evidence),
- has the **exact workflow name** (`--workflow`),
- has the **exact head SHA** (`--commit`),
- is **completed** with conclusion **success**.

Runs that fail these filters are rejected with a precise reason: `missing-run`,
`wrong-branch`, `failed-conclusion`, `cancelled`, or `ambiguous-rerun`. The
**"latest successful attempt"** rule is deterministic: the GitHub runs list returns one
entry per `run_id` (its latest attempt), and **exactly one** completed-success run per
workflow is required. **Two distinct successful runs** for the same workflow+commit are
**ambiguous** and rejected — the tool refuses to pick an authoritative run for you.

The emitted candidate lists each run with an **empty, unverified** `artifacts[]`
(`artifacts_verified: false`) — the honest "run proven, artifacts not yet fetched" state —
so the candidate independently passes `validate-release-evidence.sh --offline`. Artifact
verification is a separate step (below) that populates and verifies `artifacts[]`.

```sh
sh scripts/collect-release-evidence.sh \
  --repo bogdaniel/sentinel-shield --commit <40hex> \
  --workflow ci-self-test --workflow ci-pipeline \
  --version 2.0.0-beta.2 --stage beta --scope engine-only \
  --output /tmp/candidate.json
sh scripts/validate-release-evidence.sh --file /tmp/candidate.json   # offline structural check
```

Exit codes: `0` candidate produced; `1` collection unmet (a workflow had no unambiguous
successful run); `2` invalid invocation / malformed API; `3` missing `jq`/`gh`.

---

## 2. Artifact verification — `scripts/verify-release-artifacts.sh` + `scripts/lib/archive-safety.sh`

`verify-release-artifacts.sh` downloads each run's artifacts into an **isolated per-artifact
temp directory** and fail-closed verifies:

- **ownership** — `artifact.workflow_run.id` equals the run; `id`/`name` present;
- **expiration** — `artifact.expired` must be `false`;
- **archive integrity + safety** — via `scripts/lib/archive-safety.sh` (below);
- **inventory** — records every contained file with its SHA-256; can require a minimum file
  count (`--min-files`) and/or an **embedded commit** string (`--require-embedded-commit`);
- **digests** — SHA-256 of the whole artifact zip and of each contained file.

`archive-safety.sh` inspects the ZIP listing **before** extracting and re-asserts safety
**during** extraction, rejecting:

| attack | reason token |
| --- | --- |
| a `..` path component (traversal) | `path-traversal:` |
| an entry anchored at `/` (absolute) | `absolute-path:` |
| a symlink entry (escaping the root) | `symlink:` |
| the same path listed twice | `duplicate-path:` |
| total uncompressed size over the cap (zip bomb) | `oversize:` |
| more entries than the cap | `too-many-entries:` |

A single rejection fails the whole run (exit `1`). The tool emits one
artifact-verification record per artifact (`ownership_ok`, `expired`, `archive_safe`,
`sha256`, `files[]`, `embedded_commit_found`, `verified`, `reasons[]`). The malicious-archive
fixtures live under `tests/fixtures/archives/` (see that README).

```sh
sh scripts/verify-release-artifacts.sh --evidence /tmp/candidate.json \
  --require-embedded-commit --output /tmp/artifact-verification.json
```

Exit codes: `0` all safe/owned; `1` a rejection; `2` invalid invocation / malformed API;
`3` missing `jq`/`gh`/`unzip`/`zipinfo`/SHA-256 tool.

---

## 3. Reproducible manifest — `scripts/generate-release-manifest.sh` + `scripts/verify-release-manifest.sh`

`generate-release-manifest.sh` produces a canonical **release manifest**
(`schemas/release-manifest.schema.json`) fingerprinting exactly what the release ships:

- `source_commit`, `tree_hash` (git `rev-parse <commit>^{tree}`), `tag_target`,
- `release_scope`, `version`, `stage`,
- `workflow_runs` (from `engine_ci[]`, sorted by `run_id`),
- `artifact_digests` (from a `verify-release-artifacts` report, sorted),
- `action_pins` (every workflow `uses:` ref across engine CI + templates, de-duplicated and
  sorted),
- `tool_versions`,
- `profile_policy_digests` (SHA-256 of each `profiles/**/profile.manifest.json`),
- `schema_digests` (SHA-256 of each `schemas/*.json`).

The document splits a **hashed `body`** from a **non-hashed `metadata`** section.
`reproducibility.hash` is the SHA-256 of the **canonical** serialization of `body` alone
(`jq -S -c`: recursively key-sorted, compact). **Timestamps live only in `metadata`** and
therefore never perturb the hash — regenerating from the same repository state yields an
**identical** hash. `tool_versions` are part of the provenance fingerprint (a manifest built
in a different tool environment is legitimately different).

`verify-release-manifest.sh` performs two independent checks:

1. **self-consistency** (always): recompute the hash over the manifest's own `body`; any
   tamper to `body` that did not also forge the hash is detected;
2. **reconstruction** (with `--evidence`): regenerate the body from the same inputs and
   require both the reconstructed hash and body to match — detecting drift between the
   manifest and the actual repo/evidence state.

```sh
sh scripts/generate-release-manifest.sh --evidence evidence/releases/v2.0.0-beta.2.json \
  --artifacts /tmp/artifact-verification.json --output /tmp/release-manifest.json
sh scripts/verify-release-manifest.sh --manifest /tmp/release-manifest.json \
  --evidence evidence/releases/v2.0.0-beta.2.json
```

Exit codes: generate `0`/`2`/`3`; verify `0` verified, `1` tamper/drift, `2` malformed, `3`
missing tool.

---

## 4. Finalization — `scripts/finalize-release-evidence.sh`

Finalization computes the release **tag target** under the two-commit model and creates the
tag **only** on explicit request. It is finite and non-circular: it reads the evidence,
computes one target, verifies it, prints it, and stops.

- `--mode source-tag` — tag the CI-proven `engine_commit` directly (source == release).
  Target = `engine_commit`.
- `--mode metadata-tag` — tag a later **metadata-only** `release_commit`. Target =
  `release_commit`, which must be a **descendant** of `engine_commit` whose diff changes
  **only** approved release metadata (`evidence/releases/*.json`, `CHANGELOG.md`, release
  notes/evidence docs). Any executable/schema/workflow/test/policy/profile change is a
  **violation** (exit `2`). The allowlist matches
  `validate-release-evidence.sh --verify-binding`.

The tool **never creates a tag unless `--execute` is passed**. Without it, it is a read-only
planner that prints the exact target it would tag.

```sh
# Plan (read-only) — prints the exact target, creates nothing:
sh scripts/finalize-release-evidence.sh --evidence evidence/releases/v2.0.0-beta.2.json \
  --mode metadata-tag --tag v2.0.0-beta.2
# Create the tag (explicit):
sh scripts/finalize-release-evidence.sh --evidence evidence/releases/v2.0.0-beta.2.json \
  --mode metadata-tag --tag v2.0.0-beta.2 --execute
```

Exit codes: `0` target computed (tag created with `--execute`); `1` fail-closed
(unknown/unresolvable/non-descendant commit); `2` invalid invocation or metadata-only
violation; `3` missing `git`.

---

## End-to-end flow

```
collect-release-evidence.sh   → candidate engine_ci[]            (runs proven)
        │
        ▼
verify-release-artifacts.sh   → artifact-verification.json       (archives safe + digested)
        │
        ▼
generate-release-manifest.sh  → release-manifest.json            (reproducible fingerprint)
        │
        ▼
validate-release-evidence.sh --verify-github   (existing gate; runs + binding proven)
check-release-readiness.sh    (existing stage gate)
        │
        ▼
finalize-release-evidence.sh --mode … --execute → the release tag
```

---

## Deferred (NOT implemented in beta.2)

Per governance, signing stays **optional** for beta.2 and is a follow-up:

- **SLSA attestation / signed-provenance GitHub workflow** — a workflow that emits signed,
  in-toto/SLSA provenance for release artifacts.
- **Detached manifest signatures** — cryptographic signing of the release manifest
  (`reproducibility.hash`) so consumers can verify authorship, not just integrity.

The manifest's `reproducibility.hash` is the natural payload for a future detached
signature; the schema and tooling are signing-ready but do not require it.
