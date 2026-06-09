# Changelog

All notable changes to Sentinel Shield are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). This project is
pre-1.0; the first tag is `v0.1.0`.

## [Unreleased]

## [0.1.19] — main-gate execution hardening

### Added
- **`scripts/verify-semgrep-image.sh`** + `tests/fixtures/semgrep/php-modern/` — verify the
  configured `SENTINEL_SHIELD_SEMGREP_IMAGE` parses modern PHP 8.1+ syntax. **`semgrep/semgrep:1.165.0`
  fixture-verified: 0 parser errors** (1.90.0 produced 118 on the pilot). Missing tool → unavailable
  (exit 0); parser errors → exit 1; clean → exit 0. **Fixture verification ≠ live consumer validation.**
- **`docs/main-gate-execution-hardening-v0.1.19.md`** + evidence-registry + tool-installation env-var
  tables.
- **Self-test `main-gate-exec`** (fake binaries, no network): grype sbom missing→unavailable / sbom+
  fake→report; dep-check disabled→unavailable, enabled-no-binary→unavailable; dockle no-image→
  unavailable, image+fake→report; semgrep-verify no-tool→unavailable / parser-error→exit 1 / clean→
  exit 0; main-gate tools JSON v1.1 fields.

### Changed
- **Grype** (`audits/grype.sh`): SBOM-first (default) / fs modes; local binary **or** container;
  `SENTINEL_SHIELD_GRYPE_MODE/IMAGE/SBOM_PATH`. Harness exports the Syft SBOM path so SBOM-first works.
- **OWASP Dependency-Check** (`audits/dependency-check.sh`): **disabled by default**; `enabled` mode;
  cache dir; container image; nightly-recommended. Documented slow + duplicates OSV/Trivy/Grype.
- **Dockle** (`audits/dockle.sh`): built-image-gated (`SENTINEL_SHIELD_IMAGE`), local or container
  (`SENTINEL_SHIELD_DOCKLE_IMAGE`, `_EXIT_CODE`); never builds/scans-arbitrary.
- **`run-main-gate-validation.sh`**: tools JSON **v1.1** — adds `duration_seconds`, `executor`,
  `valid_json` (additive; v1.0 consumers unaffected). main/scheduled templates wire the new env vars.
- All honest: missing binary/precondition → unavailable, no file, never fake-clean.

### Honest status
No new scanners. No gates weakened. No findings suppressed. **Grype/Dependency-Check/Dockle are
NOT live-validated** (no consumer artifact). Semgrep 1.165.0 is **fixture-verified, not
consumer-verified** — the 118 errors were on the consumer's real code, not the fixture.


## [0.1.18] — main-gate live-validation hardening

> v0.1.17 (already tagged) is the *branch-safe main-gate harness*. This release (v0.1.18) is the
> evidence-based **promotion + Semgrep strategy** pass that builds on it. Earlier tags unchanged.

### Added
- **`docs/main-gate-live-evidence.md`** — canonical live-validation evidence registry (tool,
  consumer, run ID, artifact, mapping, maturity, limitations, next target). Source of truth for
  promotions; other maturity docs defer to it.
- **`docs/remediation/semgrep-parser-errors.md`** — findings-vs-parser-errors triage, when to
  upgrade the Semgrep image, why NOT to `.semgrepignore` application code.
- **`docs/tooling/main-gate-tool-installation.md`** — how to run Grype / OWASP Dependency-Check /
  Dockle via action/container (main gate / nightly, never PR-fast), with honest-unavailable contract.
- **Self-test `main-gate-evidence`** (wired into `all`): Semgrep image variable present in
  templates; no `--config=auto` for app scan; main-gate template has no DAST/Nuclei/AI; evidence
  registry contains CodeQL/OSV/Trivy/Syft.

### Changed
- **Promoted with cited evidence (zenchron run 27214865086): CodeQL, OSV-Scanner, Trivy-fs, Syft
  SBOM → live-validated.** Updated product-status, production-readiness-audit, enterprise-scanner-matrix,
  pilot-consumers, raw-report-contract, roadmap. Grype/Dep-Check/Dockle/Deptrac/IaC stay
  experimental/not-configured (no evidence).
