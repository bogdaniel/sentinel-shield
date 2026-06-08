# Adoption Guide

Sentinel Shield is adopted in phases. Do not attempt to switch a legacy project
straight to `strict` — it will produce an unmanageable wall of findings and the team
will disable the gates. Adopt visibility first, then stop new risk, then burn down,
then tighten.

The four adoption modes (`report-only`, `baseline`, `strict`, `regulated`) map onto
five phases.

---

## Phase 1 — Visibility (`report-only`)

**Goal:** know the truth. Nothing blocks except safety gates.

- Add the scanners and run them in CI.
- CI fails only on leaked secrets, broken builds, or catastrophic misconfiguration.
- Generate the baseline report (`scripts/generate-report.sh`) and store it.
- Record the current finding counts as the project baseline.

Exit criteria: scanners run on every PR; the team can see current debt.

---

## Phase 2 — New-code gates (`baseline`)

**Goal:** stop the bleeding. Existing debt is tolerated; new risk is not.

- New critical/high vulnerabilities fail CI.
- New secrets fail CI.
- New architecture violations fail CI.
- Static-analysis and type errors fail CI for changed code (baseline comparison).
- Pre-existing findings are tracked as accepted risks with owners and expiry dates.

Exit criteria: no new high-risk findings merge; legacy debt is inventoried and
owned.

---

## Phase 3 — High-risk cleanup

**Goal:** burn down the dangerous legacy findings.

- Triage the baseline by severity ([`severity-policy.md`](severity-policy.md)).
- Assign owners and expiry dates to critical/high items.
- Track progress; revisit expired exceptions.
- Keep `baseline` gates on throughout so the backlog only shrinks.

Exit criteria: no unaddressed critical/high legacy findings; medium/low have a plan.

---

## Phase 4 — Strict mode (`strict`)

**Goal:** the whole codebase meets the bar, not just new code.

- Critical/high vulnerabilities fail CI regardless of age.
- Static-analysis failures, test failures, architecture, Docker, and Actions
  violations all block.
- The baseline-comparison allowance is removed.

Exit criteria: a clean run is achievable on demand; gates are stable.

---

## Phase 5 — Regulated mode (`regulated`)

**Goal:** auditable evidence for compliance-heavy systems.

- Everything from `strict`, plus:
- SBOM is generated and archived per release.
- Release evidence is required ([`templates/production-readiness-report.md`](../templates/production-readiness-report.md)).
- Exceptions are formal: owner, reason, expiry, approval.
- Security review is mandatory for auth, payments, compliance, data access, cron
  jobs, and infrastructure.
- A rollback plan is required per release.

Exit criteria: a release can be defended to an auditor from artifacts alone.

---

## Setting the mode

The mode lives in `.sentinel-shield/profile.yaml`:

```yaml
gates:
  mode: baseline   # report-only | baseline | strict | regulated
```

Change it deliberately, with team agreement, and only move forward when the exit
criteria for the current phase are met. Moving backward (e.g. `strict` → `baseline`)
is allowed during an incident but must be recorded and time-boxed.

After every mode change, run the resolver to confirm what CI will enforce:

```sh
sh scripts/resolve-gates.sh        # writes reports/sentinel-shield-gates.{env,json,md}
```

See [`gate-resolution.md`](gate-resolution.md) for the full mode→threshold mapping.

---

## Switching modes in practice

### Start with `report-only`

```yaml
gates:
  mode: report-only
```

Only `secrets` and `expired_exceptions` block. Everything else is reported. This is
the safe entry point for any legacy project — scanners run, nothing else breaks the
build. Capture the current finding counts as your baseline.

### Switch to `baseline`

```yaml
gates:
  mode: baseline
```

Now `critical_vulnerabilities`, `high_vulnerabilities`, `architecture_violations`,
`type_errors`, `test_failures`, `unsafe_docker`, and `unsafe_github_actions` block —
for **new** issues (the individual scanner workflows apply baseline comparison).
`medium_vulnerabilities` and the SBOM/evidence gates stay off. Track pre-existing
critical/high as owned, time-boxed exceptions.

