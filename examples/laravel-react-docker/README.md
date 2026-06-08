# Example integration — Laravel + React + Docker

This directory shows **the output of the profile installer** for a Laravel + React + Docker
project — i.e. what you get from:

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile laravel-react-docker --apply
```

It is **not** a hand-maintained special case. The installed/managed files are generated
from Sentinel Shield templates + the `laravel-react-docker` profile manifest
(`profiles/combinations/laravel-react-docker.manifest.json`). See
[`docs/profile-driven-adoption.md`](../../docs/profile-driven-adoption.md).

## What the installer produces

| File | Mode | Notes |
| --- | --- | --- |
| `.github/workflows/sentinel-shield.yml` | **managed** | == `templates/workflows/sentinel-shield.yml`; updated by `sync-baseline.sh --apply --force`. Uses the **upstream** runner/adapters/audits. |
| `.sentinel-shield/profile.yaml` | project-owned | adoption mode (stamped from `--mode`) + gate policy |
| `.sentinel-shield/accepted-risks.example.json` | project-owned | copy to `accepted-risks.json` only when accepting a risk |
| `.semgrepignore` | project-owned | SAST scoping |
| `docs/security/*.md` | project-owned | governance templates to fill in |

## What stays project-specific (never installed/overwritten)

- `.sentinel-shield/accepted-risks.json` — your owner-approved, time-boxed risk decisions.
- `phpstan.neon` / `phpstan-baseline.neon` — your PHPStan config + debt baseline.
- Project code, Dockerfiles, and remediation docs.

## Migration note (v0.1.9 → v0.1.11)

Earlier versions of this example carried **local** test normalizers
(`scripts/sentinel/phpunit-to-tests-json.php`, `vitest-to-tests-json.mjs`) and relied on
project `composer run sentinel:quality` / `npm run sentinel:*` scripts. Those are
**superseded** by Sentinel Shield's upstream pieces and have been **removed** from this
example:

- PHPStan → `scripts/runners/laravel-phpstan.sh` (upstream runner; measured, never faked).
- PHPUnit → `scripts/adapters/phpunit-to-tests-json.php` (upstream adapter).
- Vitest → `scripts/adapters/vitest-to-tests-json.mjs` (upstream adapter).
- Multi-Dockerfile Hadolint → `scripts/run-hadolint.sh`; base-digest → `scripts/audit-docker-base-digest.sh`;
  GitHub Actions pins → `scripts/audit-github-actions-pins.sh`.

The workflow checks out Sentinel Shield at a pinned `SENTINEL_SHIELD_REF` and calls these
directly. `composer.json` / `package.json` here remain **illustrative** (showing dev deps /
optional project hooks); a thin consumer does not need local scanner scripts.

## Updating

```sh
sh scripts/sync-baseline.sh --target /path/to/project            # drift report
sh scripts/sync-baseline.sh --target /path/to/project --apply --force   # update managed files
```

`sync-baseline.sh` updates **managed** files (the workflow) and **never** overwrites
`accepted-risks.json`, `phpstan-baseline.neon`, or your project-owned config.
