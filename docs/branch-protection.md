# Branch Protection (advisory)

> **This document is advisory; do not change repository settings without explicit
> request.**

GitHub branch protection matches **job / check names**, not workflow **filenames**.
When you add a required status check, GitHub records the name of the *check run*,
which is the **job name** as it appears in the workflow (`jobs.<id>.name`, or the job
id when no name is set) — not the `.github/workflows/*.yml` filename. Configuring a
required check by filename will silently fail to match.

## Canonical registry & enforced drift/merge-safety gates

The stable check names below are recorded canonically in
[`config/required-checks.json`](../config/required-checks.json), and two
fail-closed gates in `ci-workflow-lint.yml` (job `governance-audits`) keep this
document honest:

- **`scripts/audits/required-checks-audit.sh`** parses the live `jobs.<id>.name`
  from every `.github/workflows/*.yml` and diffs it against the registry. A
  renamed, removed, duplicated, or newly-added-but-unregistered check fails CI —
  so a "required" status check can never silently stop matching. **When you rename
  or add a job, update `config/required-checks.json` AND the table below in the
  same change.**
- **`scripts/audits/merge-safety-audit.sh`** flags unsafe workflow patterns
  across the engine CI and the consumer templates: a privileged
  `pull_request_target` that checks out untrusted PR head code, a mutating
  `write` permission (or `write-all`) on a fork-reachable workflow, a custom
  secret exposed to fork PRs under `pull_request_target`, a mutable (non-SHA)
  action ref, and a publish/release step reachable from a `pull_request` event.

Each registry entry is **classified** so the intent of requiring (or not
requiring) it is explicit:

| Classification | Meaning |
|----------------|---------|
| `always-required` | Runs on every PR/push; safe to mark required on `master`. |
| `applicability-detector` | Lightweight `detect`/`prepare` gate deciding whether its heavy dependents run; require it so a check is present on every PR while heavy jobs may skip. |
| `conditional-heavy` | Heavy job gated behind a detector (`needs`/`if`); may legitimately skip, so do NOT require it by itself. |
| `scheduled-only` | Runs only via `schedule`/`workflow_dispatch`; never on ordinary PRs. Do NOT require. |
| `release-only` | Runs only on release refs (tags/dispatch); not on ordinary PRs. Do NOT require for PR merges. |
| `default-branch-only` | Runs on default-branch `push` (and manual `workflow_dispatch`) but is skipped on PRs by an event guard (`if: github.event_name != 'pull_request'`), not a detector; never runs on a PR, so do NOT require for PR merges. |

## Recommended required checks for `master`

Core gates:

- `full-self-test`
- `release-gate`
- `workflow-lint`
- `workflow-runtime-audit`
- `governance-audits`
- `semgrep`
- `gitleaks`
- `trivy-fs`
- `security-summary`

> ### ⚠️ REQUIRED SETTINGS CHANGE (audit)
>
> Four workflows used to publish a check named **`detect`**, and two published
> **`workflow-lint`**. Branch protection matches `required_status_checks` contexts **by NAME**,
> so a passing `detect` from `ci-docker` satisfied a requirement that the `detect` in
> `ci-codeql` never ran for — the gate rots open. (An earlier revision of this document
> asserted GitHub distinguishes them by originating workflow. It does not.)
>
> The jobs are now uniquely named: `detect-codeql`, `detect-php`, `detect-node`,
> `detect-docker`, and `workflow-lint-readiness`.
>
> **Anyone with branch protection configured must update the required-check list to the new
> names.** Until then the old contexts will never report and PRs may block. The drift audit
> (`scripts/audits/required-checks-audit.sh`) now fails on any cross-workflow duplicate.

Applicability / detect checks:

- `ci-php` → `detect-php`
- `ci-node` → `detect-node`
- `ci-docker` → `detect-docker`
- `ci-codeql` → `detect-codeql`

These `detect` jobs are the applicability gates that decide whether their heavy jobs
(php, node, docker, analyze) need to run for a given change. Requiring the `detect`
jobs keeps the gate present on every PR while allowing the heavy jobs to skip when a
change does not touch the relevant surface, so the required set stays satisfiable
without forcing unnecessary heavy work.

## Additional branch-protection settings

- Require branches to be up to date before merging.
- Require all review threads to be resolved.
- Block force pushes.
- Block branch deletion.
- Optionally require signed commits.

## Workflow file → job / check names

The following table maps each engine workflow file to the job / check names it
publishes, with each check's registry classification. Use the job names (not the
filenames) when configuring required checks. This table mirrors
[`config/required-checks.json`](../config/required-checks.json) and is enforced by
`required-checks-audit.sh`.

| Workflow file        | Job / check names (classification) |
|----------------------|-------------------|
| `ci-self-test`       | `full-self-test`, `syntax`, `lifecycle`, `fallback-policy`, `negative-policy`, `workflow-sanity` (all `always-required`) |
| `ci-pipeline`        | `prepare` (`applicability-detector`); `php-quality`, `node-quality`, `docker-security` (`conditional-heavy`); `security-scan`, `build-security-summary`, `release-gate` (`always-required`) |
| `ci-security`        | `detect-deps` (`applicability-detector`); `semgrep`, `gitleaks`, `trivy-fs`, `security-summary`, `security-acceptance` (`always-required`); `osv-scanner`, `sbom` (`conditional-heavy`); `security-acceptance-live` (`default-branch-only`) |
| `ci-workflow-lint`   | `workflow-lint`, `workflow-runtime-audit`, `governance-audits` (all `always-required`) |
| `ci-codeql`          | `detect-codeql` (`applicability-detector`), `analyze` (`conditional-heavy`) |
| `ci-php`             | `detect-php` (`applicability-detector`), `php` (`conditional-heavy`) |
| `ci-node`            | `detect-node` (`applicability-detector`), `node` (`conditional-heavy`) |
| `ci-docker`          | `detect-docker` (`applicability-detector`), `docker` (`conditional-heavy`) |
| `ci-release-gate`    | `gate` (`release-only`) |
| `ci-zap`             | `zap-baseline`, `zap-full` (both `scheduled-only`) |

> DAST (OWASP ZAP) runs via the `ci-zap` workflow — `scheduled-only`, so it
> publishes no required PR check: `zap-full` scans staging nightly and is SKIPPED
> until the `STAGING_URL` variable is set; `zap-baseline` runs only on manual
> dispatch. Never require either for PR merges. The consumer-project template
> `templates/workflows/sentinel-shield-dast.yml` remains the dispatch-only option
> for adopters. See [`dast-policy.md`](dast-policy.md).

> The `ci-workflow-lint` workflow now publishes three checks: `workflow-lint`
> (actionlint + zizmor), `workflow-runtime-audit` (runtime-hardening invariants),
> and `governance-audits` (required-checks drift + merge-safety). All three are
> `always-required`.

Those applicability gates used to share the job name `detect`, so a passing `detect`
from one workflow could satisfy a requirement meant for another. They are now uniquely
named per workflow — `detect-codeql`, `detect-php`, `detect-node`, `detect-docker` — and
`config/required-checks.json` is the source of truth for these context names. Require the
qualified names above; a bare `detect` no longer exists.
