# Profile Compatibility (v0.1.23)

Reference for every Sentinel Shield profile manifest: schema validity, the workflow
template it installs, the governance docs it installs, the raw reports its pipeline is
expected to produce, and the per-stage tool lists (`recommended_*_tools`, added in
v0.1.22). This is descriptive — it reports what the manifests in `profiles/` actually
declare. It does not change any gate.

> **Scope honesty.** Eight manifests ship today: the single-stack profiles
> **laravel, symfony, node, react, docker, php-library** and the combinations
> **laravel-react-docker** and **node-react**. Stacks without a manifest (Go, Python,
> Rust, …) are still **not** covered — onboarding for those is not solved.

All commands below assume a Sentinel Shield checkout as the working directory and a
consuming project (or fixture) passed via `--target`. `install-baseline.sh` is **dry-run
by default** and writes nothing without `--apply`.

## 36. Profile-manifest validation summary

Each manifest is JSON and conforms to `profiles/profile.manifest.schema.json`
(`required: ["profile","files"]`; `files`/`workflows`/`docs` entries are
`{source,target,mode}` with `mode ∈ {create-if-missing, overwrite-if-force,
sync-managed-block, manual}`). The schema sets `additionalProperties: true`, so the
v0.1.22 `recommended_*` fields validate.

Reproduce:

```sh
python3 - <<'PY'
import json, glob
for f in sorted(glob.glob('profiles/**/*.manifest.json', recursive=True)):
    d = json.load(open(f))
    assert 'profile' in d and 'files' in d, f
    for key in ('files', 'workflows', 'docs'):
        for e in d.get(key, []):
            assert set(e) == {'source', 'target', 'mode'}, (f, e)
            assert e['mode'] in {'create-if-missing', 'overwrite-if-force',
                                 'sync-managed-block', 'manual'}, (f, e)
    print('ok', f)
PY
```

| # | Manifest | `profile` | Valid |
|---|---|---|---|
| 1 | `profiles/laravel/profile.manifest.json` | `laravel` | yes |
| 2 | `profiles/node/profile.manifest.json` | `node` | yes |
| 3 | `profiles/react/profile.manifest.json` | `react` | yes |
| 4 | `profiles/docker/profile.manifest.json` | `docker` | yes |
| 5 | `profiles/php-library/profile.manifest.json` | `php-library` | yes |
| 6 | `profiles/symfony/profile.manifest.json` | `symfony` | yes |
| 7 | `profiles/combinations/laravel-react-docker.manifest.json` | `laravel-react-docker` | yes |
| 8 | `profiles/combinations/node-react.manifest.json` | `node-react` | yes |

## 37. Declared raw-report expectations (`recommended_raw_reports`)

The reports the profile's pipeline is expected to emit under `reports/raw/`. This is a
declaration of intent, not a guarantee a tool ran — a tool that cannot run on a given
repo emits an honest empty/clean report, never a fabricated one.

| Profile | `recommended_raw_reports` |
|---|---|
| laravel | `phpstan.json`, `tests.json`, `composer-audit.json`, `gitleaks.json`, `semgrep.json`, `deptrac.json` |
| node | `npm-audit.json`, `tests.json`, `gitleaks.json`, `semgrep.json` |
| react | `npm-audit.json`, `tests.json`, `typescript.json`, `eslint.json`, `gitleaks.json`, `semgrep.json` |
| docker | `hadolint.json`, `docker-base-digest.json`, `trivy.json`, `checkov.json`, `dockle.json`, `gitleaks.json`, `semgrep.json` |
| php-library | `php-syntax.json`, `phpstan.json`, `tests.json`, `composer-audit.json`, `gitleaks.json`, `semgrep.json` |
| symfony | `php-syntax.json`, `phpstan.json`, `psalm.json`, `deptrac.json`, `php-style.json`, `tests.json`, `composer-audit.json`, `gitleaks.json`, `semgrep.json` |
| laravel-react-docker | `gitleaks.json`, `semgrep.json`, `trivy.json`, `composer-audit.json`, `npm-audit.json`, `phpstan.json`, `tests.json`, `hadolint.json`, `docker-base-digest.json`, `github-actions-pins.json`, `codeql.json`, `osv-scanner.json`, `grype.json`, `dependency-check.json`, `checkov.json`, `dockle.json`, `scorecard.json`, `trufflehog.json`, `php-syntax.json`, `php-style.json`, `psalm.json`, `zap.json`, `nuclei.json`, `ai-security-review.json`, `dependency-policy.json`, `architecture-tests.json`, `deptrac.json`, `sbom.spdx.json` |
| node-react | `npm-audit.json`, `tests.json`, `typescript.json`, `eslint.json`, `gitleaks.json`, `semgrep.json` |

## 38. Workflow-template reference

