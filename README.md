# Sentinel Shield

> A hardened engineering baseline for code, containers, CI, and infrastructure.

Sentinel Shield is a reusable security, quality, architecture, CI/CD, Docker, and
release-gate baseline. It is designed to be applied consistently across many
project types and to make security a measurable release requirement rather than a
best-effort activity.

This repository is not a demo. It is intended for use in real production projects.

---

## 1. Purpose

Engineering teams repeatedly re-solve the same problems: which static analysers to
run, how strict the CI should be, how to handle Docker security, how to manage
exceptions, and when a release is allowed to ship. Sentinel Shield codifies those
decisions once so they can be reused.

It provides:

- A written security standard ([`SECURITY-STANDARD.md`](SECURITY-STANDARD.md)).
- A release-gate standard ([`RELEASE-GATES.md`](RELEASE-GATES.md)).
- Per-stack tooling profiles for PHP/Laravel/Symfony, Node, React, and Docker.
- Reusable GitHub Actions workflow templates.
- Semgrep rules, OPA/Rego policies, and local helper scripts.
- Governance documents: severity policy, exception policy, readiness checklist.

Sentinel Shield can be used in three ways:

1. As a standalone standards repository that teams read and follow.
2. As a baseline copied into an existing project (under `.sentinel-shield/`).
3. As a future source of reusable, centrally-maintained GitHub Actions workflows.

---

## 2. Supported stacks

| Stack | Status | Profile |
| --- | --- | --- |
| Laravel (PHP 8.3+) | Supported | [`profiles/laravel`](profiles/laravel) |
| Symfony 6/7 (PHP 8.3+) | Supported | [`profiles/symfony`](profiles/symfony) |
| Node.js (22+) | Supported | [`profiles/node`](profiles/node) |
| React + TypeScript | Supported | [`profiles/react`](profiles/react) |
| Docker / Compose | Supported | [`profiles/docker`](profiles/docker) |
| GitHub Actions | Supported | [`docs/github-actions-security.md`](docs/github-actions-security.md) |
| Infrastructure / server security | Partial (OPA, Trivy) | [`policies/opa`](policies/opa) |

---

## 3. Adoption modes

Sentinel Shield supports four modes. A project picks one mode and tightens over
time. See [`docs/adoption-guide.md`](docs/adoption-guide.md) for the migration path
and [`RELEASE-GATES.md`](RELEASE-GATES.md) for exact blocking thresholds.

| Mode | Intended for | CI fails on |
| --- | --- | --- |
| `report-only` | Legacy projects | Leaked secrets, broken builds, catastrophic misconfiguration only |
| `baseline` | Projects being migrated | New critical/high issues, new secrets, new architecture violations |
| `strict` | Active production projects | Critical/high vulns, static-analysis failures, test failures, architecture and Docker/Actions violations |
| `regulated` | Casino, fintech, compliance-heavy systems | Everything in `strict` plus SBOM, release evidence, formal exceptions, mandatory security review, rollback plan |

---

## 4. Repository layout

```txt
sentinel-shield/
├─ README.md                 # This file
├─ SECURITY-STANDARD.md      # Secure coding and operational security standard
├─ RELEASE-GATES.md          # When a release is allowed to ship
├─ docs/                     # Policies and guides
├─ profiles/                 # Per-stack tool configurations
├─ github/                   # Reusable workflow + Dependabot + CodeQL templates
├─ semgrep/                  # Semgrep rules — app/ (application SAST) and
│                            #   supply-chain/ (third-party + opt-in experimental)
├─ policies/                 # OPA/Rego policies and exception templates
├─ scripts/                  # Local helper scripts (detect, scan, report, install)
└─ templates/                # PR, security review, threat model, ADR, readiness
```

---

## 5. Quick start

