# v1 → v2 Migration Guide

`v2` introduces the **profile tool-policy contract**: profiles now declare the
tools they expect, how those tools are detected/installed/configured/executed,
and how each is **gated**. The contract is
[`profile-tool-policy.md`](profile-tool-policy.md) (the canonical source of truth)
backed by [`schemas/tool-policy.schema.json`](../schemas/tool-policy.schema.json).
This guide is the human migration path. For the routine bump-and-sync mechanics
see [`upgrading.md`](upgrading.md).

## What changed (additive, not a contract break)

- **Tool policy** — profile manifests carry an optional `tools` map
  ($ref `toolsMap`), `extends`, and `tool_policy_version`. Existing manifests
  without these keep working (`additionalProperties:true`).
- **Result states** — the per-tool `status` enum is now additive: legacy
  `pass/fail/warn/skipped/unavailable` **plus** `findings`, `not-configured`,
  `not-applicable`, `execution-error`, `disabled`. Nothing was renamed or removed.
- **Installation record** — installs/syncs write
  `.sentinel-shield/installation.json`
  ([schema](../schemas/installation.schema.json)): `version`, `profile`,
  `profile_schema`, `tool_mode`, `managed_files`, `project_owned_files`,
  `enabled_tools`, `disabled_tools`. This lets sync reason about managed vs
  project-owned files and which tools are enabled.
- **Project override** — `.sentinel-shield/tool-policy.yaml`
  ([schema](../schemas/tool-policy-override.schema.json)) lets a project tune the
  **`policy`** of a tool the profile already declares (and only that).
- **Tool provisioning** — `install-baseline.sh` gained `--tool-mode`
  (`config-only` | `require-existing` | `bootstrap-tools`); see
  [`tool-provisioning.md`](tool-provisioning.md).

## Migration steps

```sh
# 1. Bump the engine ref to v2.0.0.
SENTINEL_SHIELD_REF=v2.0.0
git -C "$SENTINEL_SHIELD_PATH" fetch --tags && git -C "$SENTINEL_SHIELD_PATH" checkout "$SENTINEL_SHIELD_REF"

# 2. See the tool plan the v2 profile expects (read-only, no mutation).
sh scripts/resolve-tool-plan.sh --profile laravel --target /path/to/project --format text

# 3. Sync managed files — DRY-RUN, review, then apply.
sh scripts/sync-baseline.sh --target /path/to/project --profile laravel
sh scripts/sync-baseline.sh --target /path/to/project --profile laravel --apply --force

# 4. Provision any newly-required tools (choose a mode — see tool-provisioning.md).
sh scripts/install-baseline.sh --target /path/to/project --profile laravel \
    --tool-mode require-existing            # dry-run by default; fails if a required tool is absent

# 5. Preflight and confirm a real security-summary.json is produced.
sh scripts/doctor.sh --target /path/to/project --profile laravel
```

`sync-baseline.sh` is **dry-run by default**; `install-baseline.sh` is too (add
`--apply` to write). Always read the dry-run report before applying.

## Two different "modes" — don't confuse them

`v2` has two independent axes that both happen to be called *tool mode*:

| Axis | Where | Values | Means |
| --- | --- | --- | --- |
| **Provisioning** | `install-baseline.sh --tool-mode` | `config-only` · `require-existing` · `bootstrap-tools` | *How* a profile's tools get onto the box at install time. See [`tool-provisioning.md`](tool-provisioning.md). |
| **Enforcement** | `installation.json.tool_mode`, `doctor.sh --tool-mode` | `config-only` · `require-existing` · `bootstrap-tools` | *Whether* absent required tools gate. `config-only` warns; `require-existing`/`bootstrap-tools` exit 3. A tool whose policy is `external` is never gated. See [`workflow-execution-model.md`](workflow-execution-model.md). |

## Adopting tool policy incrementally

You do not have to enable everything at once.

1. **Stay config-only.** Migrate, sync managed files, leave dependency files
   untouched. Missing required tools are reported, not fatal.
2. **Tighten to require-existing** once the tools your team already uses are
   present — this makes an absent required tool a hard preflight failure.
3. **Use bootstrap-tools** only when you want Sentinel Shield to install the
   packages for you (with automatic rollback). See
   [`tool-provisioning.md`](tool-provisioning.md).
4. **Tune policy per project** in `.sentinel-shield/tool-policy.yaml` (e.g.
   downgrade a noisy `recommended` to `optional`). You **cannot** disable a
   non-suppressible control (e.g. `secrets`) without a documented accepted-risk
   record, and you **cannot** convert an `execution-error` into a `pass`
   ([`accepted-risk-suppression.md`](accepted-risk-suppression.md)).

## Rollback

Set `SENTINEL_SHIELD_REF` back to your prior tag and re-run
`sync-baseline.sh --apply --force`. Because the tool-policy additions are
default-off where they would change behavior, reverting the ref reverts the
behavior. Full rollback options: [`upgrading.md`](upgrading.md#rollback).
</content>