- **Documented baseline run 27214863297 FAIL as correct gate behavior** (real npm critical:
  shell-quote via concurrently). NOT suppressed/accepted/downgraded — consuming-project fix.
- **Semgrep image strategy**: default `semgrep/semgrep:1.90.0` → **`1.165.0`** (PHP parser fix),
  overridable via **`SENTINEL_SHIELD_SEMGREP_IMAGE`** across pr-fast/combined templates +
  ci-security/ci-pipeline; never `:latest` silently. Pin by digest before prod.
- Deptrac/IaC status clarified (not-validated-unless-configured; skip honestly).

### Honest status
No new scanners. No gates weakened. No findings suppressed. npm critical NOT fixed here (consumer's
job). Grype/Dependency-Check/Dockle NOT live-validated. Semgrep 1.165.0 default is documented but
**not live-tested in this pass** (no Docker/Semgrep locally).


## [0.1.17] — main-gate validation harness

Solves the dispatchability blocker that kept main-gate scanners `experimental`. **No new scanners.
No weakened gates. No faked reports. No live-validation claims without artifact evidence.**

### Added
- **`scripts/run-main-gate-validation.sh`** — branch-safe main-gate validation harness (POSIX sh).
  Runs the deterministic main-gate wrappers/audits (codeql-export, osv-scanner, trivy-fs, syft,
  grype, dependency-check, deptrac, architecture-tests, checkov, conftest, terrascan, dockle) from
  **any branch/PR** — no `workflow_dispatch`, no merge-first. Produces the same `reports/raw/*`
  contracts the summary builder consumes. `--target`, `--output-dir`, `--profile`, `--all`,
  repeatable `--tool`. Missing binary / unmet precondition → `unavailable`, **no file written**
  (never fake-clean); an unexpected wrapper crash → `fail` (exit 1). **No DAST/Nuclei/AI.**
- **`reports/raw/main-gate-validation-tools.json`** — per-tool `{status,reason,report}` descriptor
  (status ∈ `pass|fail|unavailable|skipped`), version 1.0.
- **`docs/main-gate-validation-strategy.md`** — the dispatchability analysis (why `workflow_dispatch`
  needs the workflow on the default branch first), Options A–E compared, and the recommended
  strategy (D for first validation, A for steady-state).
- **Self-test suite `main-gate-harness`** (wired into `all`): unknown-tool/no-selection → exit 2;
  DAST/AI tool names rejected; `--tool` selection vs `skipped`; `--all` → 12 tools; unavailable
  writes no fake report; fake-binary proves the `pass` branch; builder consumes harness output.

### Changed
- `templates/workflows/sentinel-shield-main.yml`, `docs/workflow-template-inventory.md`,
  `docs/profile-driven-adoption.md`: document validating main-gate scanners **branch-safely first**
  with the harness, then merge the workflow (never merge unvalidated).
- Docs updated for the harness + promotion path: product-status, product-readiness-checklist,
  roadmap (Phase 3 now in-progress), raw-report-contract, enterprise-scanner-matrix,
  production-readiness-audit, docs/README.

### Honest status (unchanged)
The harness makes branch-safe validation **possible**; it does **not** make any main-gate scanner
`live-validated`. No main-gate tool has a cited consumer run yet — promotion still requires a real
report + reviewed severity (roadmap Phase 3). Engine + PR-fast gate remain `proven`; main-gate
scanners remain `experimental`/`template-only`. DAST stays `manual`; AI stays `non-gating`.


## [0.1.16] — product completion & stabilization

A documentation + stabilization release. **No new scanners. No weakened gates. No new maturity
claims without cited evidence.** Goal: round Sentinel Shield up as a reusable product —
understandable, installable, maintainable, ready for repeated adoption.

### Added
- **Product docs:** `docs/product-status.md` (canonical maturity — single source of truth),
  `docs/product-boundaries.md` (product owns vs project owns + the upstream/keep-local rule),
  `docs/pilot-consumers.md` (zenchron-tools recentered as pilot **evidence**, not a product target;
  what it did and did not prove), `docs/roadmap.md` (maturity-phased, not tool-accumulation),
  `docs/product-readiness-checklist.md` (done/partial/not-started/blocked, evidence-gated).
