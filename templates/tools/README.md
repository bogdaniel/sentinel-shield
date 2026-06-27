# Isolated tools (`tools/<tool>/`)

Some quality/security tools (**deptrac**, **rector**, **psalm**, **php-cs-fixer**)
pull dependency graphs that conflict with the application's own `composer.json`.
Installing them into the project `vendor/` can **force a framework downgrade**
(e.g. drag `laravel/framework` or a shared library back to an older version) just
to satisfy the tool. That is exactly the outcome we want to avoid.

The fix is **isolation**: each such tool gets its own minimal Composer project
under `tools/<tool>/`, with its own `vendor/`, resolved independently of the app.
The application's dependency graph is never touched, so no downgrade can happen.

## Layout convention

```
tools/
  psalm/
    composer.json      # committed — minimal, requires ONLY the tool
    composer.lock      # committed — pins the resolved versions
    vendor/            # git-ignored (see repo .gitignore: tools/*/vendor/)
      bin/psalm        # deterministic wrapper invocation path
```

Rules:

- `composer.json` requires **only the tool package**. Never add the application
  framework here — that would reintroduce the conflict isolation exists to prevent.
- **Commit** `composer.json` and `composer.lock` (reproducible, pinned installs).
- **Do not commit** `tools/*/vendor/` — it is git-ignored.
- Invoke the tool only through `tools/<tool>/vendor/bin/<bin>`.

## Scaffolding (via `scripts/lib/isolated-tools.sh`)

The library never runs Composer; it scaffolds files and reports paths/commands.

Scaffold is **DRY-RUN by default** (prints the would-be `composer.json` to stdout):

```sh
. scripts/lib/sentinel-shield-common.sh
. scripts/lib/isolated-tools.sh

# Preview only (writes nothing):
isolated_tool_scaffold psalm vendor/psalm "^5.0"

# Actually write tools/psalm/composer.json:
isolated_tool_scaffold psalm vendor/psalm "^5.0" --apply
# (add --force to overwrite an existing composer.json)
```

## Install / update commands

`composer.lock` is the source of truth for the pinned version. Run these from the
project root (the library prints the exact strings via the functions below):

```sh
# First install (creates vendor/ + composer.lock):
composer --working-dir=tools/psalm install
# Upgrade within the composer.json constraints (refreshes composer.lock):
composer --working-dir=tools/psalm update
```

Helper functions:

| Function | Returns |
| --- | --- |
| `isolated_tool_root <tool>` | `tools/<tool>` |
| `isolated_tool_composer_path <tool>` | `tools/<tool>/composer.json` |
| `isolated_tool_lock_path <tool>` | `tools/<tool>/composer.lock` |
| `isolated_tool_bin <tool> <bin>` | `tools/<tool>/vendor/bin/<bin>` |
| `isolated_tool_available <tool> <bin>` | exit 0 if the wrapper bin is executable |
| `isolated_tool_install_command <tool>` | `composer --working-dir=tools/<tool> install` |
| `isolated_tool_update_command <tool>` | `composer --working-dir=tools/<tool> update` |
| `isolated_tool_version <tool> <package>` | locked version from `composer.lock`, or `unknown` |

## Worked example: psalm, php-cs-fixer, deptrac, rector

```sh
isolated_tool_scaffold psalm         vendor/psalm                 "^5.0"  --apply
isolated_tool_scaffold php-cs-fixer  friendsofphp/php-cs-fixer    "^3.0"  --apply
isolated_tool_scaffold deptrac       deptrac/deptrac              "^2.0"  --apply
isolated_tool_scaffold rector        rector/rector                "^1.0"  --apply

# then, for each:
composer --working-dir=tools/psalm install
tools/psalm/vendor/bin/psalm --version
```