```sh
# 1. Detect the stack of a project you want to onboard.
sh scripts/detect-stack.sh

# 2. Run the local security sweep (skips tools that are not installed).
sh scripts/run-local-security.sh

# 3. Generate a baseline report.
sh scripts/generate-report.sh

# 4. Preview which baseline files would be copied (dry-run is the default).
sh scripts/install-baseline.sh --target /path/to/your/project

# 5. Apply for real once you have reviewed the dry-run output.
sh scripts/install-baseline.sh --target /path/to/your/project --apply
```

---

## 6. Example `.sentinel-shield/profile.yaml`

Each consuming project keeps its configuration in `.sentinel-shield/profile.yaml`.

```yaml
project:
  name: proxyflux
  type: laravel
  criticality: high

profiles:
  - laravel
  - react
  - docker
  - github-actions

gates:
  mode: baseline
  fail_on:
    secrets: true
    critical_vulnerabilities: true
    high_vulnerabilities: true
    architecture_violations: true
    type_errors: true
    test_failures: true

exceptions:
  allowed: true
  require_owner: true
  require_expiry_date: true
```

The canonical, fully-commented template is [`templates/profile.yaml`](templates/profile.yaml).

---

## 6a. Gate resolver

The selected adoption mode is **machine-readable and enforceable**, not just
documented. [`scripts/resolve-gates.sh`](scripts/resolve-gates.sh) reads
`.sentinel-shield/profile.yaml`, applies the mode defaults, layers any explicit
overrides, and writes normalized artifacts that CI loads and acts on. Full docs:
[`docs/gate-resolution.md`](docs/gate-resolution.md).

Run it locally:

```sh
# Resolve the project profile to reports/sentinel-shield-gates.{env,json,md}
sh scripts/resolve-gates.sh

# Force a mode, or pick a format
sh scripts/resolve-gates.sh --mode strict --format json
```

**How overrides work.** Each mode provides default `fail_on` thresholds. Any key set
under `gates.fail_on` in the profile overrides its default, and the resolver reports
the override explicitly (it never hides them):

```txt
[sentinel-shield] Mode: strict
[sentinel-shield] Override: medium_vulnerabilities=false (default true)
```

The resolver prefers `yq` v4 if installed and otherwise uses a limited built-in
parser for the canonical profile format — no `jq`/`yq`/Python required for the
resolver path.

---

## 6b. Gate enforcer

The resolver says *what should fail*; the **enforcer** decides *whether it does*.
[`scripts/enforce-gates.sh`](scripts/enforce-gates.sh) consumes the resolved flags
plus a normalized findings document, `reports/security-summary.json`, and exits
`0` (pass) / `1` (fail) / `2` (config/input error).

**`security-summary.json` is the contract.** Scanner workflows normalize their
output into one document with a required `summary` of 12 counts/flags
([schema](schemas/security-summary.schema.json),
[example](templates/security-summary.example.json),
[docs](docs/security-summary-schema.md)).

**How `enforce-gates.sh` works.**

- Loads `sentinel-shield-gates.env` **with strict per-line validation** — it is
  never blind-sourced; any line that is not `SENTINEL_SHIELD_*=<safe-value>` is
  rejected (exit 2). No command substitution, backticks, or shell metacharacters
  pass.
- Requires `jq` to read JSON (it does not parse JSON with fragile shell hacks). If
  `jq` is absent it exits 2 with a clear message.
- A missing required `summary` key is an error (exit 2), never a silent zero.
- Each gate fails only when its resolved flag is `true` and its finding crosses the
  threshold; disabled gates are recorded as `skipped`.
- **Accepted-risk suppression (v0.1.3+):** an APPROVED, unexpired, owner-bound record
  in `.sentinel-shield/accepted-risks.json` may mark a **suppressible** gate
  (`unsafe_docker`, `medium_vulnerabilities`) as `accepted-risk` — the raw count is
  preserved (not zeroed) and reported, and it does not fail. `secrets`,
  `expired_exceptions`, and `missing_release_evidence` are **never** suppressible;
  `pending`/expired records never suppress. See
  [`docs/accepted-risk-suppression.md`](docs/accepted-risk-suppression.md).
