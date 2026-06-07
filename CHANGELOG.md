# Changelog

All notable changes to Sentinel Shield are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project is
pre-1.0; the first tag is `v0.1.0`.

## [Unreleased]

## [0.1.5] — third-party supply-chain suspicious-code scan

### Added

- **Separate third-party suspicious-code scan channel.** A dedicated Semgrep run over
  dependency/vendored code (`vendor/`, `node_modules/`, `public/vendor/`,
  `public/js/filament/`) using **only** `semgrep/third-party/*.yml` — distinct from
  the application SAST scan, written to a **separate** artifact
  (`reports/raw/third-party-semgrep.json`).
- New summary keys: `third_party_suspicious_code`, `third_party_install_script_risk`,
  `third_party_obfuscation`, `third_party_network_behavior` (schema + example +
  builder seed). New gate flags + resolver defaults (report-only/baseline: all false;
  strict: install_script_risk + network_behavior true; regulated: all true).
- New files: `semgrep/third-party/{suspicious-code,php-suspicious,js-suspicious}.yml`,
  `scripts/collectors/third-party-semgrep.sh`,
  `templates/raw/third-party-semgrep.example.json`,
  `docs/third-party-supply-chain-scan.md`. Profile gains a `supply_chain.third_party_sast`
  block (modes: disabled | report-only | scheduled | strict | regulated).
- Workflow steps (ci-security, ci-pipeline, example) run the third-party scan from
  `-w /tmp` with explicit dependency-dir targets (so the app `.semgrepignore` does
  not exclude them); they skip cleanly when no dependency dirs exist.
- Self-test `third-party` subcommand: missing raw → unavailable/0; fixture → category
  counts; report-only non-blocking; regulated blocks all four.

### Scope (explicit)

- This is **behavioral** supply-chain triage, **not** a replacement for Trivy /
  composer audit / npm audit (dependency CVEs), Syft (SBOM), or Gitleaks (secrets) —
  those remain the source of truth and are unchanged.
- Application SAST still excludes `vendor/`/`node_modules/` (v0.1.4 `.semgrepignore`);
  third-party findings stay in their own keys/artifact and never mix into app
  `*_vulnerabilities`. Non-blocking by default in v1; secrets are never suppressible.

## [0.1.4] — default Semgrep/SAST scoping for Laravel/React

### Added

- Default **Semgrep/SAST path exclusions** via project-local `.semgrepignore`
  templates: `profiles/laravel/.semgrepignore`, `profiles/react/.semgrepignore`, and
  `examples/laravel-react-docker/.semgrepignore`. They exclude vendored/generated/
  cache paths (`vendor/`, `node_modules/`, `storage/`, `bootstrap/cache/`,
  `public/js/filament/`, `public/vendor/`, `public/build/`, `dist/`, `build/`,
  `coverage/`, …) while keeping application source scanned.
- `docs/semgrep-scoping.md` explaining the scope and the scanner-specific behavior.
- Self-test check that the `.semgrepignore` templates exist and carry the key
  exclusions (incl. `public/js/filament/` in the example).

### Changed

- Semgrep workflow steps run with `-w /src` so a project-local `.semgrepignore` (at
  the repo root) is honored: `ci-security.yml`, `ci-pipeline.yml`, and the
  Laravel+React+Docker example workflow.
- Fixed a Semgrepignore-v2 anchoring deprecation in the JS rule excludes
  (`*/__tests__/*` → `**/__tests__/*`, `*/tests/*` → `**/tests/*`).

### Scope (explicit)

- These exclusions apply to **Semgrep / SAST only**. `composer audit`, `npm audit`,
  Trivy, Syft (SBOM), Gitleaks, and Hadolint are **not** narrowed — dependency
  scanning, SBOM, and secret scanning remain broad.

## [0.1.3] — Semgrep image fix, rule-noise tuning, accepted-risk suppression

### Fixed

