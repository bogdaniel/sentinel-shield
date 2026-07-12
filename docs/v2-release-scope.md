# v2 Release Scope (engine-only)

This document states precisely what the v2 engine-only work proves and what it does
not prove. The latest release is **`v2.0.1`** — an engine-only maintenance release
published 2026-07-09 at tag target `32812ed`, refreshing the **`v2.0.0`** engine-only
production release evidence (tag target `13be630`) with **no executable engine change**.
The **v1.x** line (latest published tag `v1.9.2`) remains a supported prior stable line
but is no longer the latest overall release. The `v2.0.0-beta.1` / `v2.0.0-alpha.1`
references elsewhere are historical pre-release milestones on the path to `v2.0.0`.

The release cycle described here runs under the `engine-only` release scope. Under
this scope the release is a **production-oriented engine** with
**production-readiness controls**, and its **framework profiles are supported by
deterministic tests** — but it makes no live-consumer validation claims for those
frameworks.

## Proven in scope

The engine-only release exercises and validates the following through the engine's
own tests, fixtures, and green default-branch CI:

- Profile-policy resolution.
- Effective-profile composition.
- Required / recommended / optional / one-of semantics.
- Required-tool fail-closed enforcement.
- Local pipeline orchestration.
- Stale-report protection.
- Source acquisition safety.
- Install / sync / migration transactions.
- Recovery behavior.
- Release-evidence validation.
- Engine GitHub Actions workflows.
- Workflow pinning and security linting.
- Deterministic fixture validation.

## Supported but not live-validated

The following are supported by the engine and covered by deterministic
engine/fixture tests, but were **not** independently validated in a real consumer
repository for this release:

- Laravel profile.
- Symfony profile.
- PHP-library profile (unless separately validated).
- Node/React profile (unless separately validated).
- Combined framework profiles (unless separately validated).

Laravel and Symfony are profile-supported, engine-tested, and fixture-tested. They
are not independently live-validated in a real consumer repository. Engine fixtures
are synthetic test inputs and are not real consumers; passing fixture validation is
not production proof for any framework.

## Explicitly deferred

The following are out of scope for this release cycle and are deferred to future
work:

- Real Laravel consumer CI.
- Real Symfony consumer CI.
- Independent production-project adoption proof.
- External maintainer usability proof.

## Release scope values and requirement matrix

A top-level `release_scope` field governs which evidence is required. It accepts
three values. When the field is absent, it defaults to `framework-validated`.

- **engine-only** — Laravel/Symfony/consumer real runs are **not** required; their
  `required_evidence` flags stay `false`. The release **cannot** claim
  framework-validated status, and the validator prints
  `FRAMEWORK LIVE-VALIDATION NOT INCLUDED`. This is the scope used for this release
  cycle.
- **framework-validated** — consumer live-validation evidence is required, phased by
  release stage:
  - **beta**: `laravel` + `symfony` consumer evidence required.
  - **rc**: the above **plus** `php_library`, `node_react`, and `combined_profile`.
  - **ga**: the above **plus** `bootstrap_apply`, `rollback_npm`, `rollback_pnpm`,
    and `rollback_yarn`.
- **full-platform** — all of the evidence listed under framework-validated (beta
  through ga) is required at **beta and above**.

The engine-only track is still **fail-closed**. An engine-only beta requires the
engine's own green default-branch CI recorded in an `engine_ci[]` block: successful
`ci-self-test` and `ci-pipeline` at the recorded `engine_commit`. This is verifiable
against GitHub.

## How this is enforced

Enforcement is implemented by three scripts and the recorded evidence:

- `schemas/release-evidence.schema.json` — defines the evidence structure, including
  `release_scope` and the `engine_ci[]` block.
- `scripts/validate-release-evidence.sh` — validates evidence against the schema and
  the active scope; with `--verify-github` it verifies the recorded `engine_ci[]`
  runs against GitHub Actions.
- `scripts/check-release-readiness.sh` — checks readiness for the target stage under
  the active scope.

For this cycle the engine's green default-branch CI is recorded in
`evidence/releases/v2.0.0-beta.1.json` under `engine_ci[]` and is GitHub-verified via
`validate-release-evidence.sh --verify-github`.

## Release-commit binding model (avoiding circular self-reference)

A release cannot record its own CI evidence *inside the very commit that CI validated* —
the evidence would have to exist before the runs it references. Sentinel Shield resolves
this with an explicit two-commit model:

| Field | Meaning |
| --- | --- |
| `engine_commit` | The **release-source commit**: the immutable, executable engine commit that CI actually ran against (every `engine_ci[]` / `consumer_runs[]` run has `commit == engine_commit`). This is the code that is proven. |
| `release_commit` | The commit the **tag** points at (the "evidence commit"). Optional; when absent it equals `engine_commit`. When present and different, it must be a descendant of `engine_commit` whose diff changes **only approved release metadata**. |

**Tag policy (selected):** the tag points at `release_commit`; the evidence records
`engine_commit` as the CI-proven source. When the two differ, the validator proves the
`engine_commit → release_commit` diff is **metadata-only**.

**Approved metadata allowlist** (nothing else may change between the two commits):

```
evidence/releases/*.json
CHANGELOG.md
docs/*release-evidence*.md
docs/*release-notes*.md
docs/v2-merge-commit-ci-evidence*.md
```

Any change to a script, workflow, schema, or other executable/source file between
`engine_commit` and `release_commit` is a **binding violation** and is rejected
(non-overridable). This is verified against the GitHub compare API:

```sh
# Prove the tag target only adds approved metadata over the validated source:
sh scripts/validate-release-evidence.sh --file evidence/releases/v2.0.0-beta.1.json --verify-binding
# (also runs automatically as part of --verify-github)
```

The shipped alpha/beta files currently set `release_commit == engine_commit`
(`8bd33a9`), i.e. no separate evidence commit yet. **After PR #11 merges**, both must be
refreshed to the merge commit `M2` (whose own push CI is then recorded), and — if the
tag is cut from a later metadata-only commit — `release_commit` is set to that commit and
`--verify-binding` proves the diff is evidence-only. A future or unmerged SHA is never
written into evidence.

Alternative policy (not selected): tag `engine_commit` directly and publish evidence as a
signed release asset instead of an in-tree evidence commit.
