# v0.1.9 Consolidation — promoting pilot lessons upstream

`zenchron-tools` was the **pilot consumer** and validation fixture for Sentinel Shield.
During that rollout we implemented several reusable pieces directly in the project to
validate them quickly. v0.1.9 promotes the reusable ones **into Sentinel Shield** so
consuming projects use profiles/scripts instead of duplicating logic.

## Ownership model (corrected)

| Sentinel Shield owns | Consuming project owns |
| --- | --- |
| scanner runners, adapters, collectors | `.sentinel-shield/profile.yaml` |
| profile defaults, workflow templates | `.sentinel-shield/accepted-risks.json` |
| security docs / remediation guides | project code fixes |
| governance templates | project-specific baselines (e.g. `phpstan-baseline.neon`) |
| audits/detectors (pins, base digests) | project-specific risk decisions |

## Classification of the pilot items

Legend: **A** executable capability · **B** reusable template · **C** doc/remediation guide
· **D** project-specific only (do NOT move).

| # | Item | Class | Where it now lives (v0.1.9) |
| --- | --- | --- | --- |
| 1 | PHPUnit → tests.json adapter | A | `scripts/adapters/phpunit-to-tests-json.php` |
| 2 | Vitest → tests.json adapter | A | `scripts/adapters/vitest-to-tests-json.mjs` |
| 3 | Jest → tests.json adapter | A | `scripts/adapters/jest-to-tests-json.mjs` |
| 4 | Laravel PHPStan/Larastan CI runner | A | `scripts/runners/laravel-phpstan.sh` |
| 5 | GitHub Actions pin auditing | A | `scripts/audit-github-actions-pins.sh` + `scripts/collectors/github-actions-pins.sh` → `unsafe_github_actions` |
| 6 | Docker base-image digest detection | A | `scripts/audit-docker-base-digest.sh` + `scripts/collectors/docker-base-digest.sh` → `unsafe_docker` |
| 7 | Dockerfile.prod / multi-Dockerfile coverage | A | already shipped v0.1.7 (`scripts/run-hadolint.sh`); profiles/example use it |
| 8 | React `dangerouslySetInnerHTML` remediation | C | `docs/remediation/react-dangerously-set-inner-html.md` |
| 9 | DOMPurify remediation | C | folded into guide #8 (sanitizer pattern) |
| 10 | PHPStan debt baseline strategy | C | `docs/remediation/phpstan-baseline-strategy.md` |
| 11 | Docker DL3018 decision tree | C | `docs/remediation/docker-dl3018-decision-tree.md` |
| 12 | Browser-stack isolation | C | `docs/remediation/browser-stack-isolation.md` |
| 13 | Third-party install-script review | B+C | `templates/third-party-install-script-review.md` + `docs/remediation/third-party-install-script-review.md` |
| 14 | Security debt register | B | `templates/security-debt-register.md` |
| 15 | Rollout-status | B | `templates/sentinel-shield-rollout-status.md` |
| 16 | Project triage report | B | `templates/security-triage-report.md` |
| — | GitHub Actions SHA pinning guide | C | `docs/remediation/github-actions-sha-pinning.md` |
| — | Docker base digest pinning guide | C | `docs/remediation/docker-base-digest-pinning.md` |
| — | Pinned CI references | B | `templates/pinned-ci-references.md` |

### Class D — stays in the consuming project (NOT moved)
- The **accepted-risk decisions** themselves (which DL3018/DL3008 findings a team accepts,
  with owner/reason/expiry) — project governance, not product logic.
- The project's **PHPStan baseline file** and its error count.
- Project **Dockerfiles**, `hadolint.yaml`, and any code fixes (e.g. the actual DOMPurify
  call sites).
- Project **profile.yaml** mode and `fail_on` choices.

> Honesty: promoting these capabilities does **not** move a project's debt or risk
> decisions upstream. Consuming projects still own — and must keep making — their own
> accepted-risk decisions and remediation.
