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
| `default-branch-only` | Runs on default-branch `push` but is skipped on PRs by an event guard (`if: github.event_name != 'pull_request'`), not a detector; never runs on a PR, so do NOT require for PR merges. |

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

Applicability / detect checks:

- `ci-php` → `detect`
- `ci-node` → `detect`
- `ci-docker` → `detect`
- `ci-codeql` → `detect`

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
| `ci-codeql`          | `detect` (`applicability-detector`), `analyze` (`conditional-heavy`) |
| `ci-php`             | `detect` (`applicability-detector`), `php` (`conditional-heavy`) |
| `ci-node`            | `detect` (`applicability-detector`), `node` (`conditional-heavy`) |
| `ci-docker`          | `detect` (`applicability-detector`), `docker` (`conditional-heavy`) |
| `ci-release-gate`    | `gate` (`release-only`) |
| `ci-zap`             | `zap-baseline`, `zap-full` (both `scheduled-only`) |

> The `ci-workflow-lint` workflow now publishes three checks: `workflow-lint`
> (actionlint + zizmor), `workflow-runtime-audit` (runtime-hardening invariants),
> and `governance-audits` (required-checks drift + merge-safety). All three are
> `always-required`.

Note that several workflows (`ci-codeql`, `ci-php`, `ci-node`, `ci-docker`) share the
job name `detect`. GitHub distinguishes these check runs by their originating
workflow, which is why the recommended set above qualifies them as
`ci-<workflow>` → `detect`.