- **Invalid Semgrep image reference.** `semgrep/semgrep:1` does not exist
  (`manifest unknown`), so Semgrep never ran (`unavailable`). Changed to
  `semgrep/semgrep:latest` in `ci-security.yml`, `ci-pipeline.yml`, and the
  Laravel+React+Docker example workflow (pin to a digest before production).

### Changed

- **Semgrep starter-rule scoping** to cut false positives on real projects:
  - `ss-laravel-app-debug-true` now excludes `*.example`/`.env.testing`/`.env.local`/
    `.env.ci` (APP_DEBUG=true is normal in non-production env templates).
  - `ss-php-insecure-random` → WARNING (was ERROR) and excludes
    `tests/`/`database/factories/`/`database/seeders/`/`fixtures/`/`examples/`.
  - `ss-js-insecure-random-security` → INFO (was WARNING) and excludes test/story
    paths (UI `Math.random()` is benign).
  - `ss-php-hardcoded-credentials` excludes test/factory/fixture paths (Gitleaks
    remains the authoritative secret scanner).
  - React XSS heuristics (`ss-react-dangerously-set-inner-html`,
    `ss-react-unsafe-dom-write`, `ss-react-javascript-url`) → WARNING (high), not
    ERROR (critical).
  - `ss-laravel-missing-authorization-review` moved out of the default set into
    opt-in `semgrep/php/laravel-review-prompts.yml` at INFO (it is a review prompt,
    not a confirmed bug).

### Added

- **Accepted-risk suppression** in `scripts/enforce-gates.sh` (`--accepted-risks`,
  default `.sentinel-shield/accepted-risks.json`). An APPROVED, unexpired,
  owner-bound record may mark a **suppressible** gate (`unsafe_docker`,
  `medium_vulnerabilities`) as `accepted-risk` — raw count preserved (not zeroed),
  reported, does not fail. `pending`/expired/invalid never suppress; `secrets`,
  `expired_exceptions`, `missing_release_evidence` are never suppressible.
- `schemas/accepted-risks.schema.json`, `templates/accepted-risks.example.json`,
  `docs/accepted-risk-suppression.md`, and the example
  `.sentinel-shield/accepted-risks.example.json`.
- Self-test `suppression` subcommand (in `all`): approved→pass(accepted-risk),
  pending/expired/missing→fail, secrets+approved→still fail.

## [0.1.2] — trivy-action transitive-pin fix

### Fixed

- **`aquasecurity/trivy-action` bumped to `v0.36.0`.** `v0.30.0` resolved as a tag
  but transitively pinned `aquasecurity/setup-trivy@v0.2.2`, a tag that no longer
  exists, so job setup still failed with "Unable to resolve action
  …setup-trivy@v0.2.2". `v0.36.0` pins `setup-trivy` by commit SHA, so it always
  resolves. Applied across `ci-security.yml`, `ci-pipeline.yml`, `ci-docker.yml`,
  and the example workflow. (Supersedes the partial `v0.1.1` trivy fix.)

## [0.1.1] — workflow fixes from first GitHub-runner validation

### Fixed

