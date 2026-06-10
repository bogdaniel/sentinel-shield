# Managed-File Inventory (v0.1.25)

The complete, per-profile table of **every file** `scripts/install-baseline.sh` and
`scripts/sync-baseline.sh` reconcile into a consuming project, the **mode** that governs each
file, and its **protected / never-touch** status.

Derived directly from the profile manifests
(`profiles/<name>/profile.manifest.json`, `profiles/combinations/<name>.manifest.json`) and the
two scripts. This is the source-of-truth companion to
[`install-sync-guide.md`](install-sync-guide.md),
[`install-sync-status.md`](install-sync-status.md), and
[`install-sync-consumer-safety.md`](install-sync-consumer-safety.md).

> Honesty note: this inventory describes what the scripts **actually do today**. Where a
> manifest declaration and the script's hard-coded protection list interact non-obviously, the
> "Effective behavior" column states the real outcome, not the nominal manifest mode.

## How modes map to behavior

The four manifest `mode` values and what each script does with them:

| Manifest `mode` | install-baseline.sh | sync-baseline.sh | Who owns the file afterward |
|---|---|---|---|
| `create-if-missing` | Writes only if the target is **absent**. If it exists: `skip (exists, project-owned)`. | Creates if missing. On drift: `project-local-preserved` — **never** overwritten, even with `--force`. | The consuming project |
| `overwrite-if-force` | Creates if absent. Overwrites an existing target **only with `--force`**; otherwise `skip (managed, exists; use --force to update)`. | Updates on drift **only with `--apply --force`**; otherwise `manual-review-needed`. | Sentinel Shield (managed) |
| `sync-managed-block` | Reserved. Treated **identically to `overwrite-if-force`** today (no in-file block merge is implemented). | Same as `overwrite-if-force`. | Sentinel Shield (managed) |
| `manual` | Never auto-written. Printed as `MANUAL (copy yourself if wanted)` — **unless** the path is also in `never_touch` (see below), in which case it is reported `PROTECTED` and **no copy hint is printed**. | `manual-review-needed`. | The operator (hand-copy) |

### The hard-protection list (overrides manifest mode)

Both scripts maintain a `PROTECT` list that is checked **before** the manifest mode. A target on
this list is **never written or overwritten by any flag combination**, and install reports it as
`PROTECTED (project-local, never written)`, sync as `project-local-preserved (protected)`.

`PROTECT` is seeded with two hard defaults and then extended with the manifest's `never_touch`:

```
hard defaults:  .sentinel-shield/accepted-risks.json   phpstan-baseline.neon
plus:           every path in the manifest's "never_touch" array
plus:           any target whose basename is "accepted-risks.json" (extra guard)
```

