# Sentinel Shield — Release Gates

A release gate is a check that must pass before code is allowed to progress. This
document defines what is blocking, where, and per adoption mode. It is the
authoritative source for "is this allowed to ship?".

The aggregating workflow that enforces these gates is
[`github/workflows/ci-release-gate.yml`](github/workflows/ci-release-gate.yml).

---

## 0. Machine-readable gate resolution

The thresholds in this document are not just prose — they are resolved into concrete,
machine-readable values by [`scripts/resolve-gates.sh`](scripts/resolve-gates.sh),
which reads a project's `.sentinel-shield/profile.yaml`. Full details:
[`docs/gate-resolution.md`](docs/gate-resolution.md).

**Resolved outputs** (default directory `reports/`):

| File | Use |
| --- | --- |
| `sentinel-shield-gates.env` | Sourced by CI (`SENTINEL_SHIELD_FAIL_ON_*` keys) |
| `sentinel-shield-gates.json` | Programmatic consumers |
| `sentinel-shield-gates.md` | Human summary |

**Mode-to-threshold mapping** — the twelve `fail_on` gates resolve as follows
(`true` = blocks the build):

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| secrets | true | true | true | true |
| critical_vulnerabilities | false | true | true | true |
| high_vulnerabilities | false | true | true | true |
| medium_vulnerabilities | false | false | true | true |
| architecture_violations | false | true | true | true |
| type_errors | false | true | true | true |
| test_failures | false | true | true | true |
| unsafe_docker | false | true | true | true |
| unsafe_github_actions | false | true | true | true |
| missing_sbom | false | false | true | true |
| missing_release_evidence | false | false | false | true |
| expired_exceptions | true | true | true | true |

**Override rules.** Resolution order is: (1) mode defaults, (2) explicit
`gates.fail_on` overrides from the profile, (3) invalid values fail with a clear
error. Overrides are always reported, never hidden.

**Evidence expectations.** The release-gate workflow directly verifies the two
evidence-presence gates — `missing_sbom` (expects `reports/sbom.spdx.json`) and
`missing_release_evidence` (expects `reports/release-evidence.md`). Those file paths
are placeholders in the first version; wire real artifacts there. Scanner-result
gates are enforced by the dedicated workflows (`ci-security.yml`, `ci-php.yml`,
`ci-node.yml`, `ci-docker.yml`), not re-run by the release gate.

> The table below (§2) is the human-facing policy; the table above is what the
> resolver emits. They are kept consistent — `new-only` nuances in §2 are applied by
> the individual scanner workflows via baseline comparison, not by the resolver.

### Resolver vs. enforcer

Two separate, composable responsibilities:

| | Resolver | Enforcer |
| --- | --- | --- |
| Script | [`scripts/resolve-gates.sh`](scripts/resolve-gates.sh) | [`scripts/enforce-gates.sh`](scripts/enforce-gates.sh) |
| Input | `.sentinel-shield/profile.yaml` | `sentinel-shield-gates.env` + `security-summary.json` |
| Output | `sentinel-shield-gates.{env,json,md}` | `sentinel-shield-enforcement.{json,md}` + exit code |
| Question | *What should fail?* | *Does it actually fail?* |

**`security-summary.json` is the contract.** Scanner workflows normalize their
findings into one document with a required `summary` of 12 keys
([`docs/security-summary-schema.md`](docs/security-summary-schema.md)). The enforcer
maps each resolved `SENTINEL_SHIELD_FAIL_ON_*` flag onto its summary key:

| Flag | Fails when |
| --- | --- |
| `*_SECRETS` / `*_*_VULNERABILITIES` / `*_TYPE_ERRORS` / `*_TEST_FAILURES` / `*_ARCHITECTURE_VIOLATIONS` / `*_UNSAFE_DOCKER` / `*_UNSAFE_GITHUB_ACTIONS` | the matching `summary.<key> > 0` |
| `*_MISSING_SBOM` | `summary.missing_sbom == true` OR `evidence.sbom.present == false` |
| `*_MISSING_RELEASE_EVIDENCE` | `summary.missing_release_evidence == true` OR `evidence.release_evidence.present == false` |
| `*_EXPIRED_EXCEPTIONS` | `summary.expired_exceptions > 0` OR `exceptions.expired > 0` |

