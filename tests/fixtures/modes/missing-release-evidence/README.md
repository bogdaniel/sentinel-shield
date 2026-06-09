# Fixture: missing-release-evidence

**This scenario has no JSON fixture on purpose.** It is a *documented absence*, not a
scanner finding. The gate is driven by the **absence of evidence files in the raw reports
directory**, not by the content of any collector output.

## What triggers the gate

`scripts/build-security-summary.sh` derives two evidence flags from the reports directory
(see lines ~194-197):

- `missing_sbom = true`  when `<reports>/sbom.spdx.json` is **absent**
- `missing_release_evidence = true`  when `<reports>/release-evidence.md` is **absent**

So an **EMPTY raw dir** (a `reports/` with no `sbom.spdx.json` and no
`release-evidence.md`) yields:

```json
{ "summary": { "missing_sbom": true, "missing_release_evidence": true } }
```

## How the self-test should exercise it

1. Build a summary against a reports directory that contains **no** `sbom.spdx.json` and
   **no** `release-evidence.md` (the directory may contain unrelated collector output, or
   be empty of evidence files).
2. Assert `.summary.missing_release_evidence == true` (and `.summary.missing_sbom == true`).
3. Resolve gates in **regulated** mode and enforce: `missing_release_evidence` is a hard
   blocker only in regulated (see `../README.md` and the readiness matrix in
   `docs/gate-promotion-policy.md`).

## Why no JSON

Every other fixture in this tree is a `reports/raw`-style scanner input that a collector
maps to a summary count. This gate has no collector: it is computed by the summary builder
from the *presence/absence of evidence artifacts*. Shipping a JSON here would
misrepresent how the gate works. The correct fixture is the **lack of the evidence
files**, which this note documents.
