# Accepted-Risk Suppression (v0.1.3+)

Sentinel Shield can suppress a **narrow, explicit** set of gate failures when a risk
has been formally accepted — owner-bound, with a reason and an expiry. This exists so
a team can knowingly accept a low-risk finding (e.g. a Docker hygiene warning) and
still ship under `baseline`, **without weakening enforcement or hiding the finding**.

> Accepted risks are **not** automatic suppressions. A Markdown draft does nothing.
> Only an **approved, unexpired, owner-bound** JSON record suppresses, and only for a
> **suppressible** gate. The raw finding count is preserved and the suppression is
> reported.

## The file

`scripts/enforce-gates.sh` reads (default) `.sentinel-shield/accepted-risks.json`
(override with `--accepted-risks <path>`). Template:
[`templates/accepted-risks.example.json`](../templates/accepted-risks.example.json);
schema: [`schemas/accepted-risks.schema.json`](../schemas/accepted-risks.schema.json).

```json
{
  "version": "1.0",
  "risks": [
    {
      "id": "dockerfile-apk-unpinned",
      "gate": "unsafe_docker",
      "owner": "platform-team",
      "severity": "medium",
      "reason": "Alpine package pinning is brittle for this image; reviewed as hygiene.",
      "mitigation": "Base image pinned; image scanned by Trivy; revisit later.",
      "expires_at": "2026-07-06",
      "status": "approved"
    }
  ]
}
```

## When a record suppresses

A record suppresses its gate **only if all** hold:

- `status == "approved"` — `pending`/`rejected`/`expired` never suppress.
- `expires_at >= today` (UTC) — expired records never suppress.
- `owner` is non-empty.
- `reason` is non-empty.
- `gate` is a **suppressible** gate.

## Suppressible vs. never-suppressible

| Suppressible (v0.1.3) | Never suppressible |
| --- | --- |
| `unsafe_docker` | `secrets` |
| `medium_vulnerabilities` | `expired_exceptions` |
| | `missing_release_evidence` |
| | `missing_sbom`, `critical_vulnerabilities`, `high_vulnerabilities`, `type_errors`, `test_failures`, `architecture_violations`, `unsafe_github_actions` |

Only `unsafe_docker` and `medium_vulnerabilities` are honored. A record targeting any
other gate is loaded but **ignored** (counted as "invalid"). **Secrets are never
suppressible.**

## What happens at enforcement

When a gate is enabled and its finding count is > 0:

- **No valid approved record** → the gate **fails** (exit 1) as usual.
- **Valid approved record for that gate** → the gate is marked **`accepted-risk`**:
  it does **not** fail, the **raw count is preserved (not zeroed)**, and it is
  reported. Overall result stays `pass` if nothing else failed.

This is transparent in both reports:

- `reports/sentinel-shield-enforcement.json` → `accepted_risks` object
  (`loaded`, `applied_gates`, `pending_ignored`, `expired_ignored`, `invalid_ignored`)
  and the gate's `result: "accepted-risk"` in `evaluated_gates`.
- `reports/sentinel-shield-enforcement.md` → an **Accepted risks** section listing
  applied gates + the risk id, plus pending/expired/invalid counts.

## Important caveats

- **Baseline adoption still requires human approval.** Setting `status: approved` is
  a deliberate, reviewed human action — Sentinel Shield never sets it.
- **Not all gates are suppressible** — only `unsafe_docker` and
  `medium_vulnerabilities` in v0.1.3. Do not expect this to clear critical/high vulns.
- **Findings are never hidden.** Counts remain; suppression is explicit and logged.
- Prefer **fixing** over accepting. Acceptance is a time-boxed bridge, not a resolution.
