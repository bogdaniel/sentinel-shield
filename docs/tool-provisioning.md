# Tool Provisioning

How a profile's declared tools get onto a project at install/upgrade time. The
policy contract (what each tool *is*, how it's detected, gated) lives in
[`profile-tool-policy.md`](profile-tool-policy.md); this doc is about the
**provisioning mechanics** — the `--tool-mode` flag, dependency-conflict
handling, isolated installation, and managed vs project-owned files.

## The three provisioning modes (`install-baseline.sh --tool-mode`)

Default is `config-only`. The installer is **dry-run by default**; add `--apply`
to write.

| `--tool-mode` | What it does | When a required tool is absent |
| --- | --- | --- |
| `config-only` *(default)* | Installs Sentinel Shield files only. **Never** touches `composer.json` / `package.json`. | Reported, **non-fatal**. |
| `require-existing` | Installs no packages. Validates the project **before** writing any files. | **Fails preflight** (exit 1). Recommended-but-absent → warning. |
| `bootstrap-tools` | Inspects runtime versions and prints the exact install plan; with `--apply`, installs the packages, validates lockfiles, runs tests, and **rolls back** on any failure. | Installed if `install-compatible`; a `conflict` is reported, not forced. |

```sh
# config-only (default): SS files only, report missing required tools
sh scripts/install-baseline.sh --target . --profile laravel --apply

# require-existing: fail fast if a required tool's executable is absent
sh scripts/install-baseline.sh --target . --profile laravel --tool-mode require-existing --apply

# bootstrap-tools: install the profile's required packages, with rollback
SENTINEL_SHIELD_REF=v2.0.0 \
sh scripts/install-baseline.sh --target . --profile laravel --tool-mode bootstrap-tools --apply
```

> Detection is deterministic and read-only: a tool is "present" when one of its
> `executable[]` entries resolves (first match wins, e.g. `vendor/bin/phpstan`
> then `phpstan`). External/CI-provided scanners with no local executable
> (gitleaks, semgrep) are not validated locally.

## Preview the plan before doing anything (read-only)

`resolve-tool-plan.sh` and `bootstrap-profile-tools.sh --dry-run` inspect the
project (installed PHP/Composer, Node/npm, framework) and classify every tool
**without** mutating anything or hitting the network:

```sh
sh scripts/resolve-tool-plan.sh --profile laravel --target . --format text
sh scripts/resolve-tool-plan.sh --profile laravel --target . --format json   # machine-readable
sh scripts/bootstrap-profile-tools.sh --profile laravel --target .           # dry-run (default)
```

`install-baseline.sh --emit-plan <path>` writes the same JSON plan while it runs.

## <a id="dependency-conflicts"></a>Dependency conflicts

Each tool's package resolves to one decision:

| decision | meaning | provisioning action |
| --- | --- | --- |
| `already-installed` | the package (or executable) is present | nothing to do |
| `install-compatible` | constraint resolves against the project runtime | included in the `composer require` / `npm install` command |
| `conflict` | constraint cannot be satisfied (e.g. PHP/framework version) | **reported, never forced** — resolve the conflict yourself, then re-run |
| `no-package` | tool has no installable package (external/CI scanner) | skipped |

`bootstrap-tools` only installs the `install-compatible` **required + enabled**
set. A `conflict` is surfaced in the plan and left for you — Sentinel Shield does
not override your version constraints. Package `compatibility` is `auto` (let the
resolver choose) or a literal constraint string in the manifest.

## Isolated tool installation (rollback-safe)

`bootstrap-profile-tools.sh --apply` is the isolated install path:

1. Snapshots `composer.json`, `composer.lock`, `package.json`,
   `package-lock.json`.
2. Runs `composer require --dev …` / `npm install --save-dev …` for the
   install-compatible required tools (dev vs prod from each package's `scope`).
3. Validates the lockfile (`composer validate`, JSON-parse the npm lock).
4. Runs the project's `test` script if one exists.
5. **Rolls back all dependency files** to their prior state on *any* failure.

Rollback restores the snapshotted manifests/lockfiles (`composer.json/lock`,
`package.json/lock`, `pnpm-lock.yaml`, `yarn.lock`). Reconstructing the installed
tree (`node_modules/`) from the restored lockfile needs the package manager
present; if it is unavailable the manifests are restored but the install tree may
not be — reported as **rollback-incomplete** (re-run the package manager's install
to finish).

It never silently mutates dependency files — `--apply` is always explicit, and
nothing is committed for you. `install-baseline.sh --tool-mode bootstrap-tools
--apply` delegates to this script.

### Node package manager detection

The Node package manager is chosen by lockfile: `pnpm-lock.yaml` ⇒ pnpm,
`yarn.lock` ⇒ yarn, `package-lock.json` ⇒ npm. If **multiple** distinct Node
lockfiles are present the package manager is ambiguous and
`bootstrap-profile-tools.sh` exits **2** — set `package.json`'s `packageManager`
field to disambiguate. (The `npm-audit` runner independently picks pnpm/yarn/npm
the same way, and with no lockfile leaves its report absent — `unavailable`, never
fake-clean.)

## Managed vs project-owned files

The installer classifies every file it places; sync/upgrade honors the class.
The record lives in `.sentinel-shield/installation.json`
(`managed_files`, `project_owned_files` —
[schema](../schemas/installation.schema.json)).

| Class (manifest file mode) | Owner | Overwritten on sync? |
| --- | --- | --- |
| `overwrite-if-force`, `sync-managed-block` | **Sentinel Shield (managed)** | Yes, with `--apply --force` only |
| `create-if-missing` | **Project** | No — preserved if it exists |
| `manual` | You decide | Never auto-written |
| `never_touch` (e.g. `accepted-risks.json`, `phpstan-baseline.neon`) | **Project (protected)** | **Never** |

Rule of thumb: **never hand-edit a managed file** — your edit is lost on the next
sync. Put project choices in `.sentinel-shield/profile.yaml`, project-local config
(e.g. `phpstan.neon`, which is `never_touch`), and policy tweaks in
`.sentinel-shield/tool-policy.yaml`. See
[`workflow-execution-model.md`](workflow-execution-model.md) for how provisioned
tools become CI execution steps, and [`upgrading.md`](upgrading.md) for the full
upgrade flow.
</content>