- **Install/sync audit:** `docs/install-sync-status.md` — coverage for laravel-react-docker,
  node-react, docker-only, php-library; gaps + manual steps + safe next improvements.
- **Workflow inventory:** `docs/workflow-template-inventory.md` — all six templates with gate
  category, inputs/secrets, default-enabled, PR-safety, maturity, limitations, pinning.
- **Documentation index:** `docs/README.md` — categorized entry point for new teams.
- **`profiles/php-library/profile.manifest.json`** — framework-free PHP install profile (generic
  PHPStan, composer audit, PHPUnit adapter; no Larastan/Docker assumptions). Closes the
  "no php-library manifest" gap. Validated: valid JSON + clean dry-run on the php-library fixture.

### Changed
- **Maturity canonicalized:** `enterprise-scanner-matrix.md`, `production-readiness-audit.md`,
  `tooling/scanner-enablement.md`, and `README.md` now defer to `product-status.md` as the single
  maturity source (A–F → label mapping documented). No tool carries conflicting labels.
- **Release process** (`sentinel-shield-release-process.md`) made explicit: shell syntax, self-test
  all (incl. workflow-sanity, fixture install/sync, raw-report-contract), JSON/YAML validity,
  adapter syntax, changelog update, tag immutability. No unstable scanner run in the engine's gate.

### Honest status (unchanged)
Engine (resolver/enforcer/builder/install/sync/self-test) and the PR-fast gate remain `proven`
(zenchron run 27170148123). **Main-gate scanners remain `experimental`/`template-only` — not
live-validated; `sentinel-shield-main.yml` is still not dispatchable from a feature branch
(roadmap Phase 3).** DAST stays `manual`+fail-closed; AI review stays `non-gating`. Severity
parsing for OSV/CodeQL remains coarse. Sentinel Shield is **not** complete.


## [0.1.15] — live-validation hardening

### Changed
- **Semgrep default hardened**: the PR-fast workflow template now runs **curated
  `semgrep/app` rules** (honoring the project `.semgrepignore`), explicitly **never
  `--config=auto`**. Validated on zenchron-tools (run 27170148123): curated rules produced
  **0 critical / 0 high** and 118 scan errors vs `--config=auto`'s 7/16 + 341 errors.
- **Maturity promotions (evidence-based, cited)** in production-readiness-audit.md from the
  zenchron-tools pilot (run 27170148123): Pint/PHP-CS-Fixer (php-style → live-validated,
  style_violations=88), TypeScript --noEmit (live-validated, type_errors=0), dependency-policy
  lockfile detector (live-validated, dependency_policy_violations=0). Core PR-fast tools remain
  proven; baseline gate PASS with no regression on v0.1.14.
- pr-fast template also runs the dependency-policy audit by default.
- Docs updated: production-readiness-audit, tooling/scanner-enablement (curated Semgrep
  guidance), pinned-tool-references (validated action SHAs), README.

### Not promoted (honest)
Psalm/Deptrac/ESLint were `not-configured` on the pilot (runner correctly reported unavailable —
no fake). CodeQL/OSV/Trivy/Syft/Grype/Dependency-Check/IaC remain template/fixture-only
(main-validation not yet dispatchable). DAST/Nuclei/AI stay manual/non-gating. No new scanners;
no gates weakened.


## [0.1.14] — enterprise feature completion

### Added
- **dependency-policy emitter** (`scripts/audits/dependency-policy.sh` + collector) — first
  concrete `dependency_policy_violations` source: flags ecosystem manifests missing a lockfile
  (composer/npm/python/go/ruby/rust). License/version policy deferred (documented future).
- **9 runners**: psalm, php-style (Pint/PHP-CS-Fixer), eslint, typescript, actionlint, zizmor,
  deptrac, codeql-export (SARIF→raw), architecture-tests. **3 audits**: syft, trivy-fs,
  trivy-image. **1 collector**: architecture-tests. All honest: missing binary → unavailable,
  never fake-clean.