The CI workflow file(s) each profile installs (manifest `workflows[].source` →
`target`). Single-stack profiles and `node-react` install the single all-in-one
`sentinel-shield.yml` (`overwrite-if-force`). The `laravel-react-docker` combination
additionally references the split per-stage workflows as `manual` entries (printed for
the maintainer; never auto-written).

| Profile | Workflow template(s) installed |
|---|---|
| laravel | `templates/workflows/sentinel-shield.yml` → `.github/workflows/sentinel-shield.yml` (overwrite-if-force) |
| node | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |
| react | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |
| docker | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |
| php-library | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |
| symfony | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |
| laravel-react-docker | `sentinel-shield.yml` (overwrite-if-force); plus `manual`: `sentinel-shield-pr-fast.yml`, `sentinel-shield-main.yml`, `sentinel-shield-scheduled.yml`, `sentinel-shield-dast.yml`, `sentinel-shield-ai-review.yml` |
| node-react | `templates/workflows/sentinel-shield.yml` (overwrite-if-force) |

## 39. Docs reference

Governance/doc templates each profile installs (manifest `docs[].source` → `target`,
all `create-if-missing`). `node` and `react` install no doc templates.

| Profile | Docs template(s) installed |
|---|---|
| laravel | `templates/security-debt-register.md` → `docs/security/security-debt-register.md` |
| node | (none) |
| react | (none) |
| docker | `templates/pinned-ci-references.md` → `docs/security/pinned-ci-references.md` |
| php-library | `templates/security-debt-register.md` → `docs/security/security-debt-register.md` |
| symfony | `templates/security-debt-register.md` → `docs/security/security-debt-register.md` |
| laravel-react-docker | `security-debt-register.md`, `sentinel-shield-rollout-status.md`, `security-triage-report.md` (→ `sentinel-shield-triage.md`), `pinned-ci-references.md`, `third-party-install-script-review.md` (all under `docs/security/`) |
| node-react | `templates/security-debt-register.md` → `docs/security/security-debt-register.md` |

## 40. Profile compatibility table

| Profile | Stack(s) | Install command | PR-fast tools | Main-gate tools | Scheduled tools | Raw reports (count) |
|---|---|---|---|---|---|---|
| laravel | laravel | `install-baseline.sh --target <dir> --profile laravel` | php-syntax, phpstan, composer-audit, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, deptrac, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 6 |
| symfony | symfony, php | `install-baseline.sh --target <dir> --profile symfony` | php-syntax, phpstan, psalm, php-style, composer-audit, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, deptrac, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 9 |
| node | node | `install-baseline.sh --target <dir> --profile node` | npm-audit, eslint, typescript, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 4 |
| react | react, node | `install-baseline.sh --target <dir> --profile react` | npm-audit, eslint, typescript, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 6 |
| docker | docker | `install-baseline.sh --target <dir> --profile docker` | hadolint, docker-base-digest, gitleaks, semgrep | trivy-fs, trivy-image, syft, grype, checkov | trufflehog, scorecard, dockle, grype-fs | 7 |
| php-library | php | `install-baseline.sh --target <dir> --profile php-library` | php-syntax, phpstan, composer-audit, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 6 |
| laravel-react-docker | laravel, react, node, docker | `install-baseline.sh --target <dir> --profile laravel-react-docker` | php-syntax, phpstan, composer-audit, npm-audit, eslint, typescript, hadolint, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, trivy-image, syft, grype, deptrac, checkov, dependency-check | trufflehog, scorecard, dockle, dependency-check, grype-fs | 28 |
| node-react | node, react | `install-baseline.sh --target <dir> --profile node-react` | npm-audit, eslint, typescript, gitleaks, semgrep, tests | codeql, osv-scanner, trivy-fs, syft, grype, dependency-check | trufflehog, scorecard, dependency-check, grype-fs | 6 |

`install-baseline.sh` resolves `--profile <name>` from `profiles/<name>/profile.manifest.json`
first, then `profiles/combinations/<name>.manifest.json`. Default profile is
`laravel-react-docker`; default mode is `report-only`.

## Tool-list stack-correctness notes (tasks 41-45)

Each profile's tool lists are verified against the stack it targets:

- **PHP analysis tools are declared only where the manifest actually wires them.** A tool
  named in a `recommended_*_tools` list must correspond to a `required_scripts` runner
  and/or a `recommended_raw_reports` entry, otherwise it would over-claim coverage.
- **symfony** runs the full PHP analysis surface — `php-syntax`, `phpstan`, `psalm`,
  `php-style` (PHP-CS-Fixer), `composer-audit`, `deptrac` — plus `gitleaks`/`semgrep`.
  In v0.1.23, `php-style` was added to `recommended_pr_fast_tools`: the manifest already
  declared `scripts/runners/php-style.sh` and `php-style.json`, so the tool ran but was
  missing from the PR-fast list. That gap is now closed.
