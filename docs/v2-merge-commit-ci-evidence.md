# v2 Merge-Commit CI Evidence

This document records the default-branch (`master`) CI evidence for merge commit
`8bd33a9` (PR #4) in `bogdaniel/sentinel-shield`.

- **Repository:** `bogdaniel/sentinel-shield`
- **Default branch:** `master`
- **Commit under evaluation:** `8bd33a91343603434026408aded2de0142989159` (`8bd33a9`), PR #4
- **Event:** `push`
- **Overall conclusion:** all workflows `success`

All runs below are the engine's own default-branch CI on this commit. Run URLs
follow the pattern:
`https://github.com/bogdaniel/sentinel-shield/actions/runs/<run_id>`

## Important scope notes

- **Skipped jobs are applicability-gated, not failures.** Jobs marked skipped
  did not run because no matching file types changed in this commit (for
  example, no compiled-language sources for CodeQL analysis, no PHP/Node/Docker
  changes for the respective language pipelines). This is the intended
  behavior of the detection gates.
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
| Run ID | `28542231786` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231786 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | full-self-test (success), workflow-sanity (success), lifecycle (success), fallback-policy (success), negative-policy (success), syntax (success) |
| Artifacts | sentinel-shield-self-test-reports (`8020375110`) |

### ci-pipeline

| Field | Value |
| --- | --- |
| Run ID | `28542231713` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231713 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | prepare (success), security-scan (success), node-quality (success), php-quality (success), docker-security (success), build-security-summary (success), release-gate (success) |
| Artifacts | sentinel-shield-release-evidence (`8020393036`), sentinel-shield-enforcement (`8020392827`), sentinel-shield-gate-resolution (`8020392618`), sentinel-shield-raw-security-merged (`8020389354`), sentinel-shield-security-summary (`8020389107`), sentinel-shield-sbom (`8020386118`), sentinel-shield-raw-security (`8020385894`), sentinel-shield-security-scan.spdx.json (`8020385723`) |

### ci-workflow-lint

| Field | Value |
| --- | --- |
| Run ID | `28542231729` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231729 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | workflow-lint (success) |
| Artifacts | none |

### ci-security

| Field | Value |
| --- | --- |
| Run ID | `28542231769` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231769 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | detect-deps (success), security-summary (success), semgrep (success), trivy-fs (success), gitleaks (success), sbom (skipped), osv-scanner (skipped) |
| Artifacts | sentinel-shield-security-summary (`8020383400`), sentinel-shield-raw-security (`8020383135`) |

### ci-codeql

| Field | Value |
| --- | --- |
| Run ID | `28542231970` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231970 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | detect (success), analyze (skipped — no compiled-language changes) |
| Artifacts | none |

### ci-php

| Field | Value |
| --- | --- |
| Run ID | `28542231759` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231759 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | detect (success), php (skipped) |
| Artifacts | none |

### ci-node

| Field | Value |
| --- | --- |
| Run ID | `28542231767` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542231767 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | detect (success), node (skipped) |
| Artifacts | none |

### ci-docker

| Field | Value |
| --- | --- |
| Run ID | `28542232206` |
| Run URL | https://github.com/bogdaniel/sentinel-shield/actions/runs/28542232206 |
| Event | `push` |
| Commit | `8bd33a9` |
| Conclusion | `success` |
| Jobs | detect (success), docker (skipped) |
| Artifacts | none |

## Relationship to release evidence

This CI evidence backs the engine-only alpha/beta candidates recorded in:

- `evidence/releases/v2.0.0-alpha.1.json`
- `evidence/releases/v2.0.0-beta.1.json`

Note: no `v2` tag is published (the highest published tag is `v1.9.2`); these
are candidates, not releases. The evidence above can be GitHub-verified with:

```sh
sh scripts/validate-release-evidence.sh --verify-github
```
