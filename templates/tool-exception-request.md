# Tool / Gate Exception Request

> For disabling or down-grading a scanner gate. Time-boxed + owner-approved. This is NOT for
> per-finding accepted-risks (see templates/accepted-risks.example.json + accepted-risk-suppression.md).

- **Gate / summary key:** e.g. style_violations, iac_violations
- **Scope:** whole gate (discouraged) | specific finding(s)
- **Reason:** …
- **Compensating control:** …
- **Owner (approves):** …
- **Requested / review-at / expires-at:** YYYY-MM-DD / YYYY-MM-DD / YYYY-MM-DD
- **Mode impact:** which modes (baseline/strict/regulated) this affects

Never request exceptions for `secrets`, `expired_exceptions`, or `missing_release_evidence`
— those are never suppressible.