- Writes `reports/sentinel-shield-enforcement.{json,md}`.

Local example:

```sh
sh scripts/resolve-gates.sh --mode baseline
cp templates/security-summary.example.json reports/security-summary.json
sh scripts/enforce-gates.sh --format all   # exit 0 (all zero findings)
```

CI: [`github/workflows/ci-release-gate.yml`](github/workflows/ci-release-gate.yml)
runs `resolve-gates.sh`, provides `security-summary.json` (real scanner output, or
the all-zero example as a clearly-marked fallback), runs `enforce-gates.sh`, uploads
the resolver + enforcement artifacts, and lets the enforcer's exit code be the
release gate.

---

## 6c. Scanner normalization (producing `security-summary.json`)

Sentinel Shield ships a first-pass layer that turns raw scanner output into the
contract above, keeping scanner *execution* separate from *normalization*:

```txt
reports/raw/*.json  →  scripts/collectors/<tool>.sh  →  scripts/build-security-summary.sh  →  reports/security-summary.json
```

- **Scanner workflows** run the tools and write raw output to `reports/raw/`
  (e.g. `gitleaks.json`, `semgrep.json`, `trivy.json`, …).
- **Collectors** ([`scripts/collectors/`](scripts/collectors/)) each parse one raw
  file with `jq` and emit a small normalized object. A missing artifact ⇒ the tool
  is `unavailable` (counts 0), not a crash; invalid JSON ⇒ exit 2.
- **The builder** ([`scripts/build-security-summary.sh`](scripts/build-security-summary.sh))
  merges collectors by summing counts, builds the `tools` object, sets evidence by
  file existence, reads `reports/exceptions.json` if present, and writes a
  schema-consistent summary (with a self-check). `--strict-tools` / `--require-tool`
  make missing artifacts fatal.

Fourteen tools are supported today (Gitleaks, Semgrep, Trivy, composer audit, npm
audit, TypeScript, ESLint, PHPStan, Psalm, Deptrac, tests, Hadolint, actionlint,
zizmor) with **conservative, tunable** severity mappings — not a claim of perfect
coverage. See [`docs/scanner-normalization.md`](docs/scanner-normalization.md) and,
for the Node/React mappings, [`docs/node-react-normalization.md`](docs/node-react-normalization.md).
Clean input examples live in [`templates/raw/`](templates/raw/).

**Multi-Dockerfile Hadolint (v0.1.7+).** [`scripts/run-hadolint.sh`](scripts/run-hadolint.sh)
discovers and lints **all** Dockerfiles (`Dockerfile`, `Dockerfile.*`, `docker/**`,
`.docker/**`) and merges them into one `reports/raw/hadolint.json` → `unsafe_docker`.
Consuming projects should call this script, **not** re-implement per-Dockerfile logic.
See [`docs/docker-security-standard.md`](docs/docker-security-standard.md).

**Semgrep scoping (v0.1.4+).** Semgrep scans **application source** only — copy a
[`.semgrepignore` template](profiles/laravel/.semgrepignore) to your repo root to
exclude vendored/generated/cache assets (`vendor/`, `node_modules/`,
`public/js/filament/`, build output, …). This is **SAST-only**: composer audit, npm
audit, Trivy, Syft SBOM, Gitleaks, and Hadolint are **not** narrowed by it. See
[`docs/semgrep-scoping.md`](docs/semgrep-scoping.md).

**Third-party suspicious-code scan (v0.1.5+; rule trees separated in v0.1.6).** Rules
are physically split: application SAST configs from `semgrep/app/` and a **separate**
supply-chain channel configs from `semgrep/supply-chain/third-party/` (high-confidence
by default; broad heuristics opt-in under `…/third-party-experimental/`). The app scan
**cannot** load third-party rules; the third-party scan writes a separate artifact +
`third_party_*` keys, non-blocking by default, and **does not replace** Trivy /
composer audit / npm audit / Gitleaks / SBOM. See
[`docs/third-party-supply-chain-scan.md`](docs/third-party-supply-chain-scan.md).