- Policy docs: iac-security-policy, static-analysis-policy, style-policy, architecture-policy;
  dependency-policy emitter section. Remediation: dependency-advisory-triage, iac-finding-triage,
  phpstan-psalm-triage, deptrac-architecture-triage. Templates: dependency-risk-review,
  iac-exception-request. Gap audit: `docs/feature-completion-v0.1.14.md`.
- Self-test `feature-completion` (dependency-policy detector, arch-tests collector, runner/audit
  presence, IaC clean-skip, missing→unavailable, invalid→exit 2). `architecture-tests` +
  `dependency-policy` wired into the summary TOOL_TABLE.

### Notes
This is a FEATURE-COMPLETION release, NOT hardening/live-validation. Scanner binaries are
external; most integrations remain supported/experimental (fixture-validated, not live). DAST
stays manual+allowlisted+fail-closed; AI review stays assistive+non-gating. No gates weakened.


## [0.1.13] — production readiness hardening

### Added
- **Production readiness audit** (`docs/production-readiness-audit.md`) — per-tool A–F status
  (proven-live / fixture-only / collector-only / template-only / documented-only / not-ready).
- **Fixture consumer projects** (`tests/fixtures/projects/{laravel-react-docker,node-react,docker-only,php-library}`)
  — minimal, offline.
- **Self-test suites** `fixtures` (detect-stack + install/sync round-trip + profile resolution +
  enforcement) and `workflow-sanity` (no pull_request_target trigger, permissions present, DAST
  allowlist required, AI review non-gating). Both BLOCKING in ci-self-test.yml.
- Docs: `workflow-template-validation.md`, `pinned-tool-references.md` (real upstream SHAs
  resolved 2026-06-09), `raw-report-contract.md`, `sentinel-shield-release-process.md`,
  `ci-runtime-budget.md`.
- Maturity labels (proven/supported/experimental/template-only/manual/non-gating) across README,
  enterprise-scanner-matrix, profile-driven-adoption.

### Changed
- `ci-self-test.yml`: actions **SHA-pinned** (checkout v4.2.2, upload-artifact v4.6.2) + new
  BLOCKING `full-self-test` job (sh -n all scripts, self-test all, workflow-sanity, fixtures).
- `scripts/self-test.sh`: +`fixtures`, +`workflow-sanity`; all suites wired into `all`.

### v0.1.12 correction (honesty)
v0.1.12 expanded scanner BREADTH but the integrations are **not equally mature**. The new
collectors are deterministic-fixture-validated, **not live-validated**; severity parsing for
OSV/CodeQL is coarse; DAST/Nuclei are manual+allowlisted; AI review is non-gating. Sentinel
Shield is production-ready as a **release-gate engine**, not as a turnkey "all scanners proven"
product. See production-readiness-audit.md.


## [0.1.12] — enterprise scanner expansion

### Added
- **Enterprise scanner matrix** (`docs/enterprise-scanner-matrix.md`) classifying every tool by
  gate category (PR fast / main / nightly / manual) with honest before/after status.
- **16 new collectors** (normalize tool output → summary keys; self-tested): codeql, php-syntax,
  php-style, osv-scanner, grype, dependency-check, scorecard, trufflehog, checkov, conftest,
  terrascan, dockle, zap, nuclei, ai-security-review, kuzushi.
- **8 new summary keys**: style_violations, php_syntax_errors, dependency_policy_violations,
  iac_violations, dast_findings, container_image_violations, repository_health_warnings,
  ai_review_findings (+ gate flags, mode defaults, enforcement).
- **DAST safety runners** (`scripts/runners/{dast-guard,zap-baseline,zap-full,nuclei}.sh`):
  no target → skip; host not allowlisted → **fail closed**; never scans arbitrary targets.
- **Audit wrappers** (`scripts/audits/*`) + `scripts/runners/php-syntax.sh` — run tool if present,
  else report unavailable (never fake clean).
- **Workflow templates**: sentinel-shield-{pr-fast,main,scheduled,dast,ai-review}.yml.
- **Report templates**: ai-security-review-report, kuzushi-investigation-report,
  dast-scan-approval, nuclei-target-allowlist, scheduled-scan-report, tool-exception-request.
