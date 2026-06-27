# Upgrading Sentinel Shield

How to move a consuming project from one Sentinel Shield release to a newer one
**safely** — preview drift before writing, never clobber project-local decisions,
and roll back deterministically. For the major `v1 → v2` jump see
[`v2-migration-guide.md`](v2-migration-guide.md). The tool contract every step
relies on is [`profile-tool-policy.md`](profile-tool-policy.md).

## The model in one paragraph

A consumer pins the engine via `SENTINEL_SHIELD_REF` (a tag or full SHA, never a
moving branch). Upgrading means **bumping that ref** and then re-running
`sync-baseline.sh` so the project's **managed** files catch up to the new release.
**Project-owned** files (your config, accepted risks) are never overwritten. What
the installer placed, and which tools are enabled, is recorded in
`.sentinel-shield/installation.json` ([`schemas/installation.schema.json`](../schemas/installation.schema.json))
so sync can reason about managed vs project-owned paths.

## Standard upgrade (drop-in minor)

```sh
# 1. Bump the engine to the new tag (in your engine checkout / the path the
#    workflow uses via SENTINEL_SHIELD_PATH).
SENTINEL_SHIELD_REF=v2.0.0
git -C "$SENTINEL_SHIELD_PATH" fetch --tags
git -C "$SENTINEL_SHIELD_PATH" checkout "$SENTINEL_SHIELD_REF"

# 2. Preview drift — DRY-RUN first, always.
sh scripts/sync-baseline.sh --target /path/to/project --profile laravel

# 3. Apply managed-file updates after reviewing the drift report.
sh scripts/sync-baseline.sh --target /path/to/project --profile laravel --apply --force

# 4. Bump SENTINEL_SHIELD_REF in the consumer's workflows to the same tag.
```

`sync-baseline.sh` categorizes every file as `created` / `updated` /
`up-to-date` / `manual-review-needed` / `project-local-preserved`. `--force`
updates **only** managed files (`overwrite-if-force`, `sync-managed-block`); it
never touches `accepted-risks.json`, `phpstan-baseline.neon`, project-owned
(`create-if-missing`) files, or your code. See
[`tool-provisioning.md`](tool-provisioning.md) for managed vs project-owned rules
and [`workflow-execution-model.md`](workflow-execution-model.md) for migrating the
CI workflow itself.

## Preview a tool plan while you sync

Both installer and sync can emit the read-only resolver plan (no mutation, no
network) so you can see exactly which tools the new release expects:

```sh
sh scripts/sync-baseline.sh --target . --profile laravel --emit-plan upgrade-plan.json
sh scripts/resolve-tool-plan.sh --profile laravel --target . --format text
```

Each tool resolves to `already-installed`, `install-compatible`, `conflict`, or
`no-package`. Conflicts are reported, never auto-resolved — see
[`tool-provisioning.md`](tool-provisioning.md#dependency-conflicts).

## Verify after upgrading

```sh
sh scripts/doctor.sh --target . --profile laravel    # preflight (tools, config, gates)
# confirm your pipeline still produces a real reports/security-summary.json
```

`doctor.sh --tool-mode config-only|require-existing|bootstrap-tools` checks required-tool
enforcement (see [`workflow-execution-model.md`](workflow-execution-model.md#required-tool-enforcement)).

## Rollback

Tags are immutable, so the prior behavior is always retrievable:

- **Engine version:** set `SENTINEL_SHIELD_REF` back to the prior tag and re-run
  `sync-baseline.sh --apply --force` to restore the prior managed files.
- **Dependency files:** `bootstrap-profile-tools.sh` rolls back
  `composer.json/lock` + `package.json/lock` automatically on any install/test
  failure. If you committed an upgrade you regret, `git revert` the dependency
  commit.
- **Adoption mode:** lower `gates.mode` in `.sentinel-shield/profile.yaml`
  (e.g. `strict → baseline`) — no engine change needed.
- **Scanner image digests:** keep the prior `@sha256:` pin
  ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).

## Update paths

- **Manually** — the flow above (bump ref → sync dry-run → `--apply --force`).
- **Through an AI agent** — see [`ai-assisted-update.md`](ai-assisted-update.md).
- **Provisioning new required tools** the release introduced — see
  [`tool-provisioning.md`](tool-provisioning.md).

Whichever path you take: **never** edit managed files in place (changes are lost
on the next sync) and **never** suppress a finding to keep the gate green.
</content>
</invoke>
