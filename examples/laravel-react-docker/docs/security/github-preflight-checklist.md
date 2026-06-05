# GitHub Preflight Checklist

Complete this before running [`github-fixture-run.md`](github-fixture-run.md). It
verifies the external-checkout integration can actually resolve and run.

## Sentinel Shield availability

- [ ] **Sentinel Shield repo exists** and is pushed to GitHub
      (`YOUR_ORG/sentinel-shield`).
- [ ] **`v0.1.0` tag exists** on that repo
      (`git tag v0.1.0 && git push origin v0.1.0`), or you have a full commit SHA to
      pin instead.
- [ ] **The fixture workflow can access the Sentinel Shield repo.**
      - Public Sentinel Shield repo → no token needed.
      - **Private** Sentinel Shield repo → a read token/deploy key is configured and
        referenced in each `Checkout Sentinel Shield` step
        (`token: ${{ secrets.SENTINEL_SHIELD_RO_TOKEN }}`), stored as a repo secret.

## Fixture repo

- [ ] **Actions are enabled** (Settings → Actions → General → Allow).
- [ ] **`master` branch exists** (the workflow targets `push: branches: [master]`).
- [ ] Example files copied to the repo root; workflow at
      `.github/workflows/sentinel-shield.yml`.

## Workflow configuration

- [ ] **`SENTINEL_SHIELD_REPOSITORY`** is correct (`owner/repo`).
- [ ] **`SENTINEL_SHIELD_REF`** is correct — `v0.1.0` for the first run; a **full
      commit SHA** before production.
- [ ] **`SENTINEL_SHIELD_PATH`** is `tools/sentinel-shield` (unchanged).
- [ ] `project.name` set in `.sentinel-shield/profile.yaml` (not `PROJECT_NAME_HERE`).
- [ ] `gates.mode: report-only` (first run).

## Stack expectations (only if you want that stack to run)

- [ ] **`composer.lock` present** if you expect PHP tools to run a real install/audit.
      (Without an app, leave `composer.json` out → PHP job skips cleanly.)
- [ ] **`package-lock.json`** (or npm lockfile) present if you expect Node checks
      (`npm ci` needs a lockfile). Without it, leave `package.json` out → Node job
      skips cleanly.
- [ ] **`Dockerfile`** (or `docker-compose.yml`/`compose.yml`) present if you expect
      Docker checks (Hadolint/Trivy). Without it, the Docker job skips cleanly.
- [ ] **Node test JSON reporter configured** if you expect test gating: your test
      runner must emit a JSON report (e.g.
      `vitest run --reporter=json --outputFile=reports/raw/node-tests.json`) so
      `sentinel:test:node` can normalize it to `reports/raw/tests.json`. Without it,
      Node test failures stay `unavailable` (not faked).

## Understanding

- [ ] **Release evidence expectations understood:** `report-only`/`baseline` generate
      a rollup from the template; `regulated` requires a completed, project-provided
      readiness document before the gate (see
      [`release-evidence-template.md`](release-evidence-template.md)).
- [ ] You understand that **report-only** only blocks `secrets` and
      `expired_exceptions`; everything else is collected but does not fail the build.
- [ ] **Action SHA pinning** before production: all third-party `uses:` and the
      Sentinel Shield ref must be pinned to full commit SHAs.

When every required box is checked, proceed to the fixture run.
