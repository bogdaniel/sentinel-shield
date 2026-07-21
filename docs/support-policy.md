# Support Policy

This policy states what Sentinel Shield supports, for how long, and what qualifies for
a patch. It distinguishes **engine** support from **framework-profile** support, because
the two carry different validation guarantees. Where this document and marketing/README
prose disagree, [`product-status.md`](product-status.md) is the canonical maturity source
and this file is the canonical support-scope source.

> Version identifiers below use immutable examples.
> **`v2.0.1` is the published engine-only production release**, marked latest, tag target `32812ed`.
> `v2.0.0` remains an intact release, tag target `13be630`.
> An earlier revision of this note attributed v2.0.0's tag to v2.0.1. The **v1.x line (`v1.9.2`)
> remains supported**; framework live-validation is still excluded from the v2.0.0 scope.

## Supported lines

| Line | Status | Support |
| --- | --- | --- |
| **v2.0.0** (`v2.0.1`, engine-only) | Published production release, **latest** | **Supported — engine scope only.** Security and correctness patches for the STABLE engine surface. **No framework live-validation guarantee** (Laravel/Symfony not live-validated). |
| **v1.x** (latest `v1.9.2`) | Stable, GA | **Fully supported** — security and correctness patches. |
| **v2.0.0 pre-releases** (`v2.0.0-beta.1`, `v2.0.0-rc.1`) | Superseded | **Unsupported.** Superseded by `v2.0.1`. Upgrade. |
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

Standalone-consumer status: **Node service, React app and the PHP-library consumer are all
structural only.** The Node/React LIVE tier (real npm/pnpm/yarn) is gated on
`SS_CONSUMER_LIVE=1`, which nothing in this repository sets, so CI records
`skip/LIVE_UNAVAILABLE`; the PHP-library consumer's composer/phpunit/phpstan/pint gates are
CI-deferred SKIPs. An earlier revision claimed Node + React were live-tested, contradicting
[`product-status.md`](product-status.md).

Support follows that reality: issues in the **structurally verified** paths are in scope;
every live-tooling path is best-effort until its gates actually run.

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

## Platform & toolchain compatibility

The set of operating systems, CPU architectures, shells, and tool versions the **engine** runs on
is declared once, machine-readably, in [`config/compatibility-policy.json`](../config/compatibility-policy.json)
(schema: [`schemas/compatibility-policy.schema.json`](../schemas/compatibility-policy.schema.json))
and rendered in [`docs/compatibility.md`](compatibility.md). It is enforced by the fail-closed gate
`sh scripts/health.sh` and reported by `sh scripts/doctor.sh`.

Lifecycle rules specific to that matrix:

- **Fail closed with a stable reason.** An unsupported OS, architecture, shell, or below-minimum
  mandatory tool fails with a stable `reason=<CODE>` (e.g. `UNSUPPORTED_NODE_VERSION`,
  `UNSUPPORTED_SHELL`), never an incidental command error. `health.sh` exits **3** (unsupported),
  **4** (a bounded probe timed out — unverifiable), or **2** (bad/missing policy). `doctor.sh`
  mirrors a definite host incompatibility as exit **5**.
- **Supported ≥ tested ≥ pinned.** *Supported* is what the gate accepts; *tested* is what the
  `ci-compatibility.yml` matrices exercise; release-critical CI pins a dated runner image.
- **Track upstream, announce before removal.** PHP tracks php.net active branches (8.1–8.4); Node
  tracks even-numbered LTS lines (18, 20, 22); package managers track npm **8–11**, pnpm **8–10**,
  Yarn **1–4**; GitHub runner images are dropped within one `policy_version` of GitHub's own
  deprecation. A currently-supported configuration is removed no sooner than one minor
  `policy_version` after it is announced deprecated. Mandatory-tool floors (Git 2.20, jq 1.6)
  advance no faster than one minor `policy_version` per year.
- **Adding support is test-gated.** A new configuration is not "supported" until it is added to the
  policy JSON **and** guarded by [`tests/prod/260-compatibility-policy.sh`](../tests/prod/260-compatibility-policy.sh)
  and (where a real toolchain is involved) a matrix row in
  [`.github/workflows/ci-compatibility.yml`](../.github/workflows/ci-compatibility.yml).

See [`docs/compatibility.md`](compatibility.md) for the full rendered matrix and stable reason codes.

## Reporting an issue

Include: the exact tag/commit you pinned (`--ref`), the profile, the command and flags
run, the observed vs expected exit code, and a minimal reproduction. For machine-readable
context, attach the `--output json` envelope where the command supports it (secrets are
masked and absolute paths stripped). Do not attach secrets or raw scanner reports
containing sensitive data — use `scripts/support-bundle.sh` (redacted by default).

## Incident, rollback, and release remediation

Support remediation never mutates a published tag. A defect in a released version is fixed by
publishing a **superseding** release and issuing an advisory that marks the affected version;
when no fix is ready yet, the advisory recommends pinning to a known-good prior version. See
[`rollback-policy.md`](rollback-policy.md) for the policy and the
`scripts/authorize-production-release.sh declare-superseded` / `rollback-advisory` commands, and
[`security-incident-response.md`](security-incident-response.md) for the incident workflow. The
production release path itself is governed by
[`production-release-runbook.md`](production-release-runbook.md).