Consequence worth calling out: when a profile lists a path in **both** `files` (as `manual`) **and**
`never_touch` (e.g. `phpstan.neon` in the Laravel / Symfony / php-library / laravel-react-docker
profiles), the protection wins. The file is reported `PROTECTED` and the operator does **not** see
the usual `MANUAL (copy yourself if wanted)` hint for it. If you want that config, you must copy it
from `profiles/<stack>/` by hand. See [Per-profile notes](#per-profile-notes).

## Files written for every profile

These three entries appear in **every** manifest and are the minimal "thin consumer":

| Source (in Sentinel Shield) | Target (in consuming project) | Mode | Effective behavior |
|---|---|---|---|
| `templates/profile.yaml` | `.sentinel-shield/profile.yaml` | `create-if-missing` | Created once; `--mode` stamped into its `mode:` line on first write. Project-owned thereafter. |
| `templates/accepted-risks.example.json` | `.sentinel-shield/accepted-risks.example.json` | `create-if-missing` | Example only. The **real** `accepted-risks.json` is hard-protected and never created. |
| `templates/workflows/sentinel-shield.yml` | `.github/workflows/sentinel-shield.yml` | `overwrite-if-force` | **Managed.** Created on first install; updated by `--force` (install) or `--apply --force` (sync). |

## Per-profile inventory

Legend for **Effective behavior**: `create` = create-if-missing (project owns after);
`managed` = overwrite-if-force (Sentinel-owned, `--force` to update);
`manual` = hand-copy hint printed; `PROTECTED` = never written by any flag.

### Profile: `laravel`  (`profiles/laravel/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create |
| `phpstan.neon` | `profiles/laravel/phpstan.neon` | manual | **PROTECTED** (in `never_touch`; no manual hint shown — copy by hand if wanted) |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** (hard default + never_touch) |
| `phpstan-baseline.neon` | — | (never_touch) | **PROTECTED** (hard default + never_touch) |

### Profile: `react`  (`profiles/react/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `profiles/react/.semgrepignore` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |

### Profile: `node`  (`profiles/node/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |

### Profile: `docker`  (`profiles/docker/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `hadolint.yaml` | `profiles/docker/hadolint.yaml` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `docs/security/pinned-ci-references.md` | `templates/pinned-ci-references.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |

### Profile: `php-library`  (`profiles/php-library/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |
| `phpstan-baseline.neon` / `phpstan.neon` | — | (never_touch) | **PROTECTED** |

### Profile: `symfony`  (`profiles/symfony/profile.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `profiles/laravel/.semgrepignore` | create-if-missing | create |
| `phpstan.neon` | `profiles/symfony/phpstan.neon` | manual | **PROTECTED** (in `never_touch`; no manual hint shown) |
| `psalm.xml` | `profiles/symfony/psalm.xml` | manual | manual (copy hint printed) |
| `deptrac.yaml` | `profiles/symfony/deptrac.yaml` | manual | manual (copy hint printed) |
| `.php-cs-fixer.dist.php` | `profiles/symfony/php-cs-fixer.php` | manual | manual (copy hint printed) |
| `rector.php` | `profiles/symfony/rector.php` | manual | manual (copy hint printed) |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |
| `phpstan-baseline.neon` | — | (never_touch) | **PROTECTED** |

### Profile: `laravel-react-docker`  (default; `profiles/combinations/laravel-react-docker.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `templates/.semgrepignore` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `.github/workflows/sentinel-shield-pr-fast.yml` | `templates/workflows/sentinel-shield-pr-fast.yml` | manual | manual (copy hint printed) |
| `.github/workflows/sentinel-shield-main.yml` | `templates/workflows/sentinel-shield-main.yml` | manual | manual (copy hint printed) |
| `.github/workflows/sentinel-shield-scheduled.yml` | `templates/workflows/sentinel-shield-scheduled.yml` | manual | manual (copy hint printed) |
| `.github/workflows/sentinel-shield-dast.yml` | `templates/workflows/sentinel-shield-dast.yml` | manual | manual (copy hint printed) |
| `.github/workflows/sentinel-shield-ai-review.yml` | `templates/workflows/sentinel-shield-ai-review.yml` | manual | manual (copy hint printed) |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create |
| `docs/security/sentinel-shield-rollout-status.md` | `templates/sentinel-shield-rollout-status.md` | create-if-missing | create |
| `docs/security/sentinel-shield-triage.md` | `templates/security-triage-report.md` | create-if-missing | create |
| `docs/security/pinned-ci-references.md` | `templates/pinned-ci-references.md` | create-if-missing | create |
| `docs/security/third-party-install-script-review.md` | `templates/third-party-install-script-review.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |
| `phpstan-baseline.neon` / `phpstan.neon` | — | (never_touch) | **PROTECTED** |

### Profile: `node-react`  (`profiles/combinations/node-react.manifest.json`)

`never_touch`: `.sentinel-shield/accepted-risks.json`

| Target | Source | Manifest mode | Effective behavior |
|---|---|---|---|
| `.sentinel-shield/profile.yaml` | `templates/profile.yaml` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.example.json` | `templates/accepted-risks.example.json` | create-if-missing | create |
| `.semgrepignore` | `profiles/react/.semgrepignore` | create-if-missing | create |
| `.github/workflows/sentinel-shield.yml` | `templates/workflows/sentinel-shield.yml` | overwrite-if-force | managed |
| `docs/security/security-debt-register.md` | `templates/security-debt-register.md` | create-if-missing | create |
| `.sentinel-shield/accepted-risks.json` | — | (never_touch) | **PROTECTED** |

## Per-profile notes

- **`phpstan.neon` is never auto-installed for any PHP profile.** It is declared `manual` in
  the Laravel / Symfony manifests but is also in `never_touch`, so protection wins: install prints
  `PROTECTED` and **no copy hint**. To use the curated config, copy
  `profiles/<stack>/phpstan.neon` into the project root by hand.
- **`php-library`** intentionally ships **no** `phpstan.neon` entry (generic PHPStan), but still
  lists `phpstan.neon` in `never_touch` so an existing project file is never clobbered.
- **`node-react` vs `react`.** Both produce an equivalent thin consumer. The `react` profile
  declares stacks `react, node`; the `node-react` combination manifest is the explicit name.
- **Combination `laravel-react-docker`** is the only profile that ships the **extra split
  workflows** (`pr-fast`, `main`, `scheduled`, `dast`, `ai-review`) — all `manual`, so they are
  printed as copy hints and never auto-written. Only the single `sentinel-shield.yml` is managed.
- **`required_scripts` and `recommended_raw_reports`** in each manifest are **not files install
  writes** into the project. `required_scripts` live upstream in Sentinel Shield and the workflow
  calls them via `SENTINEL_SHIELD_PATH`; `recommended_raw_reports` are artifacts the pipeline
  produces at run time. Neither is part of this managed-file inventory.

## What is NEVER written into a consuming project (any profile, any flag)

1. `.sentinel-shield/accepted-risks.json` — hard default protection **and** in every `never_touch`.
2. `phpstan-baseline.neon` — hard default protection.
3. Any path in a profile's `never_touch` array (includes `phpstan.neon` for PHP profiles).
4. Any target whose basename is `accepted-risks.json` (extra guard).
5. Project source code — neither script ever touches files outside the manifest's declared targets.
