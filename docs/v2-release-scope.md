# v2 Release Scope (engine-only)

This document states precisely what the v2.0.0 alpha work proves and what it does
not prove. It applies to the current development line: **v2.0.0-alpha.1 candidate —
not yet published**. There is no v2 git tag; the highest published tag is `v1.9.2`,
which remains the stable product line. The default branch is currently doing
post-v2-alpha production-readiness work.

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
