# Support Policy

This policy states what Sentinel Shield supports, for how long, and what qualifies for
a patch. It distinguishes **engine** support from **framework-profile** support, because
the two carry different validation guarantees. Where this document and marketing/README
prose disagree, [`product-status.md`](product-status.md) is the canonical maturity source
and this file is the canonical support-scope source.

> Version identifiers below use immutable examples. `v2.0.0-beta.2` is a **draft,
> engine-only pre-release** (not published). The **latest stable, supported line is v1.x
> (latest published tag `v1.9.2`)**.

## Supported lines

| Line | Status | Support |
| --- | --- | --- |
| **v1.x** (latest `v1.9.2`) | Stable, GA | **Fully supported** — the recommended production line. Security and correctness patches. |
| **v2.0.0 beta** (`v2.0.0-beta.1` published; `v2.0.0-beta.2` draft) | Pre-release, **engine-only** | **Best-effort beta support** — engine-scope only. No framework live-validation guarantee. |
| **v2.0.0 alpha** (`v2.0.0-alpha.1`) | Superseded | **Unsupported.** Superseded by `v2.0.0-beta.1`. Upgrade. |
| pre-1.0 (`v0.x`) | Historical | **Unsupported.** |

### Engine vs framework-profile support (important)

- **Engine support** covers the STABLE engine surface: the driver CLIs
  (`resolve-gates`, `enforce-gates`, `build-security-summary`, `install-baseline`,
  `sync-baseline`, `doctor`, and the other documented commands), their exit-code
  contract, `SENTINEL_SHIELD_*` environment variables, the additive JSON schemas, and
  the adoption modes. The engine is validated by its own blocking self-test and
  GitHub-verified default-branch CI. **This is the guarantee the beta pre-releases
  carry.**
- **Framework-profile support** means a profile ships with manifests, fixtures, and
  engine tests. It **does not** by itself mean the profile was live-validated in a real
  Laravel/Symfony consumer repository. For v2 beta, **Laravel and Symfony framework
  live-validation is NOT included** and is deferred (see
  [`product-status.md`](product-status.md), [`v2-release-scope.md`](v2-release-scope.md)).
  A profile bug is supported to the extent it is reproducible against the engine and its
  fixtures; framework-specific behavior in a real app that the engine does not model is
  **out of scope** until that profile is live-validated.

Standalone-consumer status for v2 beta.2: **Node service + React app are live-tested**
(real npm/pnpm/yarn); the **standalone PHP-library consumer is structural only** (its live
composer/phpunit/phpstan/pint gates are CI-deferred SKIPs). Support follows that reality —
issues in the live-tested paths are in scope; the PHP-library live-tooling path is
best-effort until its gates run.

## Beta support duration

Beta support is **time-boxed and best-effort**. A beta pre-release (`v2.0.0-beta.*`) is
supported only until **one** of the following occurs, whichever is first:

- the **next beta or RC** in the same line is published (the prior beta is then
  superseded and unsupported — upgrade to the newer pre-release), or
- **v2.0.0 GA** is published (all v2 beta pre-releases become unsupported), or
- the v2 line is **withdrawn** (documented in the CHANGELOG and `product-status.md`).

There is **no long-term-support commitment for any beta pre-release.** Production use
should stay on the stable **v1.x** line. Beta adopters are expected to track the latest
pre-release.

## Severity classes

| Severity | Definition | Engine (v1.x / v2 engine scope) | Framework profile (v2 beta) |
| --- | --- | --- | --- |
| **S1 — Critical** | Security vulnerability in the engine; a gate that **fails open** (passes when it should fail); silent data/config loss; a failed transaction that does not fail closed. | Patch prioritized. | Patch prioritized **if** reproducible against the engine/fixtures. |
| **S2 — High** | A documented STABLE command/flag/exit-code behaving incorrectly; a fail-closed path that does not recover; broken rollback. | Patch in the supported line. | Best-effort; fixture repro required. |
| **S3 — Medium** | Incorrect but non-security output; coarse severity mapping producing wrong-but-visible results; doc↔CLI drift. | Fix scheduled. | Best-effort. |
| **S4 — Low** | Cosmetic, wording, or enhancement. | Backlog. | Backlog. |

