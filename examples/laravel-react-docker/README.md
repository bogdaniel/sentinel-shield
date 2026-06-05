# Example integration — Laravel + React + Docker

This directory is a **reference integration package**: the files Sentinel Shield adds
to a real Laravel + React + Docker project, laid out exactly as they'd sit in that
project's repository. Copy these into your project and adapt (do not run them from
inside the Sentinel Shield repo).

## Layout

```txt
.sentinel-shield/profile.yaml                 # adoption mode + gate policy (report-only)
.github/workflows/sentinel-shield.yml         # CI pipeline (Option B: checks out Sentinel Shield)
composer.json                                 # illustrative: sentinel:* scripts + dev deps
package.json                                  # illustrative: sentinel:* scripts + dev deps
scripts/sentinel/phpunit-to-tests-json.php    # PHPUnit JUnit -> reports/raw/tests.json
docs/security/sentinel-shield-adoption.md     # how it works + migration plan
docs/security/release-evidence-template.md    # release readiness evidence template
.gitignore                                    # ignore generated reports, keep .gitkeep
reports/.gitkeep, reports/raw/.gitkeep        # output dirs
```

## Quick start

1. Copy this tree into your project (merge `composer.json` / `package.json` blocks
   into your existing files — do not overwrite them).
2. Set `PROJECT_NAME_HERE` in `.sentinel-shield/profile.yaml`.
3. In `.github/workflows/sentinel-shield.yml`, set `SS_REPO` and pin `SS_REF`, then
   pin all third-party action `uses:` to commit SHAs.
4. Read [`docs/security/sentinel-shield-adoption.md`](docs/security/sentinel-shield-adoption.md)
   — start in `report-only`, then follow the migration plan to `baseline` → `strict`
   → `regulated`.

## Source strategy

**Option B (external checkout)** is wired: the workflow checks Sentinel Shield out
into `tools/sentinel-shield` at a pinned ref and calls its scripts. Use **Option A
(vendoring)** only if CI cannot reach the Sentinel Shield repo — see the adoption doc.

> First integration is intentionally migration-safe (`report-only`): only secrets and
> expired exceptions block until you tighten the mode.
