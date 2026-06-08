# Workflow Template Validation (v0.1.13)

Validation of every workflow in `github/workflows/`, `templates/workflows/`, and
`examples/**`. Automated checks live in `scripts/self-test.sh workflow-sanity` (BLOCKING in
ci-self-test.yml).

## Automated (self-test workflow-sanity)
| Check | Result |
|---|---|
| No `pull_request_target:` trigger (comments OK) | ✓ PASS (0 triggers) |
| Every workflow declares `permissions:` | ✓ PASS |
| DAST template requires `SENTINEL_SHIELD_DAST_ALLOWED_HOST` + guarded runners | ✓ PASS |
| AI review template is NON-GATING (no active `fail_on.ai_review_findings: true`) | ✓ PASS |
| DAST template is workflow_dispatch-only (no `pull_request:`) | ✓ PASS |
| All YAML parses (ruby) | ✓ PASS |

## Manual review
| Item | Status | Notes |
|---|---|---|
| minimal permissions (`contents: read` default) | ✓ | CodeQL adds `security-events: write` (required) |
| no `pull_request_target` | ✓ | only in comments ("Do not use…") |
| third-party actions pinned | **partial** | ci-self-test.yml pinned; others tag + documented (pinned-tool-references.md) |
| required artifacts uploaded | ✓ | every job uploads `reports/**` or raw |
| release-gate downloads raw reports | ✓ | `download-artifact pattern: sentinel-shield-raw-security*` + `merge-multiple` |
| no fake reports | ✓ | collectors emit `unavailable` on missing input; never fabricate |
| safe when tools unavailable | ✓ | audit wrappers no-op when binary absent; collectors → unavailable |
| DAST safe | ✓ | fail-closed without target+allowlist |

## Known gaps
- Templates intentionally use **tag** refs for `uses:` readability → **must pin before production**
  (the GH Actions pin audit gate enforces this in a consumer).
- actionlint/zizmor on the templates remain **advisory** in ci-self-test (not blocking) until the
  templates are confirmed lint-clean against a pinned actionlint.