- **Docs**: dast-policy, ai-review-policy, scheduled-scans, dependency-policy,
  tooling/scanner-enablement.
- **Self-test suite** `scanner-matrix` (collectors, resolver/enforcer gates by mode, DAST
  fail-closed, AI non-gating).

### Changed
- `resolve-gates.sh`: 8 new fail_on flags with conservative mode defaults (baseline blocks
  php_syntax + dependency_policy; strict adds style/iac/container; regulated adds
  dast/repo-health; **AI review never gating by default**).
- `enforce-gates.sh`: evaluates the new count gates (optional, null-safe; finding-scoped
  accepted-risk still ONLY for unsafe_docker; secrets never suppressible).
- `build-security-summary.sh`, schema, example, `ss_emit_collector`: carry the 8 new keys.
- profile manifest + `templates/profile.yaml`: new gates + manual workflow templates.

### Notes
- Collectors normalize/gate; scanner binaries run via workflow templates / audit wrappers
  (not bundled). DAST/Nuclei are manual + allowlisted; AI review is assistive + non-gating.
  Severity parsing (OSV/CodeQL) is best-effort. See enterprise-scanner-matrix.md.


## [0.1.11] — profile-driven adoption & sync

### Added

- **Profile manifests** (`profiles/<name>/profile.manifest.json`,
  `profiles/combinations/laravel-react-docker.manifest.json`) + schema
  (`profiles/profile.manifest.schema.json`). A manifest declares `files`/`workflows`/`docs`
  entries (`source`, `target`, `mode`), `never_touch`, `required_scripts`,
  `recommended_raw_reports`. File modes: `create-if-missing`, `overwrite-if-force`,
  `sync-managed-block` (reserved), `manual`.
- **Thin-consumer workflow template** `templates/workflows/sentinel-shield.yml` — uses the
  upstream runner/adapters/audits (`runners/laravel-phpstan.sh`,
  `adapters/{phpunit,vitest}-to-tests-json.*`, `run-hadolint.sh`,
  `audit-{github-actions-pins,docker-base-digest}.sh`, `build-security-summary.sh`,
  `enforce-gates.sh`); minimal permissions; uploads raw reports + downloads them in
  release-gate for finding-scoped accepted-risk matching; never fakes reports.
- `templates/.semgrepignore`, `docs/profile-driven-adoption.md`.
- Self-test `install-sync` suite (temp dirs, no network): dry-run writes nothing; `--apply`
  creates expected files + stamps profile mode; never creates/overwrites
  `accepted-risks.json`; `--force` overwrites managed files only (not project-owned);
  sync reports drift, updates managed files, preserves project-local; detect-stack
  identifies Laravel/React/Docker.

### Changed

- **`install-baseline.sh`** is now profile-manifest-driven: `--profile` (default
  `laravel-react-docker`), `--mode` (default `report-only`, stamped into `profile.yaml`),
  dry-run by default, `--apply`, `--force` (managed files only), `--target`. Installs
  profile.yaml + accepted-risks.example + workflow + .semgrepignore + security doc
  templates. **Never** creates/overwrites `accepted-risks.json` / `phpstan-baseline.neon`.
- **`sync-baseline.sh`** now updates a consumer from a newer release without destroying
  local decisions: `--dry-run` default, `--apply`, `--force` (managed only), `--target`,
  `--profile`. Reports created/updated/up-to-date/manual-review-needed/project-local-preserved.
  Never overwrites `accepted-risks.json`, `phpstan-baseline.neon`, project-owned files, or code.
- **Example** `examples/laravel-react-docker/` now represents installer output: workflow ==
  the managed template (upstream scripts), README explains generation + sync + the migration;
  removed the superseded local normalizers (`scripts/sentinel/*`).

### Notes

- Profiles cover **Laravel, React, Node, Docker** (and the combination) only — full
  multi-stack project onboarding is **not** solved yet. Project-local risk decisions stay
  local and are never overwritten.


## [0.1.10] — Larastan PHPStan runner robustness; multi-source unsafe_docker enforcement

### Changed