- **`aquasecurity/trivy-action` version pin** corrected from the non-existent
  `0.30.0` to `v0.30.0` (the action's tags are `v`-prefixed); later found
  insufficient (see 0.1.2). Affected
  `ci-security.yml`, `ci-pipeline.yml`, `ci-docker.yml`, and the Laravel+React+Docker
  example workflow. The bad pin failed job setup with
  "Unable to resolve action …@0.30.0".
- **`actions/setup-node` cache** (`cache: npm`) removed from the fixture-capable
  workflows (`ci-pipeline.yml`, example `sentinel-shield.yml`) because it fails when
  no lockfile is present (minimal/report-only repos without `package.json`).
  `ci-node.yml` (a Node-project-only workflow) keeps the cache.

Both were found by the first real GitHub Actions fixture run; the Sentinel Shield
scripts (resolver/builder/enforcer) were unaffected.

## [0.1.0]

### Added

- **Baseline & governance.** Top-level standards (`README.md`,
  `SECURITY-STANDARD.md`, `RELEASE-GATES.md`) and the `docs/` governance set:
  adoption guide, severity policy, exception policy, secure-coding standard,
  Docker and GitHub Actions security, dependency policy, architecture
  boundaries, and the project-readiness checklist. Defines the four adoption
  modes (`report-only`, `baseline`, `strict`, `regulated`) and the security
  doctrine.
- **Per-stack profiles.** Laravel and Symfony (PHPStan/Larastan, Psalm + taint,
  Pint/PHP-CS-Fixer, Deptrac, Rector), Node and React (ESLint flat configs,
  strict `tsconfig`, Knip, audit-ci, Vite security guide), and Docker (hardened
  Dockerfile/Compose references, Hadolint, Trivy).
- **Reusable CI workflows.** PHP, Node, Docker, security (SAST/secrets/deps/SBOM),
  CodeQL, ZAP (staging-only), and the release-gate aggregator, plus Dependabot
  and CodeQL config. Minimal permissions and `master`-branch examples.
- **Semgrep rules** for generic PHP, Laravel, Symfony, generic JS, Node, React,
  and Docker.
- **OPA/Rego policies** for Docker/Compose, GitHub Actions, Terraform, and
  production env config, plus the accepted-risk exception template.
- **Templates.** Pull request, security review, STRIDE-lite threat model,
  one-page ADR, and production-readiness report.
- **Local automation scripts** (POSIX `sh`): stack detection, PHP/Node quality
  runners, local security sweep, report generator, safe `install-baseline`
  (dry-run by default), and a non-destructive `sync-baseline` stub.
- **Gate resolver** (`scripts/resolve-gates.sh`): reads
  `.sentinel-shield/profile.yaml` and resolves the adoption mode into
  machine-readable `SENTINEL_SHIELD_FAIL_ON_*` flags
  (`sentinel-shield-gates.{env,json,md}`). Prefers `yq` v4, with a
  canonical-format awk/sed fallback. Shared shell library in
  `scripts/lib/sentinel-shield-common.sh`; canonical `templates/profile.yaml`;
  documented in `docs/gate-resolution.md`.
- **Gate enforcer** (`scripts/enforce-gates.sh`): consumes the resolved flags
  plus a normalized `reports/security-summary.json` and decides pass/fail
  (exit `0`/`1`/`2`). The gates `.env` is validated line-by-line and never
  blind-sourced; JSON is parsed only with `jq`; a missing required summary key
  is an error, never a silent zero. Ships the `security-summary.json` contract:
  JSON Schema (`schemas/security-summary.schema.json`), canonical example, and
  `docs/security-summary-schema.md`.
- **Repository hygiene.** `CHANGELOG.md`, `LICENSE`, `CONTRIBUTING.md`, and a
  `Makefile` wrapper over the scripts.

### Security

- Audit-hardened the baseline: fixed malformed XML (double-hyphen in comments),
  removed fabricated/invalid GitHub Action SHA pins (converted to version tags
  with a pin-to-SHA note), fixed `set -e` foot-guns in shell, corrected a Node
  quality-runner binary bug, and made report generation portable.
- Enforcer rejects suspicious `.env` lines (command substitution, backticks,
  shell metacharacters) instead of sourcing them.

### Notes

- Sentinel Shield does **not** yet ship per-scanner adapters that emit
  `security-summary.json`; producing it is currently the consuming project's
  responsibility. The enforcement layer defines and enforces the target contract.
- GitHub Action references use version tags for readability; pin them to commit
  SHAs in sensitive workflows before production use
  (`docs/github-actions-security.md`).

[Unreleased]: https://example.com/sentinel-shield/compare/HEAD
