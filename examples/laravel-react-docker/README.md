# Example integration — Laravel + React + Docker

This directory is a **reference integration package**: the files Sentinel Shield adds
to a real Laravel + React + Docker project, laid out exactly as they'd sit in that
project's repository. Copy these into your project and adapt (do not run them from
inside the Sentinel Shield repo).

## Layout

```txt
.sentinel-shield/profile.yaml                  # adoption mode + gate policy (report-only)
.github/workflows/sentinel-shield.yml          # CI pipeline (external Sentinel Shield checkout)
composer.json                                  # illustrative: sentinel:* scripts + dev deps
package.json                                   # illustrative: sentinel:* scripts + dev deps
scripts/sentinel/phpunit-to-tests-json.php     # PHPUnit JUnit -> reports/raw/tests.json
scripts/sentinel/vitest-to-tests-json.mjs      # Vitest/Jest JSON -> reports/raw/tests.json
docs/security/sentinel-shield-adoption.md      # how it works + migration plan
docs/security/github-fixture-run.md            # run it on a GitHub runner (fixture)
docs/security/github-preflight-checklist.md    # checklist before the first run
docs/security/release-evidence-template.md     # release readiness evidence template
.gitignore                                     # ignore generated reports, keep .gitkeep
reports/.gitkeep, reports/raw/.gitkeep         # output dirs
```

## Quick start

1. Copy this tree into your project (merge `composer.json` / `package.json` blocks
   into your existing files — do not overwrite them).
2. Set `PROJECT_NAME_HERE` in `.sentinel-shield/profile.yaml`.
3. In `.github/workflows/sentinel-shield.yml`, set `SENTINEL_SHIELD_REPOSITORY` and
   pin `SENTINEL_SHIELD_REF` (tag for first adoption; full commit SHA before
   production), then pin all third-party action `uses:` to commit SHAs.
4. Read [`docs/security/sentinel-shield-adoption.md`](docs/security/sentinel-shield-adoption.md)
   — start in `report-only`, then follow the migration plan to `baseline` → `strict`
   → `regulated`.

## Run it on GitHub (fixture)

To validate the plumbing on a real runner before touching a real app, follow
[`docs/security/github-fixture-run.md`](docs/security/github-fixture-run.md) (after
[`docs/security/github-preflight-checklist.md`](docs/security/github-preflight-checklist.md)).

**Minimal fixture mode** needs no app: the workflow skips the PHP/Node/Docker jobs
(with warnings) when `composer.json`/`package.json`/a Dockerfile are absent, while
`security-scan` still runs. The builder marks skipped tools `unavailable` — nothing
is faked — and `report-only` passes unless a real secret is found.

## Source strategy

**External checkout** is wired: the workflow checks Sentinel Shield out into
`tools/sentinel-shield` (`SENTINEL_SHIELD_PATH`) at a pinned ref and calls its
scripts. Vendoring is documented as a fallback only if CI cannot reach the Sentinel
Shield repo — see the adoption doc.

> First integration is intentionally migration-safe (`report-only`): only secrets and
> expired exceptions block until you tighten the mode.
