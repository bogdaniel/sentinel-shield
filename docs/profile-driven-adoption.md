# Profile-Driven Adoption (v0.1.11)

Adopt Sentinel Shield in a consuming project with **one install command** instead of
hand-copying workflow logic from examples. A profile manifest declares which files to
install; `install-baseline.sh` writes them safely; `sync-baseline.sh` updates them on a
newer Sentinel Shield release **without destroying project-local decisions**.

> **Scope honesty:** v0.1.11 ships profiles for **Laravel, React, Node, Docker** and the
> **laravel-react-docker** combination. Other stacks (Symfony, Go, Python, …) are **not**
> covered by manifests yet — project onboarding is **not** fully solved, only these.

## Quick start

```sh
# from a Sentinel Shield checkout (tools/sentinel-shield), targeting your project:
sh scripts/install-baseline.sh --target /path/to/project                 # dry-run (default)
sh scripts/install-baseline.sh --target /path/to/project --apply         # write files
sh scripts/install-baseline.sh --target /path/to/project --apply --mode report-only
# later, to pull template updates from a newer Sentinel Shield:
sh scripts/sync-baseline.sh    --target /path/to/project                  # drift report
sh scripts/sync-baseline.sh    --target /path/to/project --apply --force  # update managed files
```

Defaults: `--profile laravel-react-docker`, `--mode report-only`.

## What gets installed (laravel-react-docker)

| Target | Mode | Owner after install |
| --- | --- | --- |
| `.sentinel-shield/profile.yaml` | create-if-missing | **project** (mode stamped from `--mode`) |
| `.sentinel-shield/accepted-risks.example.json` | create-if-missing | **project** |
| `.semgrepignore` | create-if-missing | **project** |
| `docs/security/*.md` (debt register, rollout-status, triage, pinned-ci, third-party) | create-if-missing | **project** |
| `.github/workflows/sentinel-shield.yml` | overwrite-if-force | **managed** (synced) |

**Never created or overwritten** (project-local risk decisions): `.sentinel-shield/accepted-risks.json`,
`phpstan-baseline.neon`, `phpstan.neon`, and any `never_touch` path — plus all project code.

## Profile manifest format

`profiles/<name>/profile.manifest.json` (or `profiles/combinations/<name>.manifest.json`),
schema: [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json).

```json
{
  "profile": "laravel-react-docker",
  "files":     [ { "source": "templates/profile.yaml", "target": ".sentinel-shield/profile.yaml", "mode": "create-if-missing" } ],
  "workflows": [ { "source": "templates/workflows/sentinel-shield.yml", "target": ".github/workflows/sentinel-shield.yml", "mode": "overwrite-if-force" } ],
  "docs":      [ ... ],
  "never_touch": [ ".sentinel-shield/accepted-risks.json", "phpstan-baseline.neon" ],
  "required_scripts": [ "scripts/runners/laravel-phpstan.sh", ... ],
  "recommended_raw_reports": [ "hadolint.json", "docker-base-digest.json", ... ]
}
```

**File modes:**
- `create-if-missing` — write only if absent; the project owns it afterward (sync never clobbers).
- `overwrite-if-force` — **managed**; created if absent, overwritten only with `--force` (so sync can ship template updates).
- `sync-managed-block` — reserved (managed marker-block update in place); treated like manual today.
- `manual` — never auto-written; printed for the maintainer to handle.

`required_scripts` and `recommended_raw_reports` are **informational** — the scripts live in
Sentinel Shield (called via `SENTINEL_SHIELD_PATH`), not copied into the project.

## Current state vs intended model

**Before v0.1.11 (audit):** `install-baseline.sh` bulk-copied `scripts/`, `docs/`, `profiles/`,
`policies/`, `semgrep/`, `templates/` into `.sentinel-shield/` and told you to "copy
`github/workflows/*` … as needed" — the **workflow was manual**, `.semgrepignore` and the
security doc set were example-only, there was no profile selection, no mode selection, and
`sync` was a non-applying drift report. Drift between Sentinel Shield and consumers was
likely (no managed/project-local distinction).

**Intended model (now):** Sentinel Shield owns reusable profile logic (manifests, the
workflow template, runners/adapters/audits, doc templates). Consumers **install/sync
profiles** rather than copying scanner workflow by hand. Project-specific files stay local:
profile overrides, `accepted-risks.json`, `phpstan-baseline.neon`, remediation docs, and
code fixes. The workflow checks out Sentinel Shield at a pinned ref and calls its scripts.

## Ownership split

| Sentinel Shield owns (synced) | Consuming project owns (never overwritten) |
| --- | --- |
| `templates/workflows/sentinel-shield.yml` (managed) | `.sentinel-shield/profile.yaml` (after create) |
| profile manifests, runners, adapters, audits, collectors | `.sentinel-shield/accepted-risks.json` |
| doc/governance **templates** | `phpstan.neon` / `phpstan-baseline.neon` |
| `.semgrepignore` baseline (create-if-missing) | project code + remediation docs |

## Safety guarantees
- Dry-run by default; nothing is written without `--apply`.
- Managed files are overwritten only with `--force`.
- `accepted-risks.json` and `phpstan-baseline.neon` are **hard-protected** — never created
  or overwritten by install or sync, regardless of flags.
- `sync` reports `created / updated / up-to-date / manual-review-needed / project-local-preserved`.