```sh
# Build a summary from raw artifacts, then resolve + enforce.
sh scripts/build-security-summary.sh --project-name proxyflux --project-type laravel
sh scripts/resolve-gates.sh --mode baseline
sh scripts/enforce-gates.sh --format all
```

---

## 6d. CI artifact handoff (production-safe)

Scanner output reaches the release gate as **artifacts**, with a strict fallback
rule. Artifact names:

| Artifact | Contents | Produced by |
| --- | --- | --- |
| `sentinel-shield-raw-security` | `reports/raw/*.json` | `ci-security.yml` |
| `sentinel-shield-raw-security-php` / `-node` / `-docker` | `reports/raw/*.json` | `ci-php` / `ci-node` / `ci-docker` |
| `sentinel-shield-security-summary` | `reports/security-summary.json` | `ci-security.yml` (builder) |
| `sentinel-shield-sbom` | `reports/sbom.spdx.json` | `ci-security.yml` |
| `sentinel-shield-gate-resolution` | `reports/sentinel-shield-gates.{env,json,md}` | `ci-release-gate.yml` |
| `sentinel-shield-enforcement` | `reports/sentinel-shield-enforcement.{json,md}` | `ci-release-gate.yml` |
| `sentinel-shield-release-evidence` | `reports/release-evidence.md` | `ci-release-gate.yml` |

### Fallback rule (mandatory)

> The all-zero example summary is **never** accepted in `baseline`, `strict`, or
> `regulated`. If the gate cannot prove a real `security-summary.json` exists:
> **`baseline`/`strict`/`regulated` → fail; `report-only` → warn and continue with
> the example.**

This is enforced by [`scripts/select-security-summary.sh`](scripts/select-security-summary.sh),
which the release gate runs after resolving the mode. "Real" means the summary
exists, is valid JSON, and is not byte-identical to the example template (a real
builder run always differs) — so dropping in the example cannot spoof a pass.

### Recommended topology

`actions/download-artifact` only sees artifacts from the **current run**. For
production, run the release gate **in the same workflow** as the scanner jobs using
`needs:`, so the `sentinel-shield-security-summary` artifact is in-run:

```yaml
jobs:
  security:        # runs scanners, builds + uploads sentinel-shield-security-summary
    ...
  release-gate:
    needs: [security]
    steps:
      - uses: actions/download-artifact@v4
        with: { name: sentinel-shield-security-summary, path: reports }
      - run: sh scripts/select-security-summary.sh --gates-env reports/sentinel-shield-gates.env
      - run: sh scripts/enforce-gates.sh --format all
```

**Cross-workflow** retrieval (release gate in a separate workflow from scanners) is
**not** wired here: GitHub does not download artifacts across unrelated runs without
extra logic, and Sentinel Shield deliberately ships **no** artifact discovery that
could pull from untrusted runs. If you need it, wire a trusted strategy keyed on
commit SHA + workflow run ID + a trusted branch + environment protection rules. The
standalone `ci-release-gate.yml` is fail-closed: with no real summary,
`baseline`/`strict`/`regulated` fail.

### Combined reference workflow (recommended)

[`github/workflows/ci-pipeline.yml`](github/workflows/ci-pipeline.yml) is the
**canonical** production topology: it runs everything in one workflow run so the
summary artifact is passed in-run via `needs:` + `upload`/`download-artifact` — no
cross-run handoff required.

```txt
prepare → { php-quality, node-quality, docker-security, security-scan }
        → build-security-summary → release-gate
```

- `prepare` resolves project metadata (name/type/criticality/branch/commit) by
  reusing `resolve-gates.sh` — no YAML parsing in the workflow.
