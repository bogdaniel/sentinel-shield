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
  SS_REPO: YOUR_ORG/sentinel-shield   # your Sentinel Shield repo
  SS_REF: v0.1.0                      # pin to a tag or full commit SHA
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
# 1. Get Sentinel Shield scripts available (clone next to the project, or vendor).
git clone <SS_REPO> tools/sentinel-shield   # or symlink your local checkout

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

## Known missing adapters / tools

- Severity mappings in the collectors are conservative first-pass and may need
  tuning for this project's tools/versions (especially ESLint security severity).
- `knip` and other Node tools are not yet collected.
- This integration has **not** been executed on a GitHub runner yet; run it once and
  review real scanner output before trusting the gates.
