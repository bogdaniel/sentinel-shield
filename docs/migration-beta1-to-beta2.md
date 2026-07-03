# Migration: `v2.0.0-beta.1` → `v2.0.0-beta.2`

This guide covers upgrading an adopter from the published **`v2.0.0-beta.1`**
engine-only pre-release to the **`v2.0.0-beta.2`** increment. beta.2 is an
**additive, production-readiness hardening** step: **no STABLE engine CLI, exit
code, environment variable, or schema was renamed or removed.** For the v1 → v2
contract change (profile tool-policy), read
[`v2-migration-guide.md`](v2-migration-guide.md) first — this document assumes you
are already on v2.

> **Framework live-validation is still excluded.** beta.2 does **not** add
> real-consumer validation for the Laravel or Symfony profiles; they remain
> engine- and fixture-tested only. The standalone PHP-library consumer is
> **structural only** (live composer/phpunit/phpstan/pint gates are CI-deferred
> SKIPs). See [Known limitations](#known-limitations).
>
> Version identifiers written as `<...>` are **placeholders** pending the release
> commit and tag. Always pin to an **immutable tag or commit**, never a branch.

## What you get by upgrading

- Fail-closed handling of unparseable scanner output (`parser-error` → exit 2).
- Updated, SHA-pinned scanner actions (OSV `v2.3.8`, Grype `v7.4.0`).
- Opt-in `--output json` machine envelope on the seven driver commands.
- Shared transaction library, transaction journal, and operator recovery
  (`scripts/recover-operation.sh`).
- Optional source tree/tag verification (`scripts/lib/source-verification.sh`).
- Governance and workflow-runtime audit gates in `ci-workflow-lint`.
- Release evidence/manifest/finalization tooling.

See [`v2.0.0-beta.2-release-notes.md`](v2.0.0-beta.2-release-notes.md) for the full
change list.

## Upgrade steps

These steps assume the standard vendored-engine layout, where the engine checkout
lives in a dedicated tools directory referenced by `SENTINEL_SHIELD_PATH`. Adjust
paths to your setup; do **not** assume an internal path.

1. **Read what changed.** Review the release notes and the
   [breaking / migration-relevant changes](#breaking--migration-relevant-changes)
   below.

2. **Re-acquire the engine at the beta.2 immutable ref.** Use
   `acquire-sentinel-shield.sh` with an immutable ref and integrity verification:

   ```sh
   sh "$SENTINEL_SHIELD_PATH/scripts/acquire-sentinel-shield.sh" \
     --repository bogdaniel/sentinel-shield \
     --destination <your-tools-dir> \
     --ref <v2.0.0-beta.2>            # immutable tag or commit — never a branch
   # then verify the checkout matches the resolved ref:
   sh "$SENTINEL_SHIELD_PATH/scripts/acquire-sentinel-shield.sh" \
     --repository bogdaniel/sentinel-shield \
     --destination <your-tools-dir> \
     --ref <v2.0.0-beta.2> --verify
   ```

3. **Dry-run the plan before touching your project.** `plan-upgrade.sh` is
   read-only (it writes nothing except an optional `--output` report):

   ```sh
   sh "$SENTINEL_SHIELD_PATH/scripts/plan-upgrade.sh" --target .
   ```

4. **Preview the config sync (no writes).** `sync-baseline.sh` without `--apply`
   is a dry-run; add `--emit-plan` to capture the plan:

   ```sh
   sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" \
     --target . --profile <your-profile> --emit-plan
   ```

5. **Apply the sync.** Only managed files are touched; accepted-risk and
   project-owned files are left alone:

   ```sh
   sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" \
     --target . --profile <your-profile> --apply
   ```

6. **Re-pin scanner actions if you copied the engine templates.** If your
   workflows were copied from the engine, re-pin OSV-Scanner to **`v2.3.8`** and
   `anchore/scan-action` to **`v7.4.0`** at their new SHAs (see `ci-security.yml`
   in the engine as the reference). If you maintain your own pins, nothing to do.

7. **Verify.** Run the doctor preflight; optionally capture machine output:

   ```sh
   sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target . --profile <your-profile>
   # optional machine-readable envelope (human output + exit code unchanged):
   sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target . --output json
   ```

## Breaking / migration-relevant changes

None break the STABLE contract. The behavior changes that can affect automation:

- **`parser-error` now fails closed (exit 2).** A scanner emitting output that
  cannot be parsed will now **fail the run** instead of being treated as clean. If
  a pipeline was silently tolerating a broken scanner, fix the scanner or its
  configuration; do not suppress the failure.
- **`--output json` is opt-in and additive.** Existing invocations are unchanged.
  Consume the envelope via `schemas/command-result.schema.json`; the envelope masks
  secrets and strips absolute local paths.
- **Scanner action versions moved** (OSV `v2.3.8`, Grype `v7.4.0`). Only relevant
  if you copied the engine's workflow templates.

## Recovery guidance (interrupted operations)

Install / sync / migration are transactional and fail-closed. If an operation is
interrupted, it retains its operation lock and per-file snapshots; nothing claims
success on a partial state.

- **Inspect** an interrupted operation (read-only; exit 4 if the journal is
  tampered/partial):

  ```sh
  sh "$SENTINEL_SHIELD_PATH/scripts/recover-operation.sh" inspect --target .
  ```

- **Recover** by resuming the same fail-closed rollback the install/sync/migrate
  scripts expose. Run `recover-operation.sh` without arguments (or with `--help`)
  to see the exact recovery mode and options for your engine version. A rollback
  that cannot complete **exits 4**, keeps the lock + snapshots
  (`state: "rollback-incomplete"`), and prints a manual recovery procedure — it
  never deletes recovery data and never claims success.

## Rollback (returning to beta.1 or v1.x)

Because `v2.0.0-beta.2` is a pre-release, rolling back means re-acquiring an earlier
immutable ref and re-syncing:

1. Re-acquire the engine at `<v2.0.0-beta.1>` (or a v1.x tag such as `v1.9.2`) with
   `acquire-sentinel-shield.sh --ref <tag> --verify`.
2. `plan-upgrade.sh --target .` (dry-run) to preview the downgrade delta.
3. `sync-baseline.sh --target . --profile <your-profile> --apply` to restore the
   managed config for that version.
4. Restore any scanner-action pins to the versions that ref shipped.

Consumer-side dependency rollback (`npm`/`pnpm`/`yarn`) is exercised byte-for-byte
in the engine's own consumer tests; the transactional installer restores managed
files to their pre-operation bytes on failure.

## Known limitations

- **Laravel and Symfony are NOT live-validated** in real consumer repositories —
  engine + fixture coverage only.
- **The standalone PHP-library consumer is STRUCTURAL only**; its live
  composer/phpunit/phpstan/pint gates are **CI-deferred SKIPs**, not proven locally.
- **Signing / attestation are deferred** (optional for beta.2).
- The release runs under `engine-only` scope and cannot claim framework-validated
  status.

For canonical maturity, see [`product-status.md`](product-status.md).