- The four stack jobs are **best-effort**: each detects its files (composer.json /
  package.json / Dockerfile / always for secrets) and uploads `reports/raw/*.json`.
  Absent tools/files ⇒ no raw ⇒ the builder marks them `unavailable` (not faked).
- `build-security-summary` downloads every `sentinel-shield-raw-security*` artifact
  (`pattern` + `merge-multiple`) plus the SBOM, builds the **real**
  `security-summary.json` (never the example), and uploads it.
- `release-gate` downloads that summary, resolves, applies the fallback policy, and
  enforces. Its exit code is the gate.

**Why same-run `needs:` is preferred over the standalone templates.** The standalone
`ci-*.yml` files are useful when stages live in different workflows, but cross-run
artifact handoff is unsafe to automate. The combined pipeline keeps every artifact
inside one trusted run, so the release gate provably consumes the summary the
scanners just produced.

**Adapting for Laravel + React + Docker.** Set `.sentinel-shield/profile.yaml`
(`type`, `criticality`, `mode`); the stack jobs already detect each ecosystem. Add
your real test step that writes a normalized `reports/raw/tests.json`
(`{ "failures": N, "errors": N }`), tune scanner flags, and pin the actions to SHAs.
No pipeline logic changes — only configuration.

### Self-test workflow

[`github/workflows/ci-self-test.yml`](github/workflows/ci-self-test.yml) makes
Sentinel Shield test **itself** on every push/PR, using the fixtures in
`templates/raw/`, `templates/profile.yaml`, and the example summary. Jobs:

- **syntax** — `sh -n` over every script + JSON/XML/YAML validity.
- **lifecycle** — runs `build → resolve → select → enforce → generate-report`
  against the fixtures and validates the generated JSON (uploads
  `sentinel-shield-self-test-reports`).
- **fallback-policy** — asserts the exact fail-closed exit codes (report-only +
  missing → 0; baseline/strict/regulated + missing → 1; copied example → 1; real
  summary → 0). The job fails if any exit code is wrong.
- **negative-policy** — proves the self-test validates **both pass and fail** gate
  behavior: a clean summary passes, but baseline + {high vuln, secret, type errors,
  test failures, architecture violations} → fail, baseline + medium-only → pass, and
  strict + medium → fail. The job fails if any exit code is wrong.
- **workflow-sanity** — runs `actionlint` (Docker) and `zizmor` (best-effort) as
  **advisory** linters; findings are logged, not gated, in this first iteration.

The meaningful logic lives in [`scripts/self-test.sh`](scripts/self-test.sh) so it
runs identically in CI and locally:

```sh
sh scripts/self-test.sh            # all: syntax + lifecycle + fallback + negative
sh scripts/self-test.sh fallback   # just the missing-summary fail-closed matrix
sh scripts/self-test.sh negative   # just the finding-bearing fail/pass matrix
```

**Why YAML validity is not enough.** A workflow can parse as valid YAML and still
mis-wire artifacts, mishandle exit codes, or accept the all-zero example. The
self-test proves the scripts actually behave — the part YAML linting can't see.

---

## 7. Example GitHub Actions usage

Copy the workflow templates from [`github/workflows`](github/workflows) into your
project's `.github/workflows/` directory and adjust as needed. Every template uses
minimal token permissions and pins third-party actions.

```yaml
# .github/workflows/ci-security.yml (excerpt)
name: ci-security
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

permissions:
  contents: read

jobs:
  security:
    uses: ./.github/workflows/ci-security.yml
```

> Note: examples in this repository use `master` as the default branch. Teams that
> use a different default branch should substitute their branch name.

---

## 8. Recommended rollout

1. Start in `report-only`. Make every existing issue visible.
2. Move to `baseline`. Stop the bleeding — new code must not add risk.
3. Burn down high-risk legacy findings with owners and expiry dates.
4. Move to `strict` once the backlog is controlled.
5. Move to `regulated` for systems that require audit evidence.

