# IaC Finding Triage (v0.1.14)

For Checkov/Conftest/Terrascan findings (→ `iac_violations`).
1. **Classify**: real misconfig vs framework default vs false positive.
2. **Fix in IaC** (tighten the resource/policy) — preferred.
3. **Suppress narrowly** at the tool level (inline ignore with justification) only when a false positive.
4. **Exception**: time-boxed, owner-approved via [`templates/iac-exception-request.md`](../../templates/iac-exception-request.md).
5. Re-run; confirm `iac_violations` drops. Do not disable the whole tool to go green.