- **Laravel PHPStan runner** (`scripts/runners/laravel-phpstan.sh`) hardened for Larastan
  apps: captures stdout/stderr **separately**, **extracts/validates** the JSON object
  before writing `reports/raw/phpstan.json` (so deprecation/boot noise on stdout no longer
  forces `unavailable`), keeps debug artifacts (`phpstan.stdout.raw`, `phpstan.stderr.log`)
  on trouble, and exits 0 so artifact upload is not skipped. Still **never writes a fake
  clean report** — PHPStan missing or no valid JSON → report absent (`unavailable`). New
  env: `SENTINEL_SHIELD_LARAVEL_PACKAGE_DISCOVER`, `SENTINEL_SHIELD_LARAVEL_PREPARE`
  (plus the existing `…_MEMORY_LIMIT/_CONFIG/_PATHS/_BIN`).
- **Multi-source `unsafe_docker` finding-scope enforcement** (`scripts/enforce-gates.sh`):
  matching now normalizes **all** unsafe_docker raw sources into one shape and matches
  `rule_id` + `files` — `reports/raw/hadolint.json` (DL*) **and**
  `reports/raw/docker-base-digest.json` (`SS_DOCKER_BASE_DIGEST`). A `DL3018` accepted-risk
  no longer (silently) covers base-digest findings; each source needs its own record. A
  source whose raw report is missing while the summary accounts for it is treated as
  **unaccepted** (fail-closed). New flag `--docker-base-digest-raw`.
- The base-digest detector emits `rule_id: SS_DOCKER_BASE_DIGEST` (underscored).
- **Release-gate** in `ci-release-gate.yml`, `ci-pipeline.yml`, and the example workflow
  now downloads the raw reports (`sentinel-shield-raw-security*`, merge-multiple) so
  finding-scope matching has `hadolint.json` + `docker-base-digest.json`. The reusable
  docker job now also runs the base-digest audit.

### Added

- Self-test `phpstan-runner` (missing/clean/errors/stdout-noise/fatal — never fakes) and
  `ud-multisource` (hadolint+base-digest matching; DL3018 never suppresses base-digest;
  unaccounted source fails closed). Schema/template/docs document the two unsafe_docker
  sources and an `SS_DOCKER_BASE_DIGEST` finding-scoped example.

### Notes

- The runner improvements are **not yet verified against zenchron-tools** (no real
  Larastan app in this repo) — tested via fake php/phpstan fixtures only.


## [0.1.9] — consolidation: promote pilot lessons upstream

Reusable pieces discovered during the `zenchron-tools` pilot are now owned by Sentinel
Shield so consuming projects stop duplicating scanner/tooling logic. See
[`docs/consolidation-v0.1.9.md`](docs/consolidation-v0.1.9.md) for the full classification.

### Added

- **Test adapters** → canonical `reports/raw/tests.json` (`{failures, errors}`), fail
  clearly on missing/invalid input (never fake success):
  `scripts/adapters/phpunit-to-tests-json.php` (JUnit XML),
  `scripts/adapters/vitest-to-tests-json.mjs`, `scripts/adapters/jest-to-tests-json.mjs`.
- **Laravel PHPStan runner** `scripts/runners/laravel-phpstan.sh` — handles the Laravel CI
  pitfalls (APP_ENV/APP_KEY, writable dirs, `package:discover`, memory limit), always
  writes the raw report on non-zero exit, and marks the tool **unavailable** (not a fake
  clean report) when PHPStan is absent. Env: `SENTINEL_SHIELD_PHPSTAN_{MEMORY_LIMIT,CONFIG,PATHS,BIN}`.
- **GitHub Actions pin audit** `scripts/audit-github-actions-pins.sh` +
  collector `scripts/collectors/github-actions-pins.sh` → `unsafe_github_actions`. Flags
  tag/branch/no-ref `uses:` and un-digested `container:`/`image:`/`docker://`; allows full
  40-char SHAs, `@sha256:` digests, and local (`./`) actions. Complementary to
  actionlint/zizmor (the builder SUMS the gate).
- **Docker base-image digest detector** `scripts/audit-docker-base-digest.sh` +
  collector `scripts/collectors/docker-base-digest.sh` → `unsafe_docker`. Flags
  `FROM image:tag` (and implicit `:latest`); allows `@sha256:` and multi-stage aliases.
  Distinct from Hadolint DL3018/DL3008 (package pinning).