See [`docs/adoption-guide.md`](docs/adoption-guide.md) for the full five-phase plan.

---

## 9. Tooling matrix

| Domain | Tools |
| --- | --- |
| PHP static analysis | PHPStan, Larastan, Psalm, Psalm taint analysis |
| PHP style / refactor | PHP-CS-Fixer, Laravel Pint, Rector, PHPMD (optional) |
| PHP architecture | Deptrac |
| PHP supply chain | `composer audit` |
| Node / React | TypeScript strict, ESLint (+ security, no-unsanitized, react, react-hooks, jsx-a11y), Prettier, Knip |
| Node supply chain | `npm audit`, audit-ci |
| SAST | CodeQL, Semgrep |
| Secrets | Gitleaks, TruffleHog (optional) |
| Dependencies / SBOM | OWASP Dependency-Check, OSV-Scanner, Trivy, Syft, Grype |
| Posture | OpenSSF Scorecard, Dependabot |
| Docker / IaC | Hadolint, Trivy, Dockle (optional), Checkov, Terrascan (optional), OPA/Conftest |
| GitHub Actions | actionlint, zizmor, OpenSSF Scorecard, OPA/Conftest |
| Runtime / staging | OWASP ZAP baseline (PRs), ZAP full (nightly), Nuclei (optional, controlled) |
| AI-assisted review | Claude Code Security Review, Kuzushi (assistive only) |

---

## 10. Governance model

- **Security is a release requirement.** Gates are defined in
  [`RELEASE-GATES.md`](RELEASE-GATES.md) and enforced in CI.
- **Severity is decided by policy**, not by mood. See
  [`docs/severity-policy.md`](docs/severity-policy.md).
- **Exceptions are formal.** Every accepted risk needs an owner, reason, affected
  component, severity, expiry date, review date, mitigation, and approval. See
  [`docs/exception-policy.md`](docs/exception-policy.md).
- **High-risk changes require human approval** — authentication, payments,
  compliance, data access, cron jobs, and infrastructure.

---

## 11. AI-assisted review is not a gate

> **Important.** AI-assisted review (Claude Code Security Review, Kuzushi, and
> similar) is an assistive layer only. It must never be treated as a replacement
> for deterministic scanners or human approval.

The doctrine across this repository is explicit:

```txt
Deterministic scanners block unsafe code.
AI review explains, prioritizes, and assists remediation.
Humans approve high-risk changes.
```

---

## Example integration

[`examples/laravel-react-docker/`](examples/laravel-react-docker/) is a reference
integration package: the files Sentinel Shield adds to a Laravel + React + Docker
project (`.sentinel-shield/profile.yaml` in `report-only`, a combined CI workflow
that checks Sentinel Shield out into `tools/sentinel-shield`, `composer`/`npm`
`sentinel:*` scripts, a PHPUnit→`tests.json` normalizer, adoption + release-evidence
docs, and a migration plan from `report-only` → `baseline` → `strict` → `regulated`).
Copy and adapt it; see its [README](examples/laravel-react-docker/README.md).

## Contributing, changelog, make targets

- Contributions: [`CONTRIBUTING.md`](CONTRIBUTING.md) (shell standards, commit
  conventions, how to add gates/profiles/rules, local validation).
- History: [`CHANGELOG.md`](CHANGELOG.md).
- A `Makefile` wraps the scripts for convenience (the scripts remain runnable
  directly): `make help`, `make resolve`, `make enforce`, `make self-test`,
  `make validate`.

## License and provenance

Licensed under the MIT License — see [`LICENSE`](LICENSE). Update the copyright
holder to your organization on adoption.

Sentinel Shield (formerly the internal working name `zenchron-engineering-baseline`)
is intended to be adopted, forked, and tuned per organization. Treat every config
in this repository as a safe default to be reviewed, not as an untouchable rule.
