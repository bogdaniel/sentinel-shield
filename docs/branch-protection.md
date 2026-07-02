# Branch Protection (advisory)

> **This document is advisory; do not change repository settings without explicit
> request.**

GitHub branch protection matches **job / check names**, not workflow **filenames**.
When you add a required status check, GitHub records the name of the *check run*,
which is the **job name** as it appears in the workflow (`jobs.<id>.name`, or the job
id when no name is set) — not the `.github/workflows/*.yml` filename. Configuring a
required check by filename will silently fail to match.

## Recommended required checks for `master`

Core gates:

- `full-self-test`
- `release-gate`
- `workflow-lint`
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
publishes. Use the job names (not the filenames) when configuring required checks.

| Workflow file        | Job / check names |
|----------------------|-------------------|
| `ci-self-test`       | `full-self-test`, `syntax`, `lifecycle`, `fallback-policy`, `negative-policy`, `workflow-sanity` |
| `ci-pipeline`        | `prepare`, `php-quality`, `node-quality`, `docker-security`, `security-scan`, `build-security-summary`, `release-gate` |
| `ci-security`        | `detect-deps`, `semgrep`, `gitleaks`, `osv-scanner`, `trivy-fs`, `sbom`, `security-summary` |
| `ci-workflow-lint`   | `workflow-lint` |
| `ci-codeql`          | `detect`, `analyze` |
| `ci-php`             | `detect`, `php` |
| `ci-node`            | `detect`, `node` |
| `ci-docker`          | `detect`, `docker` |
| `ci-release-gate`    | `gate` |
| `ci-zap`             | `zap-baseline`, `zap-full` |

Note that several workflows (`ci-codeql`, `ci-php`, `ci-node`, `ci-docker`) share the
job name `detect`. GitHub distinguishes these check runs by their originating
workflow, which is why the recommended set above qualifies them as
`ci-<workflow>` → `detect`.
