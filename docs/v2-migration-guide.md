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
# 1. Pin the IMMUTABLE v2 engine ref (a published v2 tag or a full 40-char SHA —
#    never a moving branch, never an unreleased-GA placeholder) and acquire it.
SENTINEL_SHIELD_REF=<immutable v2 tag or full SHA>      # never main/master/HEAD/latest
SENTINEL_SHIELD_PATH=.sentinel-shield-tools
sh scripts/acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" --destination "$SENTINEL_SHIELD_PATH" --verify

# Every command below runs FROM the acquired checkout, not the consumer repo's scripts/.

# 2. See the tool plan the v2 profile expects (read-only, no mutation).
sh "$SENTINEL_SHIELD_PATH/scripts/resolve-tool-plan.sh" --profile laravel --target /path/to/project --format text

# 3. Sync managed files — DRY-RUN, review, then apply.
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target /path/to/project --profile laravel
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target /path/to/project --profile laravel --apply --force

# 4. Provision any newly-required tools (choose a mode — see tool-provisioning.md).
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" --target /path/to/project --profile laravel \
    --tool-mode require-existing            # dry-run by default; fails if a required tool is absent

# 5. Preflight, then reproduce the CI gate locally (authoritative; produces a REAL summary).
sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target /path/to/project --profile laravel
sh "$SENTINEL_SHIELD_PATH/scripts/run-local-pipeline.sh" --profile laravel --target /path/to/project --stage pr
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
   downgrade a noisy `recommended` to `optional`). You **cannot** set a
   non-suppressible secrets scanner (`gitleaks`, `trufflehog`) to `disabled` — the
   resolver fails closed (exit 2) — and you **cannot** convert an
   `execution-error` into a `pass`. Disabling a **required** tool does not silence
   its gate: it still fails unless covered by an unexpired **control-waiver**
   (`.sentinel-shield/control-waivers.json`, not `installation.json`'s
   `disabled_tools`) — see
   [`profile-tool-policy.md`](profile-tool-policy.md#disabling-a-required-control-control-waiver-not-disabled_tools).

## Rollback

Set `SENTINEL_SHIELD_REF` back to your prior immutable ref, re-acquire
(`acquire-sentinel-shield.sh … --verify`), and re-run
`sync-baseline.sh --apply --force` from that checkout. Because the tool-policy
additions are default-off where they would change behavior, reverting the ref
reverts the behavior.

If `bootstrap-tools --apply` touched dependency files, `bootstrap-profile-tools.sh`
auto-rolls them back on any install/test failure; when it reports
**rollback-incomplete** (package manager absent), finish the restore yourself with
the command for the lockfile that was restored (frozen, so the restored lockfile
wins):

```sh
npm ci                                             # package-lock.json
pnpm install --frozen-lockfile                     # pnpm-lock.yaml
yarn install --immutable                           # yarn.lock
composer install --no-interaction --prefer-dist    # composer.lock
```

Full rollback options: [`upgrading.md`](upgrading.md#rollback).
</content>
