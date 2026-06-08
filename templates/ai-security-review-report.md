# AI Security Review Report

> ASSISTIVE / NON-DETERMINISTIC / **NON-GATING by default**. See docs/ai-review-policy.md.

- **Project / commit:** …
- **Tool / model:** Claude Code Security Review (model, date)
- **Scope:** files/paths reviewed
- **Raw artifact:** `reports/raw/ai-security-review.json`

## Findings (human-triaged)
| # | Title | AI severity | File:line | Confirmed? | Action (real gate / accepted-risk / false-positive) |
|---|---|---|---|---|---|
| 1 | … | high | … | yes/no | … |

## Notes
AI findings are not a release gate unless `gates.fail_on.ai_review_findings: true` is set
explicitly. Confirmed issues must be reproduced under a deterministic gate before blocking.
