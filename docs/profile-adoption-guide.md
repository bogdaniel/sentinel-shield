# Profile Adoption Guide (v0.1.24)

How to pick a Sentinel Shield profile, install it into a consuming project, and tighten the
gate mode over time — per stack. This guide is **adoption-facing** and complements the
mechanics in [`profile-driven-adoption.md`](profile-driven-adoption.md) and the
stack-compatibility matrix in [`profile-compatibility.md`](profile-compatibility.md).

> **Honesty / maturity.** The install/sync engine is `proven`; most scanner integrations are
> `supported`/`experimental`. The **single source of truth for maturity is**
> [`product-status.md`](product-status.md) — where any label here and that file disagree,
> `product-status.md` wins. **This is not a v1.0 product** and makes no v1.0 claim. Adopt in
> `report-only` first, pin tool refs ([`pinned-tool-references.md`](pinned-tool-references.md)),
> then tighten.

---

## 1. Manifest validation summary (tasks 61–64)

Every shipped profile manifest validates against the manifest JSON Schema
([`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json)): required
`profile` + `files`; each `files`/`workflows`/`docs` entry has exactly `source`, `target`,
`mode` (no extra keys); `mode` is one of `create-if-missing | overwrite-if-force |
sync-managed-block | manual`; `never_touch` / `required_scripts` / `recommended_raw_reports`
are string arrays. The repository self-test also asserts this (see `scripts/self-test.sh`
`v023-regression`, check "all profile manifests valid").

### 61–62 — Schema validation, actually run

Run from a Sentinel Shield checkout root:

```sh
SCHEMA=profiles/profile.manifest.schema.json
for m in profiles/*/profile.manifest.json profiles/combinations/*.manifest.json; do
  jq -e '
    def isentry: (type=="object")
      and (has("source") and (.source|type=="string") and (.source|length>0))
      and (has("target") and (.target|type=="string") and (.target|length>0))
      and (has("mode")   and (.mode|test("^(create-if-missing|overwrite-if-force|sync-managed-block|manual)$")))
      and (keys - ["source","target","mode"] | length == 0);
    def entrylist: (type=="array") and (all(.[]; isentry));
    [ (if (has("profile") and (.profile|type=="string") and (.profile|length>0)) then empty else "bad profile" end),
      (if (has("files") and (.files|entrylist)) then empty else "bad files[]" end),
      (if (has("workflows")|not) or (.workflows|entrylist) then empty else "bad workflows[]" end),
      (if (has("docs")|not) or (.docs|entrylist) then empty else "bad docs[]" end),
      (if (has("never_touch")|not) or ((.never_touch|type=="array") and all(.never_touch[];type=="string")) then empty else "bad never_touch[]" end),
      (if (has("required_scripts")|not) or ((.required_scripts|type=="array") and all(.required_scripts[];type=="string")) then empty else "bad required_scripts[]" end),
      (if (has("recommended_raw_reports")|not) or ((.recommended_raw_reports|type=="array") and all(.recommended_raw_reports[];type=="string")) then empty else "bad recommended_raw_reports[]" end)
    ] | if length==0 then "PASS \($m)" else "FAIL \($m): \(join("; "))" end
  ' -r "$m"
done
```

**Result (actually run, v0.1.24 sprint, 2026-06-10):**

```
PASS  profiles/docker/profile.manifest.json
PASS  profiles/laravel/profile.manifest.json
PASS  profiles/node/profile.manifest.json
PASS  profiles/php-library/profile.manifest.json
PASS  profiles/react/profile.manifest.json
PASS  profiles/symfony/profile.manifest.json
PASS  profiles/combinations/laravel-react-docker.manifest.json
PASS  profiles/combinations/node-react.manifest.json
```

8 / 8 manifests valid; exit 0. (No `ajv`/`check-jsonschema`/python-`jsonschema` is required —
the check encodes the schema's constraints in `jq`, matching what `self-test.sh` enforces in CI.)

### 63 — Existing docs this guide points to

These all exist (each verified with `[ -f ]`):

- [`profile-driven-adoption.md`](profile-driven-adoption.md) — install/sync mechanics, modes, safety.
- [`profile-compatibility.md`](profile-compatibility.md) — stack → profile mapping.
- [`install-sync-guide.md`](install-sync-guide.md) — install/sync productization, rollback, troubleshooting.
- [`gate-resolution.md`](gate-resolution.md) — how `mode` + `fail_on` resolve to enforced thresholds.
- [`raw-report-contract.md`](raw-report-contract.md) — raw-report names/shape collectors expect.
- [`strict-mode-readiness.md`](strict-mode-readiness.md), [`regulated-mode-readiness.md`](regulated-mode-readiness.md) — pre-flight before tightening.
- [`dast-policy.md`](dast-policy.md), [`ai-review-policy.md`](ai-review-policy.md) — DAST manual/fail-closed, AI non-gating.
- [`pinned-tool-references.md`](pinned-tool-references.md) — pinning tool images/actions.
- [`product-status.md`](product-status.md) — maturity source of truth.

### 64 — Workflow templates + raw-report expectations

Profiles reference workflow templates under `templates/workflows/` (each exists):

| Template | Role |
| --- | --- |
| [`sentinel-shield.yml`](../templates/workflows/sentinel-shield.yml) | Combined workflow (default install target) |
| [`sentinel-shield-pr-fast.yml`](../templates/workflows/sentinel-shield-pr-fast.yml) | PR-fast gate (`proven`) |
| [`sentinel-shield-main.yml`](../templates/workflows/sentinel-shield-main.yml) | Main-branch deep gate (`supported`, partial) |
| [`sentinel-shield-scheduled.yml`](../templates/workflows/sentinel-shield-scheduled.yml) | Nightly/scheduled scan (`template-only`) |
| [`sentinel-shield-dependency-check.yml`](../templates/workflows/sentinel-shield-dependency-check.yml) | OWASP Dependency-Check evidence (attempted, not live-validated) |
| [`sentinel-shield-dast.yml`](../templates/workflows/sentinel-shield-dast.yml) | DAST (`manual`, fail-closed) |
| [`sentinel-shield-ai-review.yml`](../templates/workflows/sentinel-shield-ai-review.yml) | AI review (`non-gating`) |

**Raw-report expectations exist:** every manifest declares `recommended_raw_reports`, the
JSON filenames the pipeline drops in the raw dir for `build-security-summary.sh` to normalize.
These are **informational** (the scripts live in Sentinel Shield, not copied) and follow the
shapes in [`raw-report-contract.md`](raw-report-contract.md). Per profile:

| Profile | `recommended_raw_reports` |
| --- | --- |
| symfony | `php-syntax.json, phpstan.json, psalm.json, deptrac.json, php-style.json, tests.json, composer-audit.json, gitleaks.json, semgrep.json` |
| laravel | `phpstan.json, tests.json, composer-audit.json, gitleaks.json, semgrep.json, deptrac.json` |
| node | `npm-audit.json, tests.json, gitleaks.json, semgrep.json` |
| react | `npm-audit.json, tests.json, typescript.json, eslint.json, gitleaks.json, semgrep.json` |
| docker | `hadolint.json, docker-base-digest.json, trivy.json, checkov.json, dockle.json, gitleaks.json, semgrep.json` |
| php-library | `php-syntax.json, phpstan.json, tests.json, composer-audit.json, gitleaks.json, semgrep.json` |
| node-react | `npm-audit.json, tests.json, typescript.json, eslint.json, gitleaks.json, semgrep.json` |
| laravel-react-docker | core 14 + main-gate set (codeql, osv-scanner, grype, dependency-check, checkov, dockle, scorecard, trufflehog, sbom.spdx.json, …) |

---

## 65 — Profile support matrix

Eight manifests ship (six single-stack + two combinations). "Install command" uses
`scripts/install-baseline.sh --profile <name>`.

| Profile (`--profile`) | Manifest | Stacks | Project-local config installed | Combination? |
| --- | --- | --- | --- | --- |
| `symfony` | `profiles/symfony/profile.manifest.json` | symfony, php | `.semgrepignore`; phpstan/psalm/deptrac/php-cs-fixer/rector = **manual** | no |
| `laravel` | `profiles/laravel/profile.manifest.json` | laravel | `.semgrepignore`; `phpstan.neon` = manual | no |
| `node` | `profiles/node/profile.manifest.json` | node | (none beyond profile.yaml/accepted-risks example) | no |
| `react` | `profiles/react/profile.manifest.json` | react, node | `.semgrepignore` | no |
| `docker` | `profiles/docker/profile.manifest.json` | docker | `hadolint.yaml` (create-if-missing) | no |
| `php-library` | `profiles/php-library/profile.manifest.json` | php | `.semgrepignore` (no Laravel/Docker assumptions) | no |
| `node-react` | `profiles/combinations/node-react.manifest.json` | node, react | `.semgrepignore` | **yes** |
| `laravel-react-docker` | `profiles/combinations/laravel-react-docker.manifest.json` | laravel, react, node, docker | `.semgrepignore` + full doc set + split workflows | **yes (default)** |

All eight install `.sentinel-shield/profile.yaml` (create-if-missing) and
`.sentinel-shield/accepted-risks.example.json`, and ship the combined
`.github/workflows/sentinel-shield.yml` (overwrite-if-force). All hard-protect
`.sentinel-shield/accepted-risks.json` (PHP profiles also protect `phpstan.neon` /
`phpstan-baseline.neon`). For the stack → profile selection logic see
[`profile-compatibility.md`](profile-compatibility.md).

---

## 66 — Maturity labels per profile

Drawn from [`product-status.md`](product-status.md) §3 ("Profile system … `supported`";
"Install / sync engine (laravel-react-docker) … `proven`"). The **engine** that installs a
profile is `proven`; an individual profile's *adoption maturity* reflects whether it has a full
fixture round-trip and/or a cited live consumer run.

| Profile | Adoption maturity | Basis (per `product-status.md`) |
| --- | --- | --- |
| `laravel-react-docker` | `proven` (install/sync) | Self-test `install-sync` + `fixtures` round-trip; zenchron pilot consumer |
| `laravel` | `supported` | Manifest + dry-run; PR-fast scanners live-validated on zenchron, but no full standalone round-trip |
| `symfony` | `supported` | Manifest + v0.1.23 install fixture; not yet a cited live consumer run |
| `react` | `supported` | Manifest + dry-run |
| `node` | `supported` | Manifest + dry-run |
| `node-react` | `supported` | Combination manifest (v0.1.22); no standalone live consumer run |
| `php-library` | `supported` | Manifest (v0.1.16); generic PHPStan, no framework runner |
| `docker` | `supported` (container scanners `experimental`) | Manifest + dry-run; Trivy-image/Checkov/Dockle severity is best-effort |

> The maturity of the **scanners** a profile recommends is separate and per-tool — see
> [`product-status.md`](product-status.md) §3–§6 and
> [`production-readiness-audit.md`](production-readiness-audit.md). E.g. Gitleaks/Semgrep/PHPStan/
> Trivy-fs are `proven`; OSV/CodeQL/Grype severity is coarse (`experimental`); OWASP
> Dependency-Check is **attempted, not live-validated**; DAST is `manual`; AI review is `non-gating`.

---

## 67–71 — Per-profile adoption guides

Each: **install command → what gets created → recommended tools → manual steps.** Run
`install-baseline.sh` from a Sentinel Shield checkout, targeting your project. Dry-run is the
default; add `--apply` to write. Mode defaults to `report-only` — start there.

### 67 — Symfony (`--profile symfony`)

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile symfony            # dry-run
sh scripts/install-baseline.sh --target /path/to/project --profile symfony --apply --mode report-only
```

**What gets created** (project-owned after install): `.sentinel-shield/profile.yaml`,
`.sentinel-shield/accepted-risks.example.json`, `.semgrepignore`,
`docs/security/security-debt-register.md`. **Managed:** `.github/workflows/sentinel-shield.yml`.

**Recommended tools** (from manifest):
- PR-fast: `php-syntax, phpstan, psalm, php-style, composer-audit, gitleaks, semgrep, tests`
- Main-gate: `codeql, osv-scanner, trivy-fs, syft, grype, deptrac, dependency-check`
- Scheduled: `trufflehog, scorecard, dependency-check, grype-fs`

**Manual steps** (mode `manual` — never auto-written; installer prints them): copy
`profiles/symfony/{phpstan.neon, psalm.xml, deptrac.yaml, php-cs-fixer.php → .php-cs-fixer.dist.php,
rector.php}` into the project and adjust paths (Symfony app code lives in `src/`). Then set
project metadata in `profile.yaml`, pin tool refs, and run a `report-only` PR before tightening.
`phpstan.neon` / `phpstan-baseline.neon` are **never** overwritten by Sentinel Shield.

### 68 — Laravel (`--profile laravel`)

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile laravel --apply --mode report-only
```

**What gets created:** `.sentinel-shield/profile.yaml`, `accepted-risks.example.json`,
`.semgrepignore`, `docs/security/security-debt-register.md`; managed
`.github/workflows/sentinel-shield.yml`.

**Recommended tools:**
- PR-fast: `php-syntax, phpstan, composer-audit, gitleaks, semgrep, tests`
- Main-gate: `codeql, osv-scanner, trivy-fs, syft, grype, deptrac, dependency-check`
- Scheduled: `trufflehog, scorecard, dependency-check, grype-fs`

**Manual steps:** copy `profiles/laravel/phpstan.neon` (Larastan) into the project (mode
`manual`); PHPStan runs via the upstream `scripts/runners/laravel-phpstan.sh`. `phpstan.neon`
and `phpstan-baseline.neon` are project-local and never overwritten.

### 69 — Node + React (`--profile node-react`)

Use the combination for a Vite SPA + Node tooling in one repo.

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile node-react --apply --mode report-only
```

**What gets created:** `.sentinel-shield/profile.yaml`, `accepted-risks.example.json`,
`.semgrepignore` (excludes `build/`/`dist/`), `docs/security/security-debt-register.md`;
managed `.github/workflows/sentinel-shield.yml`.

**Recommended tools:**
- PR-fast: `npm-audit, eslint, typescript, gitleaks, semgrep, tests`
- Main-gate: `codeql, osv-scanner, trivy-fs, syft, grype, dependency-check`
- Scheduled: `trufflehog, scorecard, dependency-check, grype-fs`

**Manual steps:** `tsconfig`/`eslint` config stay project-local (not installed) — keep your own.
The Vitest/Jest adapters and ESLint/TypeScript runners are called from Sentinel Shield. For a
pure Node service or pure React SPA you may instead use `--profile node` or `--profile react`.

### 70 — Docker-only (`--profile docker`)

For repos that ship **only** containers/IaC, no application language. If the repo also ships
app code, pair Docker with an app profile (or use `laravel-react-docker`).

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile docker --apply --mode report-only
```

**What gets created:** `.sentinel-shield/profile.yaml`, `accepted-risks.example.json`,
`hadolint.yaml` (create-if-missing), `docs/security/pinned-ci-references.md`; managed
`.github/workflows/sentinel-shield.yml`.

**Recommended tools:**
- PR-fast: `hadolint, docker-base-digest, gitleaks, semgrep`
- Main-gate: `trivy-fs, trivy-image, syft, grype, checkov`
- Scheduled: `trufflehog, scorecard, dockle, grype-fs`

**Manual steps:** keep Dockerfiles project-local; multi-Dockerfile Hadolint + base-image digest
audit run from Sentinel Shield (`scripts/run-hadolint.sh`, `scripts/audit-docker-base-digest.sh`).
Container-image scanners (Trivy-image/Checkov/Dockle) are `experimental` — treat severities as
review prompts and pin scanner images by digest ([`pinned-tool-references.md`](pinned-tool-references.md)).

### 71 — PHP library (`--profile php-library`)

Plain PHP package, no framework.

```sh
sh scripts/install-baseline.sh --target /path/to/project --profile php-library --apply --mode report-only
```

**What gets created:** `.sentinel-shield/profile.yaml`, `accepted-risks.example.json`,
`.semgrepignore`, `docs/security/security-debt-register.md`; managed
`.github/workflows/sentinel-shield.yml`.

**Recommended tools:**
- PR-fast: `php-syntax, phpstan, composer-audit, gitleaks, semgrep, tests`
- Main-gate: `codeql, osv-scanner, trivy-fs, syft, grype, dependency-check`
- Scheduled: `trufflehog, scorecard, dependency-check, grype-fs`

**Manual steps:** PHPStan is **generic** (not Larastan) — supply your own `phpstan.neon` tuned
to the library; it is never overwritten. No Docker or Laravel-runner assumptions apply.

---

## 72 — Profile selection decision tree

Pick the smallest profile that covers what the repo actually ships. See
[`profile-compatibility.md`](profile-compatibility.md) for the full stack table.

```
START: what does the repository ship?
│
├─ Ships application code AND containers/IaC in one repo?
│    └─ Laravel + React (Vite) + Docker?         → laravel-react-docker  (default; proven install/sync)
│       else app + Docker (other stacks)         → app profile now; add docker assets manually
│                                                   (no other combination manifest ships yet)
│
├─ PHP application?
│    ├─ Laravel framework                         → laravel
│    ├─ Symfony 6/7 (app code in src/)            → symfony   (copy manual config files)
│    └─ Plain library, no framework               → php-library
│
├─ JavaScript / TypeScript?
│    ├─ React (Vite) SPA only                     → react
│    ├─ Node service only                         → node
│    └─ Node + React in one repo                  → node-react
│
└─ Containers / IaC ONLY (no app language)        → docker
       (if app code is also present, do NOT use docker alone —
        use an app profile or laravel-react-docker)

THEN (every path):
  1. Install with --mode report-only (dry-run first, then --apply).
  2. Pin tool refs (pinned-tool-references.md) and wire the PR-fast gate (proven).
  3. Fill in .sentinel-shield/profile.yaml metadata; complete any manual config copies.
  4. Move report-only → baseline once new code stops adding risk.
  5. strict → regulated only after the readiness pre-flights
     (strict-mode-readiness.md / regulated-mode-readiness.md). Keep DAST manual, AI non-gating.
```

For the YAML override scenarios behind each mode (and DAST / AI opt-ins), see the example
`profile.yaml` files in [`examples/profiles/`](examples/profiles/) and the resolver behaviour in
[`gate-resolution.md`](gate-resolution.md).
