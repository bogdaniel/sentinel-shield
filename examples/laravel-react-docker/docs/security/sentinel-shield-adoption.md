# Sentinel Shield Adoption (Laravel + React + Docker)

This project uses [Sentinel Shield](https://example.com/sentinel-shield) — a hardened
engineering baseline for code, containers, CI, and infrastructure — to make security
a measurable release requirement. This page documents what was added, how to run it,
and how we tighten the gates over time.

> **Starting mode is `report-only`** (`.sentinel-shield/profile.yaml`). It collects
> findings without blocking development; only leaked secrets and expired exceptions
> block. We tighten to `baseline` → `strict` → `regulated` per the migration plan
> below.

---

## What was added

| Path | Purpose |
| --- | --- |
| `.sentinel-shield/profile.yaml` | Adoption mode + gate config (the policy) |
| `.github/workflows/sentinel-shield.yml` | CI pipeline (scan → build summary → enforce) |
| `composer.json` (`sentinel:*` scripts) | Produce PHP raw reports under `reports/raw/` |
| `package.json` (`sentinel:*` scripts) | Produce Node raw reports under `reports/raw/` |
| `scripts/sentinel/phpunit-to-tests-json.php` | Normalize PHPUnit JUnit → `reports/raw/tests.json` |
| `docs/security/release-evidence-template.md` | Release readiness evidence template |
| `reports/`, `reports/raw/` | Output dirs (generated files git-ignored) |

---

## Sentinel Shield source strategy: external checkout (Option B)

The CI workflow checks Sentinel Shield out into `tools/sentinel-shield` at a pinned
ref and calls its scripts from there. Set these in
`.github/workflows/sentinel-shield.yml`:

```yaml
env:
  SENTINEL_SHIELD_REPOSITORY: YOUR_ORG/sentinel-shield   # your Sentinel Shield repo
  SENTINEL_SHIELD_REF: v0.1.0                            # tag for first adoption; FULL SHA before production
  SENTINEL_SHIELD_PATH: tools/sentinel-shield
```

- If Sentinel Shield is **private**, add a read token/deploy key to the checkout
  steps (`token: ${{ secrets.SENTINEL_SHIELD_RO_TOKEN }}`).
- **Fallback (Option A):** if you cannot reach the repo from CI, vendor `scripts/`,
  `schemas/`, `templates/`, and `semgrep/` into this project and replace the
  `tools/sentinel-shield/...` paths. This is self-contained but drifts from upstream;
  re-sync periodically.

---

## How to run locally

```sh
# 1. Get Sentinel Shield scripts available (pinned clone, or symlink a local checkout).
git clone --depth 1 --branch v0.1.0 https://github.com/YOUR_ORG/sentinel-shield tools/sentinel-shield
# For production, check out a full commit SHA instead of the tag.

# 2. Produce raw reports (best-effort; missing tools are simply skipped).
mkdir -p reports/raw
composer run sentinel:quality || true       # PHP: audit, phpstan, psalm, deptrac, tests.json
npm run sentinel:quality || true            # Node: npm audit (+ advisory typecheck/lint)
# Docker/secrets scanners run in CI; locally you can run gitleaks/semgrep/trivy if installed.

# 3. Build → resolve → select → enforce.
sh tools/sentinel-shield/scripts/build-security-summary.sh \
  --project-name PROJECT_NAME_HERE --project-type laravel-react-docker \
  --criticality high --commit local --branch master --workflow local
sh tools/sentinel-shield/scripts/resolve-gates.sh --profile .sentinel-shield/profile.yaml --format all
sh tools/sentinel-shield/scripts/select-security-summary.sh
sh tools/sentinel-shield/scripts/enforce-gates.sh --format all
```

`enforce-gates.sh` exits `0` (pass) / `1` (fail) / `2` (config error).

---

## How CI works

`.github/workflows/sentinel-shield.yml` runs on `pull_request`, `push` to `master`,
and `workflow_dispatch`, with minimal `permissions: contents: read`. Topology:

```txt
prepare → { php-quality, node-quality, docker-security, security-scan }
        → build-security-summary → release-gate
```

- **prepare** resolves project metadata via Sentinel Shield's resolver.
- The four stack jobs run scanners/quality tools (best-effort) and upload
  `reports/raw/*.json` as per-stack artifacts. `security-scan` also produces the
  SPDX SBOM.
- **build-security-summary** downloads every raw artifact (+ SBOM) and builds the
  **real** `reports/security-summary.json` (the all-zero example is never used here).
- **release-gate** downloads the summary, resolves gates, applies the fallback
  policy, and enforces. Its exit code is the gate.

### Where raw reports are generated

`reports/raw/` — e.g. `gitleaks.json`, `semgrep.json`, `trivy.json`,
`composer-audit.json`, `phpstan.json`, `psalm.json`, `deptrac.json`, `tests.json`,
`hadolint.json`, `npm-audit.json`. Generated files are git-ignored; the directories
are kept via `.gitkeep`.

### How `security-summary.json` is produced

`build-security-summary.sh` runs Sentinel Shield's per-tool collectors over
`reports/raw/`, sums each finding count, sets evidence from file existence
(`reports/sbom.spdx.json`, `reports/release-evidence.md`), and writes a
schema-consistent `reports/security-summary.json`. Missing raw files ⇒ that tool is
`unavailable` (not faked).

### How gates are resolved

`resolve-gates.sh` reads `.sentinel-shield/profile.yaml`, applies the mode defaults,
layers any explicit `fail_on` overrides, and emits
`reports/sentinel-shield-gates.{env,json,md}`. `enforce-gates.sh` maps the
`SENTINEL_SHIELD_FAIL_ON_*` flags onto the summary counts.

### Required GitHub secrets

**None by default.** The pipeline needs no secrets. (Only add a read token if your
Sentinel Shield repo is private.)

### Action SHA pinning requirement

The workflow shows version tags for readability. **Pin every third-party action to a
verified commit SHA before relying on this in production** (supply-chain hardening).

---

## Why we start in report-only

A legacy codebase switched straight to `strict` produces a wall of findings, the
team disables the gate, and nothing improves. `report-only` makes findings visible
first, then we stop the bleeding (`baseline`), burn down debt, and tighten.

---

## Migration plan

### Phase 1 — `report-only` (now)

- **Duration:** first 1–2 weeks, or until the report is stable.
- **Blocks:** secrets and expired exceptions only.
- **Goal:** collect findings without blocking development; establish a baseline of
  current debt.

### Phase 2 — `baseline`

Set `gates.mode: baseline` in `.sentinel-shield/profile.yaml`.

- **Blocks:** secrets, critical/high vulnerabilities, type errors, test failures,
  architecture violations, unsafe Docker, unsafe GitHub Actions.
- **Goal:** prevent **new** high-risk issues. Track pre-existing critical/high as
  owned, time-boxed exceptions.

### Phase 3 — `strict`

Set `gates.mode: strict`.

- **Adds:** medium vulnerabilities and SBOM requirement (`missing_sbom`).
- **Goal:** production-grade release gate; the whole codebase meets the bar.

### Phase 4 — `regulated`

Set `gates.mode: regulated`.

- **Adds:** completed release-evidence requirement (`missing_release_evidence`).
- **Goal:** casino/compliance-heavy release readiness with auditable evidence.

### What blocks in each mode

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| secrets / expired exceptions | ✅ | ✅ | ✅ | ✅ |
| critical / high vulns | ❌ | ✅ | ✅ | ✅ |
| type errors / tests / architecture | ❌ | ✅ | ✅ | ✅ |
| unsafe Docker / GitHub Actions | ❌ | ✅ | ✅ | ✅ |
| medium vulns | ❌ | ❌ | ✅ | ✅ |
| missing SBOM | ❌ | ❌ | ✅ | ✅ |
| missing release evidence | ❌ | ❌ | ❌ | ✅ |

---

## Release evidence: two different things

1. **Project-provided release readiness evidence** — a human-completed document
   (`docs/security/release-evidence-template.md` → a filled copy) describing the
   release: scope, rollback, approvals. **Required in `regulated`** (the
   `missing_release_evidence` gate) and must exist before the gate runs.
2. **Sentinel Shield enforcement rollup** — the machine-generated
   `reports/release-evidence.md` the pipeline assembles from the resolved gates and
   enforcement result. This is produced by the workflow; it is *not* a substitute
   for the human readiness doc in `regulated` mode.

In `report-only`/`baseline` the pipeline can generate the rollup from the template if
none exists. In `regulated`, supply a real, completed readiness document.

---

## Node/React normalization (now available)

- **TypeScript and ESLint collectors now feed enforceable gates.**
  `sentinel:typescript` → `reports/raw/typescript.json` (`{errors:N}`) → `type_errors`.
  `sentinel:eslint` → native ESLint JSON → `type_errors` (errorCount),
  `medium_vulnerabilities` (warningCount), `high_vulnerabilities` (security severity-2).
  The ESLint security mapping is conservative and tunable — see
  [Sentinel Shield: node-react-normalization](https://example.com/sentinel-shield/docs/node-react-normalization.md).
- **Node test normalization is required before `baseline`.** Run your test runner
  with JSON output and normalize it to `reports/raw/tests.json` via
  `scripts/sentinel/vitest-to-tests-json.mjs` (`sentinel:test:node`). In `baseline`+,
  `test_failures` is gated. **Do not fake `tests.json`** — a missing report is an
  error, not "0 failures". Until the normalizer is wired, Node test failures stay
  `unavailable` and are not gated.

## First GitHub Runner Validation

Before trusting the gates, run the pipeline once on a real runner (use a throwaway
fixture repo). Step-by-step: [`github-fixture-run.md`](github-fixture-run.md);
preflight: [`github-preflight-checklist.md`](github-preflight-checklist.md).

**What should pass (report-only):** the overall release gate is **PASS** unless a
real secret or an expired exception is present. Only `secrets` and
`expired_exceptions` are active in `report-only`.

**What may warn (not fail):** `no composer.json` / `no package.json` / `no Docker
files` when a stack is absent; a scanner container that could not run; missing
optional tools. Warnings are expected and do not fail the build in report-only.

**Which artifacts must exist after a run:**
`sentinel-shield-security-summary`, `sentinel-shield-gate-resolution`,
`sentinel-shield-enforcement`, and `sentinel-shield-release-evidence`.
`sentinel-shield-raw-security` and `sentinel-shield-sbom` should exist from
`security-scan`. Per-stack raw artifacts exist **only** if that stack ran.

**Inspect `reports/security-summary.json`:**

```sh
jq '.summary' security-summary.json   # the 12 normalized counts/flags
jq '.tools'   security-summary.json   # per-tool status; "unavailable" = no raw produced
```

**Inspect `reports/sentinel-shield-enforcement.md`:** it lists each active gate and
whether it passed. In report-only, expect only `secrets`/`expired_exceptions` active
and `Overall result: PASS`.

**If the Sentinel Shield checkout fails:** verify `SENTINEL_SHIELD_REPOSITORY` and
`SENTINEL_SHIELD_REF` (the tag/SHA must exist); for a private Sentinel Shield repo,
add a read `token:` to the checkout steps. The job log shows the failing
`actions/checkout` step.

**If scanner containers fail:** Semgrep/Gitleaks run via Docker and are
`continue-on-error` — a container failure logs a warning and that tool becomes
`unavailable`; it does not fail report-only. Re-check the image
tags/pinning and runner network if you need that scanner.

**If npm/composer tools are missing:** the stack jobs are best-effort. A missing
tool simply does not write its raw report, and the builder marks it `unavailable`.
Install the tool (recommended dev dependencies above) when you want that signal —
do not fake the report.

## Semgrep scoping (v0.1.4+)

Semgrep scans **application code**, not vendored/generated assets. This example ships
a root [`.semgrepignore`](../../.semgrepignore) that excludes `vendor/`,
`node_modules/`, `storage/`, `bootstrap/cache/`, `public/js/filament/`,
`public/vendor/`, `public/build/`, and `tools/sentinel-shield/`; the workflow runs
Semgrep with `-w /src` so it is honored. `app/`, `Modules/`, and `resources/js` stay
scanned (React XSS rules included).

- **Laravel/Filament:** keep `public/js/filament/**` and `public/vendor/**` excluded
  (published vendor JS, not your code).
- **React:** also exclude `public/build/`, `dist/`, `build/`, `coverage/`.
- This is **SAST only** — `composer audit`, `npm audit`, Trivy, Syft (SBOM), and
  Gitleaks still scan dependencies/lockfiles/tree and are **not** narrowed by
  `.semgrepignore`. Tune Gitleaks only via its own `.gitleaks.toml`.
- To re-scan a path, remove its line from `.semgrepignore`; for a single false
  positive prefer a narrow `// nosemgrep: <rule-id> -- <reason>`. See the upstream
  `docs/semgrep-scoping.md`.

## Third-party suspicious-code scan (v0.1.5+; rule trees separated in v0.1.6)

A **separate** Semgrep channel scans dependency/vendored code (`vendor/`,
`node_modules/`, `public/vendor/`, `public/js/filament/`) with supply-chain rules
(`semgrep/supply-chain/third-party/`) into its own artifact
(`reports/raw/third-party-semgrep.json`) and its own summary keys (`third_party_*`). It
does **not** touch the normal app SAST scan (which configs from `semgrep/app/` and
cannot load third-party rules) and does **not** replace Trivy / composer audit / npm
audit / Gitleaks / SBOM (those still cover dependency CVEs and secrets).

- The workflow step runs only if a dependency dir exists; otherwise the collector
  marks the tool `unavailable`.
- **Default rules are high-confidence** (v0.1.6): npm install hooks + decode→eval. The
  broad/noisy heuristics (generic eval/require/child_process/network) are **opt-in** in
  `semgrep/supply-chain/third-party-experimental/` — add a second `--config` for a
  focused audit.
- **Non-blocking by default** (report-only/baseline). Strict blocks
  `install_script_risk` + `network_behavior`; regulated blocks all four.
- A triage aid, **not** a guarantee. Install-script findings (e.g. esbuild, puppeteer)
  are often legitimate — review, don't panic. The scan passing does **not** mean
  `node_modules` is clean.

See the upstream `docs/third-party-supply-chain-scan.md`.

## Docker linting — all Dockerfiles, globally (v0.1.7+)

The `docker-security` job checks out Sentinel Shield and runs
`scripts/run-hadolint.sh`, which discovers and lints **every** Dockerfile in the repo
(`Dockerfile`, `Dockerfile.*`, `docker/**`, `.docker/**`) and merges the results into one
`reports/raw/hadolint.json` → `unsafe_docker`. This replaces any project-local
multi-Dockerfile workaround.

> **Do not re-add custom Hadolint multi-file logic to this project's workflow.** That is
> now a global Sentinel Shield behavior — bump `SENTINEL_SHIELD_REF` to v0.1.7+ and call
> the script. Keep only **project-specific** Docker artifacts here: your Dockerfiles,
> your `hadolint.yaml`, and your **accepted-risk** records (below). Scanning more
> Dockerfiles can raise `unsafe_docker` — that is expected and visible, not hidden.

## Accepted-risk suppression (v0.1.3+)

For a Docker DL3018 or similar hygiene finding, **prefer fixing**. If you accept it
temporarily, a Markdown draft alone does **not** suppress the gate — create an
**approved** JSON record:

1. Copy `.sentinel-shield/accepted-risks.example.json` → `.sentinel-shield/accepted-risks.json`.
2. Set `gate` (only `unsafe_docker` / `medium_vulnerabilities` are suppressible),
   `owner`, `reason`, `expires_at` (≤ 90 days), and — after human review —
   `status: approved`.
3. The release gate reads it automatically (`enforce-gates.sh` default path) and
   marks the gate **accepted-risk** (count preserved, reported, does not fail).

**Finding-scoped by default (v0.1.8+).** Prefer a **finding-scoped** record — set
`scope: finding` (default) + `rule_id` + `files` so it suppresses **only** those
findings. For Docker, that usually means `rule_id` (e.g. `DL3018`) + the exact `files`
(`Dockerfile`, `Dockerfile.prod`). This is matched against `reports/raw/hadolint.json`,
so a DL3018 acceptance for `Dockerfile`/`Dockerfile.prod` will **not** hide unrelated
findings (e.g. `DL3008` in `docker/8.3/Dockerfile`) — those stay visible and fail until
fixed or separately accepted. Broad gate-wide suppression requires explicit
`scope: gate` and is **discouraged**; a legacy record with no scope/rule_id/files no
longer suppresses (it warns). Bump the file `version` to `"1.1"`.

`secrets`, `expired_exceptions`, and `missing_release_evidence` are **never**
suppressible; `pending`/expired records do not suppress. Finding-scope requires Sentinel
Shield **≥ v0.1.8** (suppression itself ≥ v0.1.3). See the upstream
`docs/accepted-risk-suppression.md`.

## Known missing adapters / tools

- Severity mappings in the collectors are conservative first-pass and may need
  tuning for this project's tools/versions (especially ESLint security severity).
- `knip` and other Node tools are not yet collected.
- This integration has **not** been executed on a GitHub runner yet; run it once and
  review real scanner output before trusting the gates.

## Use upstream adapters/runners (v0.1.9)

This example consumes Sentinel Shield-provided tooling rather than carrying local copies:

- **Tests:** produce a JUnit/JSON report, then convert with the adapters
  (`scripts/adapters/phpunit-to-tests-json.php`, `vitest-to-tests-json.mjs`,
  `jest-to-tests-json.mjs`) → `reports/raw/tests.json`.
- **Laravel PHPStan:** `scripts/runners/laravel-phpstan.sh` (no local CI-bootstrap copy).
- **GitHub Actions pins:** `scripts/audit-github-actions-pins.sh` → `unsafe_github_actions`.
- **Docker base digests:** `scripts/audit-docker-base-digest.sh` → `unsafe_docker`.

Keep project-specific items local: `.sentinel-shield/profile.yaml`,
`.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, Dockerfiles, and code
fixes. Generate `docs/security/*` from `templates/*.md`, then fill in. See
`docs/consolidation-v0.1.9.md` and `docs/remediation/`.