**Exit codes** (the enforcer's exit code is the release-gate result):

| Code | Meaning |
| --- | --- |
| 0 | all active gates pass |
| 1 | one or more active gates fail |
| 2 | configuration / input / parsing error (missing summary key, invalid JSON, missing `jq`, suspicious gates env line) |

**Accepted-risk suppression (v0.1.3+; finding-scoped v0.1.8).** An APPROVED, unexpired,
owner-bound record in `.sentinel-shield/accepted-risks.json` may suppress a
**suppressible** gate (`unsafe_docker`, `medium_vulnerabilities`): the gate is reported as
`accepted-risk` (raw count preserved, not zeroed) and does not fail. **v0.1.8:** records
are **finding-scoped by default** — for `unsafe_docker` a record matches `rule_id` +
`files` against `reports/raw/hadolint.json`, and the gate is `accepted-risk` only when
**every** finding is matched; **unaccepted findings still fail** (shown in the report).
Broad gate-wide suppression requires explicit `scope: gate` (reported as broad,
discouraged); a legacy record with no scope/rule_id/files no longer suppresses.
`pending`/expired/invalid records never suppress; `secrets`, `expired_exceptions`, and
`missing_release_evidence` are **never** suppressible. Baseline adoption still requires
the human `status: approved`. See
[`docs/accepted-risk-suppression.md`](docs/accepted-risk-suppression.md).

**Evidence requirements.** `missing_sbom` (strict/regulated) expects
`evidence.sbom.present == true` (path e.g. `reports/sbom.spdx.json`);
`missing_release_evidence` (regulated) expects `evidence.release_evidence.present
== true` (e.g. `reports/release-evidence.md`). A missing required `summary` key is
an error, never a silent zero. The gates `.env` is validated line-by-line and never
blind-sourced; JSON is parsed only with `jq`.

### Scanner normalization (producing the contract)

Between resolution and enforcement sits a normalization step that turns raw scanner
output into the contract. Responsibilities stay separate:

| Stage | Who | Output |
| --- | --- | --- |
| Run scanners | scanner workflows (`ci-security.yml`, `ci-php.yml`, …) | `reports/raw/*.json` |
| Parse one tool | `scripts/collectors/<tool>.sh` | a normalized per-tool object |
| Merge | `scripts/build-security-summary.sh` | `reports/security-summary.json` |
| Decide | `scripts/enforce-gates.sh` | pass/fail + exit code |

**Raw artifact contract:** each tool writes JSON to `reports/raw/<tool>.json`
(e.g. `gitleaks.json`, `semgrep.json`, `trivy.json`). Missing artifacts are
`unavailable` (counts 0) by default; `--strict-tools` / `--require-tool` make them
fatal (exit 1). The builder does **not** run scanners. **Enforcement begins only on
`security-summary.json`** — see [`docs/scanner-normalization.md`](docs/scanner-normalization.md).

**Hadolint (v0.1.7+):** `scripts/run-hadolint.sh` discovers and lints **all** Dockerfiles
(`Dockerfile`, `Dockerfile.*`, `docker/**`, `.docker/**`) and merges them into one
`reports/raw/hadolint.json` → `unsafe_docker`. No Dockerfiles → `unavailable`. Consuming
projects call the script rather than re-implementing per-Dockerfile logic.

**Semgrep scoping (v0.1.4+).** A project-local `.semgrepignore` (repo root; the
workflows run Semgrep with `-w /src`) keeps SAST on application source and off
vendored/generated assets. **SAST-only** — composer/npm audit, Trivy, Syft SBOM,
Gitleaks, and Hadolint are not narrowed. See [`docs/semgrep-scoping.md`](docs/semgrep-scoping.md).

**Third-party supply-chain gates (v0.1.5+; rules separated in v0.1.6).** Rule trees are
physically split — application SAST (`semgrep/app/`) can never load supply-chain rules
(`semgrep/supply-chain/third-party/`, high-confidence by default; broad heuristics
opt-in under `…/third-party-experimental/`). A separate scan over dependency code
feeds four gates — `third_party_suspicious_code`, `third_party_install_script_risk`,
`third_party_obfuscation`, `third_party_network_behavior`. Defaults: report-only &
baseline → all false (visible, non-blocking); strict → `install_script_risk` +
`network_behavior` true; regulated → all true. Findings stay in their own keys/artifact
and never mix into app `*_vulnerabilities`. See
[`docs/third-party-supply-chain-scan.md`](docs/third-party-supply-chain-scan.md).

**Node/React quality is gateable.** TypeScript (`type_errors`), ESLint
(`type_errors` / `medium_vulnerabilities` / `high_vulnerabilities`), and Node tests
(`test_failures`, via a Vitest/Jest → `tests.json` normalizer) now feed the same
gates. So a consuming project must wire Node test normalization (do not fake
`tests.json`) before moving to `baseline`, where `type_errors`, `test_failures`, and
`high_vulnerabilities` block. See [`docs/node-react-normalization.md`](docs/node-react-normalization.md).

### Security-summary artifact requirement

In CI, `security-summary.json` is passed as the `sentinel-shield-security-summary`
artifact. The release gate applies a **fallback policy** before enforcing
([`scripts/select-security-summary.sh`](scripts/select-security-summary.sh)):

| Mode | No real summary present |
| --- | --- |
| `report-only` | warn loudly, fall back to the all-zero example, continue |
| `baseline` | **fail** (exit 1) |
| `strict` | **fail** (exit 1) |
| `regulated` | **fail** (exit 1) |

> The all-zero example summary is **never** valid evidence in `baseline`/`strict`/
> `regulated`. "Real" = present, valid JSON, and not byte-identical to
> `templates/security-summary.example.json`, so the example cannot be dropped in to
> spoof a pass. This is fail-closed by design.

**Artifact trust model.** Artifacts are trusted only within the **same workflow
run** (`needs:` topology). Sentinel Shield ships no cross-run artifact discovery —
pulling artifacts from arbitrary/untrusted runs is a supply-chain risk. Cross-workflow
release gating must be wired by the consumer with a trusted strategy (commit SHA +
run ID + trusted branch + environment protection).

**Same-workflow vs cross-workflow.** Production should run the release gate in the
same workflow as the scanner jobs (so `download-artifact` finds the summary in-run).
The standalone `ci-release-gate.yml` is fail-closed: absent a real summary,
`baseline`/`strict`/`regulated` fail. See README "CI artifact handoff".

### Recommended production topology: the combined pipeline

[`github/workflows/ci-pipeline.yml`](github/workflows/ci-pipeline.yml) is the
canonical topology. Scanner/quality jobs, the summary build, and the release gate
run in **one workflow run**, wired with `needs:`; the
`sentinel-shield-security-summary` artifact is produced and consumed **in-run**:

```txt
prepare → { php-quality, node-quality, docker-security, security-scan }
        → build-security-summary → release-gate
```

**Why cross-workflow artifact discovery is not shipped.** `download-artifact` only
sees the current run. Reaching into other runs requires extra logic and is a
supply-chain risk (you could ingest artifacts from an untrusted run). Sentinel
Shield ships none. Same-run handoff is the safe, default answer; cross-workflow
gating is left to the consumer to wire with a trusted run-ID/branch/environment
strategy.

### Self-test before onboarding

Before integrating Sentinel Shield into a real project, the self-test
([`github/workflows/ci-self-test.yml`](github/workflows/ci-self-test.yml) /
[`scripts/self-test.sh`](scripts/self-test.sh)) must be green. It exercises the
full lifecycle on fixtures and, crucially, **asserts the fallback policy in CI**:
`report-only + missing → pass`, `baseline/strict/regulated + missing → fail`,
`copied example → fail`, `real summary → pass`. This proves the gates are
fail-closed before any production code depends on them.

**Finding-bearing cases are required too.** The `negative` self-test
(`sh scripts/self-test.sh negative`, run by the `negative-policy` job) proves real
findings drive enforcement — not just that clean fixtures pass: baseline + {high
vuln, secret, type errors, test failures, architecture violations} → fail, baseline
+ medium-only → pass, strict + medium → fail. These must pass before onboarding a
consuming project; a gate that never blocks is not a gate.

---

## 1. Gate stages

| Stage | When it runs | Purpose |
| --- | --- | --- |
| PR gate | On every pull request to `master` | Stop unsafe code entering the default branch |
| `master` branch gate | On push/merge to `master` | Protect the integration branch |
| Nightly gate | Scheduled | Deeper, slower scans (ZAP full, full Trivy, Scorecard) |
| Production release gate | On tag / release | Final evidence and approval before deploy |
| Emergency release | Out-of-band, documented | Controlled bypass with mandatory follow-up |

---

## 2. Blocking thresholds per mode

A ✅ means the condition **blocks** (fails the gate). A ⚠️ means **report only**.

| Condition | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| Leaked secret (Gitleaks) | ✅ | ✅ | ✅ | ✅ |
| Broken build | ✅ | ✅ | ✅ | ✅ |
| Catastrophic misconfiguration¹ | ✅ | ✅ | ✅ | ✅ |
| New critical vulnerability | ⚠️ | ✅ | ✅ | ✅ |
| New high vulnerability | ⚠️ | ✅ | ✅ | ✅ |
| Pre-existing critical/high | ⚠️ | ⚠️ (tracked) | ✅ | ✅ |
| New architecture violation (Deptrac) | ⚠️ | ✅ | ✅ | ✅ |
| Static-analysis failure (PHPStan/Psalm/tsc) | ⚠️ | ⚠️ new-only | ✅ | ✅ |
| Type errors | ⚠️ | ✅ new-only | ✅ | ✅ |
| Test failures | ✅² | ✅ | ✅ | ✅ |
| Unsafe Docker pattern | ⚠️ | ✅ new-only | ✅ | ✅ |
| Unsafe GitHub Actions pattern | ⚠️ | ✅ new-only | ✅ | ✅ |
| Missing SBOM | — | — | ⚠️ | ✅ |
| Missing release evidence | — | — | ⚠️ | ✅ |
| Exception without owner/expiry/approval | ⚠️ | ✅ | ✅ | ✅ |
| Missing rollback plan (high-risk change) | — | ⚠️ | ✅ | ✅ |
| Missing security review (high-risk change) | — | ⚠️ | ✅ | ✅ |

¹ Catastrophic misconfiguration: e.g. `APP_DEBUG=true` in a production config,
`0.0.0.0/0` SSH, public database, secrets in image layers.
² A broken test that prevents the suite from running is a broken build and blocks
even in `report-only`.

"new-only" means the gate compares against a baseline and blocks only on findings
introduced by the change, allowing tracked legacy debt to remain.

---

## 3. PR gates

Every pull request to `master` runs:

- Build / install from lockfile.
- Secret scan (Gitleaks) — blocking in all modes.
- Stack quality: PHPStan/Psalm or tsc + ESLint.
- Tests.
- Semgrep (stack rules).
- Dependency audit (`composer audit` / `npm audit` / OSV-Scanner).
- Architecture check (Deptrac) where configured.
- Docker lint (Hadolint) and GitHub Actions lint (actionlint/zizmor) when relevant
  files changed.

The PR description must use [`templates/pull-request-template.md`](templates/pull-request-template.md)
and declare risk level. High-risk PRs additionally require the security-review
template.

---

## 4. `master` branch gates

On merge to `master`:

- All PR-gate checks re-run on the merged result.
- Trivy filesystem scan.
- SBOM generation (Syft) — retained as an artifact; required to be present in
  `regulated`.
- Grype scan of the SBOM.

`master` may be intentionally red while a project proves compliance. This is by
design: a red `master` signals unresolved risk, not a process failure. It does not
authorise blind production deploys.

---

## 5. Nightly gates

Run on a schedule against a non-production environment:

- OWASP ZAP full scan against staging only (never production by default).
- Full Trivy image and filesystem scan.
- OpenSSF Scorecard.
- OSV-Scanner / Dependency-Check full run.

Nightly findings feed the burn-down backlog and severity triage.

---

## 6. Production release gates

Before a production deploy, the release gate verifies:

- All `master` gates green for the released commit.
- SBOM present and archived (`regulated`: mandatory).
- Release evidence present (`regulated`: mandatory) — see
  [`templates/production-readiness-report.md`](templates/production-readiness-report.md).
- All open exceptions for the release scope have owner, reason, expiry, and
  approval.
- Rollback plan documented for high-risk changes.
- Required security reviews completed for auth, payments, compliance, data access,
  cron jobs, and infrastructure changes.

If any required item is missing, the release gate fails.

---

## 7. Emergency release process

Emergencies (active incident, critical hotfix) may bypass non-safety gates, under
strict conditions:

1. An incident or change record is opened **before** the deploy.
2. A named owner authorises the bypass.
3. Safety gates are never bypassed: secret scan, broken build, and catastrophic
   misconfiguration still block.
4. A follow-up issue is created to restore full gate compliance within a stated
   window (default 48 hours; `regulated`: 24 hours).
5. The bypass is recorded as a time-boxed exception per
   [`docs/exception-policy.md`](docs/exception-policy.md).

Emergency bypass never silently disables gates in CI configuration. It is an
explicit, logged, owned action.

---

## 8. Rollback requirements

- Every production release has a known-good previous version to roll back to.
- Database migrations are backward-compatible or paired with a tested down-path.
- High-risk changes document the rollback procedure in the PR.
- The rollback path is verified, not assumed.

---

## 9. SBOM requirements

- SBOM generated with Syft in CycloneDX or SPDX format.
- Required and archived per release in `strict` (recommended) and `regulated`
  (mandatory).
- SBOM is scanned with Grype; new critical/high findings are triaged before release.

---

## 10. Accepted-risk requirements

An accepted risk is only valid with all of:

```txt
owner, reason, affected component, severity, expiry date, review date,
mitigation, approval
```

Use [`policies/exceptions/accepted-risk-template.md`](policies/exceptions/accepted-risk-template.md).
Expired exceptions re-activate the underlying gate and block the release.

---

## 11. Regulated mode requirements

In addition to everything in `strict`:

- SBOM is mandatory and archived per release.
- Release evidence (readiness report) is mandatory.
- Every exception is formal, owned, time-boxed, and approved.
- Security review is mandatory for auth, payments, compliance, data access, cron
  jobs, and infrastructure changes.
- A rollback plan is mandatory for the release.
- Audit logs and gate results are retained per the applicable compliance regime.