### Promote to `strict`

```yaml
gates:
  mode: strict
```

Adds `medium_vulnerabilities` and `missing_sbom`. The whole codebase must meet the
bar, not just new code — remove the baseline-comparison allowance in the scanner
workflows. Do this only when a clean run is achievable on demand.

### `regulated` and evidence requirements

```yaml
gates:
  mode: regulated
```

Everything in `strict` plus `missing_release_evidence`. The release gate now
**requires** evidence artifacts to be present:

- `reports/sbom.spdx.json` (SBOM) — also required in `strict`.
- `reports/release-evidence.md` (readiness report) — required only in `regulated`.

These paths are placeholders in the first version; wire your real artifacts there.
In `regulated` mode, exceptions must be formal (owner, reason, expiry, approval) and
security review is mandatory for auth, payments, compliance, data access, cron jobs,
and infrastructure changes.

### Per-gate overrides

You can override a single gate without changing mode — useful for a controlled,
documented exception to the mode's default:

```yaml
gates:
  mode: strict
  fail_on:
    medium_vulnerabilities: false   # reported as an explicit override
```

The resolver prints the override and records it in the artifacts. Use this sparingly
and pair it with an exception record where it weakens a gate.

---

## Common mistakes

- **Starting strict.** Produces noise, gets disabled. Start `report-only`.
- **No owners on legacy debt.** Untracked debt never shrinks. Assign owners + expiry.
- **Treating AI review as a gate.** It is assistive only — deterministic scanners
  block, humans approve high-risk changes.
- **Silently disabling a gate.** Use a formal, time-boxed exception instead.

## Reusable adapters & runners (v0.1.9)

Consuming projects should call Sentinel Shield's scripts rather than re-implementing them:

- **Tests → `reports/raw/tests.json`:** `scripts/adapters/phpunit-to-tests-json.php`
  (JUnit XML), `scripts/adapters/vitest-to-tests-json.mjs`,
  `scripts/adapters/jest-to-tests-json.mjs`.
- **Laravel PHPStan:** `scripts/runners/laravel-phpstan.sh` (handles Laravel CI bootstrap;
  marks the tool unavailable rather than faking clean when PHPStan is absent).
- **Audits:** `scripts/audit-github-actions-pins.sh`, `scripts/audit-docker-base-digest.sh`.

Project-specific items stay local: `profile.yaml`, `accepted-risks.json`, baselines, code
fixes. See [`consolidation-v0.1.9.md`](consolidation-v0.1.9.md) and `docs/remediation/`.

## Profile-driven install/sync (v0.1.11)

Instead of hand-copying the workflow from `examples/`, install from a profile manifest:

```sh
sh scripts/install-baseline.sh --target <project> --apply            # profile laravel-react-docker, mode report-only
sh scripts/install-baseline.sh --target <project> --profile laravel --mode baseline --apply
sh scripts/sync-baseline.sh    --target <project> --apply --force    # update managed files later
```

Installs `.sentinel-shield/profile.yaml`, `accepted-risks.example.json`, `.semgrepignore`,
the managed `.github/workflows/sentinel-shield.yml`, and security doc templates. It NEVER
creates/overwrites `accepted-risks.json` or `phpstan-baseline.neon`. Full model +
manifest format: [`profile-driven-adoption.md`](profile-driven-adoption.md). Supported
profiles in v0.1.11: laravel, react, node, docker, laravel-react-docker.

## v0.1.12 enterprise scanner matrix

New gated summary keys (style_violations, php_syntax_errors, dependency_policy_violations,
iac_violations, dast_findings, container_image_violations, repository_health_warnings,
ai_review_findings) with conservative mode defaults; DAST manual + fail-closed; AI review
assistive + non-gating by default. See [`docs/enterprise-scanner-matrix.md`](docs/enterprise-scanner-matrix.md).