- **laravel** intentionally runs a leaner analysis set in CI — `phpstan` (Larastan via
  `scripts/runners/laravel-phpstan.sh`) + `deptrac` (main-gate). The profile *ships*
  `psalm.xml`/`pint.json`/`rector.php` as reference configs for manual project adoption,
  but wires `pint` as a **required** tool (`missing_behavior: fail`, PR + main) and `psalm` as recommended — an earlier revision of this line claimed it deliberately did not wire style analysis, which the manifest contradicts; it does not wire the `php-style` runner specifically or raw reports, so they are deliberately
  absent from the tool lists (adding them would over-claim).
- **php-library** is framework-free PHP: `php-syntax`, `phpstan` (generic, not Larastan),
  `composer-audit`, `gitleaks`, `semgrep`. No deptrac/psalm/Docker assumptions.
- **node** / **react** / **node-react**: `npm-audit`, `eslint`, `typescript`, `tests`,
  `gitleaks`, `semgrep`. `react`/`node-react` add `.semgrepignore` excluding build/dist;
  `node` (library) installs no `.semgrepignore`.
- **docker** (docker-only): `hadolint`, `docker-base-digest`, `trivy-fs`, `trivy-image`,
  `dockle`, `checkov` spread across PR-fast / main-gate / scheduled, plus
  `gitleaks`/`semgrep`. No application-language tools — pair with an app-language profile
  (or the laravel-react-docker combination) for repos that also ship code.
- **laravel-react-docker** unions the Laravel (PHP), React/Node (JS) and Docker tool
  surfaces and is the only profile that references the split per-stage workflows.

## Fixture coverage (tasks 31-35)

The fixtures under `tests/fixtures/projects/` are minimal, offline, NOT full apps. They
exist so `detect-stack.sh` and `install-baseline.sh` (dry-run) can resolve a profile and
exercise file modes without a network/dependency install.

| Fixture | detect-stack result | Files present | Exercises |
|---|---|---|---|
| `laravel-react-docker` | laravel, react, node, docker | `composer.json`, `artisan`, `package.json`, `Dockerfile` | full combination install/sync; `artisan` triggers laravel detection |
| `node-react` | node, react | `package.json` (react dep), `vite.config.ts` | JS-only stack; react via package.json + vite config |
| `docker-only` | docker | `Dockerfile`, `compose.yaml` | container/IaC-only repo |
| `php-library` | php (not laravel) | `composer.json`, `src/Lib.php` | plain PHP package, no framework |
| `symfony` | symfony | `composer.json`, `composer.lock`, `src/Kernel.php`, `bin/console` | symfony detection via `bin/console`; full PHP-analysis profile install dry-run |

The four pre-existing fixtures are adequate for an install dry-run and `detect-stack`:
the installer reads source files from the Sentinel Shield checkout (not the fixture) and
only needs the target to be a directory, while `detect-stack.sh` keys off the marker
files each fixture already provides (`artisan`, `package.json` + `vite.config.ts`,
`Dockerfile`/`compose.yaml`, `composer.json`). No files were added to those four.

The new **symfony** fixture adds `bin/console` (the marker `detect-stack.sh` keys on for
Symfony, alongside `symfony.lock`) and a `composer.lock` beside `composer.json` so the
`dependency-policy` audit reports **0 violations** (manifest-without-lockfile is the only
policy rule implemented today). `src/Kernel.php` mirrors a real Symfony app layout.

## The `docker` profile

`profiles/docker/profile.manifest.json` declares a real `tools` map and resolves **13 tools**:

```sh
$ sh scripts/resolve-effective-profile.sh --profile docker --format json | jq '.tools|length'
13
```

Policies follow **validated maturity** ([`scanner-maturity-policy.md`](scanner-maturity-policy.md)),
not aspiration:

| Policy | Tools | Why |
| --- | --- | --- |
| `required` | `hadolint`, `docker-base-digest`, `gitleaks`, `actionlint`, `zizmor`, `github-actions-pins`, `trivy-fs`, `syft`, `grype` | run from Sentinel Shield itself, or live-validated |
| `recommended` | `checkov`, `terrascan`, `conftest` | **ci-validated (evidence-fixture) only** — requiring them would assert live IaC validation this project has not performed |
| `optional` | `dockle` | live-validated, but needs a built image (`$SENTINEL_SHIELD_IMAGE`) a consumer may not produce |

Nine tools are gate-enforced, so `required_tool_failures` fires when their evidence is absent.

> **Previously this profile resolved ZERO tools** — it declared no `tools` map and no `extends`,
> so every scanner these docs associated with it was never required, never run and never gated,
> and `required_tool_failures` could not fire at all. Because `hardened-enterprise` **extends**
> `docker`, that profile silently had no container or IaC coverage either.
