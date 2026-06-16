# AI Security Review Layer (v1.8.0 — A07)

Contract for using **Claude Code Security Review** and **Kuzushi** as **non-gating** review evidence.
AI review is **assistive, non-deterministic, and never blocks a release by default** — even in
`regulated` mode — unless a profile explicitly sets `gates.fail_on.ai_review_findings: true`. Builds
on [`ai-review-policy.md`](ai-review-policy.md).

## Scope & status

- **Non-gating** by default. Maps to `ai_review_findings`; advisory only.
- **Manual invocation** (operator-triggered), never on the PR-fast critical path.
- Output is a **review aid**, not a deterministic gate — re-runs may differ.

## Claude Code Security Review

- Run manually on a diff/PR; emits `ai-security-review.json` (findings = advisory).
- Treat findings as **prompts for human triage**, not verdicts. A human approves any action.

## Kuzushi (investigation aid)

- Investigation/triage assistant; **non-gating**; output is guidance, not a gate result.

## Prompt safety & data privacy

- **No secrets to the AI.** Never paste credentials, tokens, the NVD key, `.env`, or private keys.
- Send the **minimum** code context needed; respect data-classification policy.
- Do not send private customer data or regulated content to an external model without authorization.

## False positives & approval

- AI findings may be wrong. A **human reviewer approves** before any change.
- **No auto-remediation** — AI never edits code or opens fixes unattended.
- Nothing the AI says promotes a scanner's maturity or overrides a deterministic gate.

## Sample artifact schema (optional)

```json
{
  "tool": "claude-code-security-review",
  "status": "advisory",
  "ai_review_findings": 0,
  "findings": [
    { "title": "...", "severity_hint": "review", "location": "path:line", "rationale": "..." }
  ]
}
```

## Maturity caveat

AI review is **`non-gating`** in [`product-status.md`](product-status.md) /
[`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md) and stays that way in this release
(AI gating is **deferred** — see [`roadmap.md`](roadmap.md)). Guarded by `self-test`.
