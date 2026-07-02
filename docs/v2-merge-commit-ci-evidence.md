# v2 Merge-Commit CI Evidence

This document records the default-branch (`master`) CI evidence for merge commit
`becec20` (PR #11) in `bogdaniel/sentinel-shield`. This is the executable
release-source commit (`engine_commit`) for the v2 engine-only alpha/beta
candidates.

- **Repository:** `bogdaniel/sentinel-shield`
- **Default branch:** `master`
- **Commit under evaluation (M2 / `engine_commit`):** `becec20ed3890032d722a6118deee4a2314d39e9` (`becec20`), PR #11 merge commit
- **Event:** `push`
- **Overall conclusion:** all required workflows `success`
- **Verification method:** GitHub Actions REST API (run + artifact listing); selected artifacts additionally content-verified (download, JSON/Markdown parse, recorded commit == M2)
- **Verification timestamp:** `2026-07-02T15:47:25Z`

All runs below are the engine's own default-branch CI on this commit (`push`
event, `head_branch=master`). No `workflow_dispatch` runs were used — every
required workflow ran natively on the merge push, so no immutable-ref dispatch
was necessary. Run URLs follow the pattern:
`https://github.com/bogdaniel/sentinel-shield/actions/runs/<run_id>`

## FRAMEWORK LIVE-VALIDATION NOT INCLUDED

Laravel and Symfony profiles are engine-tested and fixture-tested, but were not
independently validated in real consumer repositories. This release cycle is
**engine-only**: the evidence proves the reusable engine via its own CI, not any
framework in a real adopter repository. `required_evidence.laravel` and
`required_evidence.symfony` remain `false`, `consumer_runs` is empty, and this
candidate **cannot** claim framework-validated / full-platform status.

## Important scope notes

- **Skipped jobs are applicability-gated, not failures.** Jobs marked skipped
  did not run because no matching root manifest / source type is present in this
  engine repository (no root `composer.json`, `package.json`, or `Dockerfile`;
  no compiled-language sources for CodeQL analysis; no root manifests for
  dependency-specific security jobs). This is the intended behavior of the
  detection gates.
- **This is engine CI, not consumer evidence.** These runs exercise the
  sentinel-shield engine itself. They are not real-consumer (adopter
  repository) runs and must not be presented as framework-validated consumer
  evidence.
- **Release scope for this cycle is engine-only.** Under the engine-only
  scope, Laravel/Symfony real-consumer runs are deferred and not required.

## Workflow evidence

### ci-self-test

| Field | Value |
| --- | --- |
| Run ID | `28602486289` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486289 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | negative-policy (success), lifecycle (success), syntax (success), full-self-test (success), fallback-policy (success), workflow-sanity (success) |
| Artifacts | sentinel-shield-self-test-reports (`8043879769`) |

### ci-pipeline

| Field | Value |
| --- | --- |
| Run ID | `28602486242` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486242 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | prepare (success), php-quality (success), node-quality (success), security-scan (success), docker-security (success), build-security-summary (success), release-gate (success) |
| Artifacts | sentinel-shield-release-evidence (`8043906487`), sentinel-shield-enforcement (`8043906070`), sentinel-shield-gate-resolution (`8043905688`), sentinel-shield-raw-security-merged (`8043900154`), sentinel-shield-security-summary (`8043899693`), sentinel-shield-sbom (`8043893732`), sentinel-shield-raw-security (`8043893409`), sentinel-shield-security-scan.spdx.json (`8043893092`) |

### ci-workflow-lint

| Field | Value |
| --- | --- |
| Run ID | `28602486282` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486282 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | workflow-lint (success) |
| Artifacts | none |

### ci-security

| Field | Value |
| --- | --- |
| Run ID | `28602486321` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486321 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | gitleaks (success), semgrep (success), detect-deps (success), security-summary (success), trivy-fs (success), osv-scanner (skipped — no root dependency manifests), sbom (skipped — no root dependency manifests) |
| Artifacts | sentinel-shield-security-summary (`8043893011`), sentinel-shield-raw-security (`8043892677`) |

### ci-codeql

| Field | Value |
| --- | --- |
| Run ID | `28602486310` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486310 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | detect (success), analyze (skipped — no applicable compiled-language source) |
| Artifacts | none |

### ci-php

| Field | Value |
| --- | --- |
| Run ID | `28602486497` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486497 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | detect (success), php (skipped — no root composer.json) |
| Artifacts | none |

### ci-node

| Field | Value |
| --- | --- |
| Run ID | `28602486248` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486248 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | detect (success), node (skipped — no root package.json) |
| Artifacts | none |

### ci-docker

| Field | Value |
| --- | --- |
| Run ID | `28602486231` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28602486231 |
| Event | `push` |
| Commit | `becec20` |
| Conclusion | `success` |
| Jobs | detect (success), docker (skipped — no root Dockerfile) |
| Artifacts | none |

## Applicability skips (summary)

All skips below are gated by presence detectors, are expected for the engine
repository, and do not represent failures:

| Workflow | Skipped job | Reason |
| --- | --- | --- |
| ci-php | php | no root `composer.json` |
| ci-node | node | no root `package.json` |
| ci-docker | docker | no root `Dockerfile` |
| ci-codeql | analyze | no applicable compiled-language source |
| ci-security | osv-scanner, sbom | no root dependency manifests |

Genuinely executed (not skipped) where required: Semgrep, Gitleaks, Trivy
filesystem, security-summary, self-tests, workflow-lint, and the release gate.

## Artifact verification method

- **Existence / provenance (all listed artifacts):** each declared artifact was
  fetched from the GitHub Actions API for its declared run
  (`repos/bogdaniel/sentinel-shield/actions/runs/<run_id>/artifacts`); the
  artifact `id` and `name` match and none are expired.
- **Content verification (key evidence artifacts):** downloaded, unzipped, and
  parsed —
  - `sentinel-shield-release-evidence` (`8043906487`, ci-pipeline): Markdown
    records `Commit: becec20…` and `Run: 28602486242`.
  - `sentinel-shield-security-summary` (`8043899693`, ci-pipeline):
    `source.commit == becec20…`, `source.branch == master`.
  - `sentinel-shield-security-summary` (`8043893011`, ci-security):
    `source.commit == becec20…`, `source.branch == master`.

  These confirm the release gate output and security summary correspond to M2.

## Known limitations

- **No framework live-validation.** See the disclosure above. Laravel/Symfony
  consumer validation is deferred (issues #19, #20); external adopter usability
  validation is deferred (#21).
- **Engine-only scope.** Language-specific pipelines (PHP/Node/Docker) and
  dependency/SBOM security jobs are applicability-skipped in the engine repo;
  they exercise real consumer repositories only under a framework-validated
  scope, which this candidate does not claim.
- **Candidates, not releases.** No `v2` tag is published (highest published tag
  is `v1.9.2`); these are candidates.

## Relationship to release evidence

This CI evidence backs the engine-only alpha/beta candidates recorded in:

- `evidence/releases/v2.0.0-alpha.1.json`
- `evidence/releases/v2.0.0-beta.1.json`

Both records set `engine_commit = becec20…` and (per the two-commit binding
model) `release_commit = engine_commit` — the tag targets the CI-validated
source commit directly. The evidence above can be GitHub-verified with:

```sh
sh scripts/validate-release-evidence.sh --verify-github
```
