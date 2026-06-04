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