- **Remediation guides** under `docs/remediation/`: react-dangerously-set-inner-html,
  phpstan-baseline-strategy, docker-dl3018-decision-tree, browser-stack-isolation,
  third-party-install-script-review, github-actions-sha-pinning, docker-base-digest-pinning.
- **Governance templates**: `templates/security-debt-register.md`,
  `sentinel-shield-rollout-status.md`, `security-triage-report.md`,
  `third-party-install-script-review.md`, `pinned-ci-references.md` (generic, not
  project-specific).
- Self-test `adapters` subcommand (in `all`): adapter parsing + fail-closed, runner
  unavailable-not-fake, pin audit flag/pass, base-digest flag/pass, template existence.

### Notes

- Promoting these capabilities does **not** move a project's debt or accepted-risk
  decisions upstream — those stay in the consuming project (`profile.yaml`,
  `accepted-risks.json`, baselines, code fixes). Class **D** in the consolidation doc.
- The PHP adapter is validated by `php -l` + fixture parse (run via local PHP or Docker);
  CI/self-test skip it cleanly when PHP is absent.

## [0.1.8] — finding-scoped accepted-risk suppression

### Added

- **Finding-scoped accepted-risk suppression.** Accepted-risk records are now
  FINDING-SCOPED by default: a record suppresses only the findings it matches, not the
  whole gate. Implemented for `unsafe_docker` (matched against `reports/raw/hadolint.json`
  by `rule_id` + `files`). New record fields: `scope` (`finding`|`gate`, default
  `finding`), `rule_id`, `rule_ids`, `files`; `components`/`fingerprints` are reserved
  (declared in the schema, not yet enforced).
- `enforce-gates.sh --hadolint-raw <path>` (default `<summary-dir>/raw/hadolint.json`)
  for unsafe_docker finding matching.
- Enforcement reports (`sentinel-shield-enforcement.json`/`.md`) now show: accepted-risks
  loaded; applied **broad** (`scope:gate`) vs **finding-scoped**; pending/expired/invalid/
  legacy-unscoped ignored; and a per-finding `unsafe_docker` table (rule_id, file, line,
  accepted, matched risk id) with total/accepted/unaccepted. Unaccepted findings are not
  hidden — they fail the gate.
- Self-test `finding-scope` subcommand (9 cases): per-file/per-rule matching, mixed
  accepted/unaccepted, legacy-unscoped (no suppress), `scope:gate` (broad), pending/
  expired (no suppress), and secrets-never-suppressed.

### Changed

- **Prevents one `unsafe_docker` accepted-risk from suppressing unrelated Docker
  findings** (the v0.1.7 multi-Dockerfile-discovery governance bug): a DL3018 record for
  `Dockerfile`/`Dockerfile.prod` no longer hides DL3008/DL3016/DL4006 in other Dockerfiles.
- **Backward compatibility / migration:** a record with no `scope` and no
  `rule_id`/`files` is ambiguous and **no longer suppresses** (it warns). Broad gate-wide
  suppression now requires explicit `"scope": "gate"` and is reported as broad and
  discouraged. Raw counts are still never reduced; `secrets`/`expired_exceptions`/
  `missing_release_evidence` are still never suppressible.

### Notes

- Finding-scoped suppression is implemented for **`unsafe_docker` only** in v0.1.8. Other
  suppressible gates (`medium_vulnerabilities`) support only broad `scope:gate`
  suppression; finding-scope records targeting them warn and do not suppress.
- If the raw Hadolint report is missing, finding-scope records cannot match and the
  `unsafe_docker` gate fails on any count > 0 (declare `scope:gate` for broad).

## [0.1.7] — global multi-Dockerfile Hadolint discovery

### Added

