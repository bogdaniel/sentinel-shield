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
# 1. Pin the IMMUTABLE engine ref you are upgrading to (a tag or full 40-char SHA,
#    never a moving branch). There is no GA default — supply the exact approved ref.
SENTINEL_SHIELD_REF=<immutable tag or full SHA>      # never main/master/HEAD/latest
SENTINEL_SHIELD_PATH=.sentinel-shield-tools

# 2. Acquire the engine at that ref. The acquire bootstrap is the ONE script run
#    directly (it CREATES the checkout); --verify checks the resolved commit.
sh scripts/acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" --destination "$SENTINEL_SHIELD_PATH" --verify

# 3. Every other engine command runs FROM the acquired checkout. Preview drift —
#    DRY-RUN first, always.
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target /path/to/project --profile laravel

# 4. Apply managed-file updates after reviewing the drift report.
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target /path/to/project --profile laravel --apply --force

# 5. Bump SENTINEL_SHIELD_REF in the consumer's workflows to the same ref.
```

`sync-baseline.sh` categorizes every file as `created` / `updated` /
`up-to-date` / `manual-review-needed` / `project-local-preserved`. `--force`
updates **only** managed files (`overwrite-if-force`, `sync-managed-block`); it
never touches `accepted-risks.json`, `phpstan-baseline.neon`, project-owned
(`create-if-missing`) files, or your code. See
[`tool-provisioning.md`](tool-provisioning.md) for managed vs project-owned rules
and [`workflow-execution-model.md`](workflow-execution-model.md) for migrating the
CI workflow itself.

## Upgrading `v2.0.1` → `v2.2.0` (current release)

Shipped workflow templates now pin `SENTINEL_SHIELD_REF: v2.2.0` — the current release
recorded in [`config/release-status.json`](../config/release-status.json). Existing
consumers installed from an older checkout are still pinned to `v2.0.1` and keep running
that engine until they bump the ref: **nothing changes under you**, because the pin is
immutable and consumer-owned.

`v2.2.0` is backward-compatible with `v2.0.1` — no stable CLI, exit code, environment
variable, or schema was renamed or removed, and the three new engineering-governance gate
families (testing-discipline, engineering-quality, architecture governance v2) are **off by
default in existing modes**. A project that bumps the ref and changes nothing else sees no
new blocking gate.

```sh
# 1. Bump the pin in every installed Sentinel Shield workflow.
#    A tag is immutable and fine; production SHOULD use the full commit the tag targets:
#    v2.2.0 -> 99fcd2767560b257344211aae57e027ea39a5304
SENTINEL_SHIELD_REF=v2.2.0

# 2. Re-acquire and preview managed-file drift BEFORE writing anything.
sh scripts/acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" --destination "$SENTINEL_SHIELD_PATH" --verify
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target . --profile <profile>

# 3. Apply, then verify locally before pushing.
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target . --profile <profile> --apply --force
sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target . --profile <profile>
sh "$SENTINEL_SHIELD_PATH/scripts/run-local-pipeline.sh" --profile <profile> --target . --stage pr
```

**Opting into the new gate families** is a separate, deliberate step: raise the mode
(`strict` / `regulated`) or list the new gate keys in `gates.fail_on`. Do it report-only
first, exactly like every other gate ([`production-rollout.md`](production-rollout.md)).

**Rolling back to `v2.0.1`** is the standard rollback below: set `SENTINEL_SHIELD_REF`
back to `v2.0.1` (tag target `32812ed43289104af61b0eb2fc20c784ca2b72c1`), re-acquire, and
re-run `sync-baseline.sh --apply --force` from that checkout. Both tags are immutable, so
the prior managed files are always reproducible. `v2.0.x` stays on security patches only
until the next feature release ([`support-policy.md`](support-policy.md)).

## Preview a tool plan while you sync

Both installer and sync can emit the read-only resolver plan (no mutation, no
network) so you can see exactly which tools the new release expects:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/sync-baseline.sh" --target . --profile laravel --emit-plan upgrade-plan.json
sh "$SENTINEL_SHIELD_PATH/scripts/resolve-tool-plan.sh" --profile laravel --target . --format text
```

