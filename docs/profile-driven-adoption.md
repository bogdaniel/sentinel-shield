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
`.github/workflows/*` … as needed" — the **workflow was manual**, `.semgrepignore` and the
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

## Validating main-gate scanners before enabling the main workflow (v0.1.17)

`sentinel-shield-main.yml` is `workflow_dispatch`/push only and cannot be dispatched from a feature
branch until it exists on the default branch. **Do not merge it unvalidated.** Instead validate its
scanners branch-safely first with the harness — no dispatch, no merge required:

```sh
# from a Sentinel Shield checkout (e.g. tools/sentinel-shield), targeting your project root:
sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all
sh scripts/build-security-summary.sh --raw-dir reports/raw --output reports/security-summary.json \
    --project-name "$PWD" --project-type laravel
sh scripts/resolve-gates.sh --profile .sentinel-shield/profile.yaml --format all
sh scripts/enforce-gates.sh --summary reports/security-summary.json --gates-env reports/sentinel-shield-gates.env
```

Tools the runner cannot run are recorded `unavailable` (never faked) in
`reports/raw/main-gate-validation-tools.json`. Only after a green branch run with real reports
should `sentinel-shield-main.yml` be merged to the default branch. Full rationale:
[`main-gate-validation-strategy.md`](main-gate-validation-strategy.md).

## Pinning scanner images by digest (v0.1.21)

Templates ship validated scanner images as **readable tags**, overridable by digest. In production,
pin by digest — override the env var with the `<image>@sha256:…` form (keep the tag as a comment):

```yaml
env:
  SENTINEL_SHIELD_SEMGREP_IMAGE: semgrep/semgrep@sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b   # 1.165.0
  SENTINEL_SHIELD_GRYPE_IMAGE:   anchore/grype@sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28      # v0.114.0
  SENTINEL_SHIELD_DOCKLE_IMAGE:  goodwithtech/dockle@sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9 # v0.4.15
```

Resolve/verify/rollback procedure: [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).
OWASP Dependency-Check is **not** digest-pinned (attempted, not live-validated) — run it via the
cached nightly job ([`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)),
never PR-fast.

## Maturity (v0.1.13)

The install/sync engine and the laravel-react-docker profile are **proven** (self-tested +
fixture round-trip). Scanner integrations carry maturity labels — see
[`production-readiness-audit.md`](production-readiness-audit.md). Adopt in `report-only` first,
pin tool refs ([`pinned-tool-references.md`](pinned-tool-references.md)), then tighten.