- `scripts/run-hadolint.sh` (POSIX sh): discovers all Dockerfile-like files
  (`Dockerfile`, `Dockerfile.*`, `docker/**/Dockerfile[.*]`, `.docker/**/Dockerfile[.*]`),
  runs Hadolint on each (local binary or `hadolint/hadolint` Docker image), and **merges
  the JSON arrays into one `reports/raw/hadolint.json`** (per-finding `.file` path
  preserved) that the existing `hadolint` collector parses unchanged. Prunes generated/
  cache dirs (`node_modules`, `vendor`, `dist`, `build`, `coverage`, `.git`). `--list`
  mode prints discovered files. Skips cleanly (writes nothing, exit 0) when no
  Dockerfiles exist → collector marks hadolint `unavailable`. Never fakes an empty `[]`
  on unexpected Hadolint failure (exit 1, no file written).

### Changed

- `ci-docker.yml`, `ci-pipeline.yml`, and the Laravel+React+Docker example workflow now
  call `run-hadolint.sh` instead of the single-`Dockerfile` `hadolint-action`. The
  example's docker-security job checks out Sentinel Shield to use the script.
- **Removes the need for project-local Hadolint multi-file workarounds** — multi-file
  discovery is now a global Sentinel Shield behavior. Project-specific accepted-risk
  decisions stay in the consuming project (not moved into Sentinel Shield).
- `unsafe_docker` normalization is unchanged (collector still counts error+warning).
- Self-test `hadolint` subcommand (in `all`): discovery includes Dockerfile +
  Dockerfile.prod + `docker/**`, excludes vendor/node_modules, handles "no Dockerfiles",
  merged JSON stays valid, and the collector still maps `unsafe_docker`.

### Notes

- DL3018 is **not** hidden — findings from every discovered Dockerfile flow into
  `unsafe_docker` (more files scanned can raise the count). Accepted-risk governance is
  unchanged and remains the consuming project's responsibility.

## [0.1.6] — separate app vs third-party rule trees; high-confidence supply-chain rules

### Changed (rule layout — see migration note)

- **Physically separated Semgrep rule trees.** Application rules moved to
  `semgrep/app/{php,javascript,docker}`; supply-chain rules to
  `semgrep/supply-chain/third-party/`. Broad/noisy heuristics moved to a **sibling**
  `semgrep/supply-chain/third-party-experimental/` (opt-in; NOT loaded by the default
  third-party config). The old `semgrep/{php,javascript,docker,third-party}` paths are
  gone.
- **App scans can no longer load third-party rules.** All workflows
  (`ci-security.yml`, `ci-pipeline.yml`, example, `run-local-security.sh`) config the
  app scan from `semgrep/app` (never the bare `semgrep/` catch-all) and the
  third-party scan from `semgrep/supply-chain/third-party`.

### Changed (third-party JS rules)

- **Tightened to high-confidence by default.** Default third-party set = npm
  install-script risk (`js-install-scripts.yml`, with a higher-severity variant for
  `curl`/`wget`/`bash`/`node -e`/`child_process`/URL), decode→eval + remote-fetch→eval
  (`js-high-confidence.yml`), and PHP decode→eval / `preg_replace /e`
  (`php-suspicious.yml`). The broad rules that flooded `node_modules` with false
  positives (`ss-tp-js-dynamic-require`, generic `eval`/`new Function`,
  `child_process`, generic outbound, `.env` read, long-base64) are now **experimental
  / opt-in**.

### Changed (third-party target discovery)

- Workflows mount each dependency dir under a **neutral name** (`/scan/depN`) so
  Semgrep's built-in `node_modules`/`vendor` ignore + git-only discovery no longer skip
  them, and exclude `*.min.js`/`dist`/`build`/`coverage`. Still skips cleanly when no
  dependency dirs exist.

### Fixed

- Three pre-existing Semgrep rules that never compiled now parse and run:
  `ss-react-dangerously-set-inner-html`, `ss-react-unsanitized-html-render` (JSX
  bare-attribute patterns), and `ss-symfony-missing-csrf-note` (attribute+method
  pattern → regex).

### Notes

- Summary keys and the collector (`third-party-semgrep.sh`, maps by
  `metadata.sentinel_shield_category`) are unchanged — `security-summary.json` stays
  backward compatible.
- **Migration:** consuming projects that copied a workflow must repoint app scans to
  `…/semgrep/app` and third-party scans to `…/semgrep/supply-chain/third-party`.

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
