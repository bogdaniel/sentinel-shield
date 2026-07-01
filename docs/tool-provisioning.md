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

Acquire the engine at an **immutable** ref first (a tag or full 40-char SHA,
never a moving branch); every command below runs **from that checkout**, not from
the consumer repo's own `scripts/`. The acquire bootstrap is the one exception —
it *creates* the checkout (see [`upgrading.md`](upgrading.md)).

```sh
# 0. Pin + acquire the engine (the bootstrap is the only script not run from the checkout).
SENTINEL_SHIELD_REF=<immutable tag or full SHA>      # never main/master/HEAD/latest
SENTINEL_SHIELD_PATH=.sentinel-shield-tools
sh scripts/acquire-sentinel-shield.sh --repository bogdaniel/sentinel-shield \
  --ref "$SENTINEL_SHIELD_REF" --destination "$SENTINEL_SHIELD_PATH" --verify

# config-only (default): SS files only, report missing required tools
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" --target . --profile laravel --apply

# require-existing: fail fast if a required tool's executable is absent
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" --target . --profile laravel --tool-mode require-existing --apply

# bootstrap-tools: install the profile's required packages, with rollback
sh "$SENTINEL_SHIELD_PATH/scripts/install-baseline.sh" --target . --profile laravel --tool-mode bootstrap-tools --apply
```

### Acquisition safety (destructive-cleanup guard + no path leak)

`acquire-sentinel-shield.sh` only ever mutates the `--destination` you give it, and
it **validates that destination before doing anything destructive**. `--cleanup`
(and re-acquiring over an existing checkout) refuses an **unsafe** destination and
exits `2` *without deleting anything*: the current directory (`.`), a parent
(`..`), the filesystem root (`/`), `$HOME`, the repo root, any ancestor of the repo
root, or a path that a symlink would let the delete **escape** outside the intended
tools directory. Only a **dedicated tools directory** (e.g. `.sentinel-shield-tools/`)
is accepted as a destination — so a copy-pasted `--cleanup` can never `rm -rf` your
working tree or home directory.

```sh
# Safe: removes only the dedicated tools checkout.
sh scripts/acquire-sentinel-shield.sh --destination .sentinel-shield-tools --cleanup
# Refused (exit 2, nothing deleted): unsafe destinations.
sh scripts/acquire-sentinel-shield.sh --destination . --cleanup        # repo root → refused
sh scripts/acquire-sentinel-shield.sh --destination "$HOME" --cleanup  # $HOME    → refused
```

The acquisition record written to `<destination>/.sentinel-shield-ref` is
**normalized and never stores a local or home path**: a GitHub shorthand records
`repository_kind:"github"` + `repository:"owner/repo"`; an explicit remote URL
records `repository_kind:"url"` with any credentials/query/fragment stripped; a
**local** source path records `repository_kind:"local"` and `repository:null` — the
on-disk path is deliberately **not persisted**.

> Detection is deterministic and read-only: a tool is "present" when one of its
> `executable[]` entries resolves (first match wins, e.g. `vendor/bin/phpstan`
> then `phpstan`). External/CI-provided scanners with no local executable
> (gitleaks, semgrep) are not validated locally.

**`config-only` is not a pass.** It installs config/managed files and **never**
edits dependency manifests, so the installer may complete cleanly even when a
required tool is absent — but that absence is still a **configuration failure**,
not a green result. `doctor.sh` reports it (a **warning** under `config-only`,
exit 3 under `require-existing`/`bootstrap-tools`), and the authoritative local
pipeline ([`run-local-pipeline.sh`](workflow-execution-model.md)) and the CI
release gate **fail** — a required tool that is `unavailable`/`not-configured`
becomes a `required_tool_failures` count that `enforce-gates.sh` folds into a gate
failure (exit 1). It stays failing until the tool is installed (any mode) or
covered by an unexpired **control-waiver** (`.sentinel-shield/control-waivers.json`).
Installing config alone never makes a missing required tool pass.

- **`require-existing`** installs **no** dependencies. It validates the project
  **before** writing any files: a required-but-absent tool **fails preflight**
  (exit 1); a recommended-but-absent tool is a **warning** only.
- **`bootstrap-tools`** is **dry-run by default**; writing requires explicit
  `--apply`. It checks **version compatibility first** (never downgrades the app /
  framework / prod deps), installs **transactionally**, and **rolls back** the
  dependency files on any install/lockfile/test failure (see below).

## Preview the plan before doing anything (read-only)

`resolve-tool-plan.sh` and `bootstrap-profile-tools.sh --dry-run` inspect the
project (installed PHP/Composer, Node/npm, framework) and classify every tool
**without** mutating anything or hitting the network:

```sh
sh "$SENTINEL_SHIELD_PATH/scripts/resolve-tool-plan.sh" --profile laravel --target . --format text
sh "$SENTINEL_SHIELD_PATH/scripts/resolve-tool-plan.sh" --profile laravel --target . --format json   # machine-readable
sh "$SENTINEL_SHIELD_PATH/scripts/bootstrap-profile-tools.sh" --profile laravel --target .           # dry-run (default)
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
tree (`node_modules/`, `vendor/`) from the restored lockfile needs the package
manager present; if it is unavailable the manifests are restored but the install
tree may not be — reported as **rollback-incomplete**. Finish it by re-running the
install **for the lockfile that was restored** (frozen/immutable, so the restored
lockfile wins — never a re-resolve):

```sh
npm ci                                             # package-lock.json
pnpm install --frozen-lockfile                     # pnpm-lock.yaml
yarn install --immutable                           # yarn.lock
composer install --no-interaction --prefer-dist    # composer.lock
```

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