Coarse severity mapping for `experimental` scanners (see `product-status.md`) is a
**known limitation**, not an S1/S2 defect, unless it causes a gate to fail open.

## What qualifies for a patch

A **patch** (a new tag on a supported line) is issued for:

- **S1 fail-open / security** defects in the STABLE engine surface — always.
- **S2** defects in a documented STABLE command, flag, exit code, schema, or env var on a
  **currently supported** line.
- **Broken fail-closed recovery** (an interrupted install/sync/migrate that does not
  retain its lock + snapshots or falsely claims success).
- **Doc↔CLI contract drift** where a documented command/flag no longer exists (guarded by
  `tests/prod/80-command-contract.sh`).

The following **do not** qualify for a patch on a beta line:

- Framework-specific behavior in a real Laravel/Symfony consumer that the engine does not
  model (deferred until that profile is live-validated).
- Requests to make a `supported`/`experimental` capability behave as `proven` without
  cited evidence.
- Feature requests (these are roadmap items, not patches).
- Issues only reproducible on an **unsupported** line (upgrade first).

Every claimed fix must ship with the same evidence discipline the project uses elsewhere:
a reproduction, a self-test/gate that guards the regression, and — for maturity changes —
cited CI evidence. Fixture existence is never treated as proof.

## Tag immutability

- **Published tags are immutable.** A released tag (`v1.9.2`, `v2.0.0-beta.1`, …) is never
  moved, re-pointed, or force-replaced. A defect is fixed by publishing a **new** tag.
- **Adopters must pin to an immutable tag or commit**, never a branch. Acquisition
  supports `--ref <tag|commit>` plus `--verify` (commit-identity) and optional tree/
  signed-tag verification (`scripts/lib/source-verification.sh`).
- **Two-commit release model.** v2 separates the CI-validated `engine_commit` (source)
  from an optional metadata-only `release_commit` that carries evidence, so a commit's own
  CI evidence is not circularly embedded in itself. Finalization is finite and creates the
  tag only on explicit `--execute` (`scripts/finalize-release-evidence.sh`).
- **Release provenance** is manifest/checksum-based and reproducible
  (`generate-release-manifest.sh` / `verify-release-manifest.sh`). **Cryptographic signing
  and build attestation are deferred** for v2 beta.

## Deprecation and migration policy

- **Additive-by-default.** Schemas and profile manifests evolve additively
  (`additionalProperties: true`; status enums gain values, none are renamed/removed).
  Existing manifests keep working across a minor/beta bump.
- **STABLE surfaces follow semver** on the stable line
  ([`product-contract.md`](product-contract.md)). A breaking change to a STABLE surface
  requires a **major** version and a migration guide.
- **Deprecations are announced before removal.** A STABLE surface slated for removal is
  marked deprecated in the CHANGELOG and relevant doc for **at least one minor (stable) or
  one beta (pre-release) cycle** before it is removed, with a documented replacement.
- **Every release ships a migration path.** v1 → v2:
  [`v2-migration-guide.md`](v2-migration-guide.md); beta.1 → beta.2:
  [`migration-beta1-to-beta2.md`](migration-beta1-to-beta2.md). Upgrades are dry-runnable
  (`plan-upgrade.sh`, `sync-baseline.sh --emit-plan`) before any write, and reversible via
  re-acquisition of an earlier immutable ref.

## Reporting an issue

Include: the exact tag/commit you pinned (`--ref`), the profile, the command and flags
run, the observed vs expected exit code, and a minimal reproduction. For machine-readable
context, attach the `--output json` envelope where the command supports it (secrets are
masked and absolute paths stripped). Do not attach secrets or raw scanner reports
containing sensitive data — use `scripts/support-bundle.sh` (redacted by default).