Each tool resolves to `already-installed`, `install-compatible`, `conflict`, or
`no-package`. Conflicts are reported, never auto-resolved — see
[`tool-provisioning.md`](tool-provisioning.md#dependency-conflicts).

## Verify after upgrading

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/doctor.sh" --target . --profile laravel    # preflight (tools, config, gates)

# Authoritative local check: the local pipeline reproduces the CI release gate
# (produces a REAL reports/security-summary.json and runs enforce-gates).
sh "$SENTINEL_SHIELD_PATH/scripts/run-local-pipeline.sh" --profile laravel --target . --stage pr
```

`doctor.sh --tool-mode config-only|require-existing|bootstrap-tools` checks required-tool
enforcement (see [`workflow-execution-model.md`](workflow-execution-model.md#required-tool-enforcement)).
`run-local-pipeline.sh` is the **authoritative** local equivalent of the CI gate; the
opportunistic `run-local-scanner-sweep.sh` is **not** — a clean sweep never proves a pass.

## Rollback

Tags are immutable, so the prior behavior is always retrievable:

- **Engine version:** set `SENTINEL_SHIELD_REF` back to the prior immutable ref,
  re-acquire (`acquire-sentinel-shield.sh … --verify`), and re-run
  `sync-baseline.sh --apply --force` from that checkout to restore the prior
  managed files.
- **Dependency files:** `bootstrap-profile-tools.sh` rolls back
  `composer.json/lock` + `package.json/lock` (+ `pnpm-lock.yaml`/`yarn.lock`)
  automatically on any install/test failure. Limitation: it restores the
  manifests/lockfiles but can only rebuild `node_modules/`/`vendor/` if the package
  manager is present — otherwise it reports **rollback-incomplete** and you re-run
  the install yourself, using the command for the restored lockfile (frozen, so the
  restored lockfile wins — never a re-resolve):

  ```sh
  npm ci                                             # package-lock.json
  pnpm install --frozen-lockfile                     # pnpm-lock.yaml
  yarn install --immutable                           # yarn.lock
  composer install --no-interaction --prefer-dist    # composer.lock
  ```

  If you committed an upgrade you regret, `git revert` the dependency commit.
- **Adoption mode:** lower `gates.mode` in `.sentinel-shield/profile.yaml`
  (e.g. `strict → baseline`) — no engine change needed.
- **Scanner image digests:** keep the prior `@sha256:` pin
  ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).

### When automatic recovery itself fails (exit 4)

A transactional install/sync/migration takes an **operation lock**
(`.sentinel-shield/operation-lock.json`) and snapshots the files it is about to
change. If a step breaks, it auto-rolls back. **If that rollback cannot complete**
(e.g. a file can no longer be restored), the engine does **not** pretend it
succeeded: it **exits `4`**, **retains the operation lock and the snapshot
directory**, marks the lock `state:"rollback-incomplete"`, and prints the manual
recovery steps. Nothing is cleaned up, because the snapshots are the only way back.

Recover manually, then clear the lock — never delete the snapshots until the tree is
restored:

```sh
# 1. Inspect what was in flight (operation, target, snapshot_dir).
jq . .sentinel-shield/operation-lock.json
# 2. Restore project files from the retained snapshot_dir it names.
# 3. Verify the working tree, then remove the lock + snapshot dir to release it.
```

Treat a stale lock as untrusted: re-validate that `target` and `snapshot_dir` are
inside your project before acting on them. A `rollback-incomplete` exit is a real
failure to report — it is never a success.

## Update paths

- **Manually** — the flow above (bump ref → sync dry-run → `--apply --force`).
- **Through an AI agent** — see [`ai-assisted-update.md`](ai-assisted-update.md).
- **Provisioning new required tools** the release introduced — see
  [`tool-provisioning.md`](tool-provisioning.md).

Whichever path you take: **never** edit managed files in place (changes are lost
on the next sync) and **never** suppress a finding to keep the gate green.
