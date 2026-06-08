# AI Review Policy (v0.1.12)

AI-assisted review (Claude Code Security Review, Kuzushi) is **assistive,
non-deterministic, and NON-GATING by default** — even in `regulated` mode. Findings map to
`ai_review_findings`; the resolver keeps `fail_on.ai_review_findings: false` in all modes
unless the project profile explicitly overrides it to `true`.

## Why non-gating
AI output is non-reproducible and can hallucinate. It must not silently block or pass a
release. Treat it as triage input that a human confirms; confirmed issues become real
findings under the appropriate deterministic gate.

## Enabling (opt-in, deliberate)
- Run `sentinel-shield-ai-review.yml` (workflow_dispatch or the `ai-review` PR label).
- To make it gating (NOT recommended; regulated/high-assurance only):
  set `gates.fail_on.ai_review_findings: true` in `.sentinel-shield/profile.yaml`.
- Record results in [`templates/ai-security-review-report.md`](../templates/ai-security-review-report.md)
  / [`templates/kuzushi-investigation-report.md`](../templates/kuzushi-investigation-report.md).

Raw contract: `reports/raw/ai-security-review.json` / `kuzushi.json` =
`{"findings":[{"title","severity","file"}]}` or `{"findings": <int>}`. Missing → unavailable
(not fake-clean).
