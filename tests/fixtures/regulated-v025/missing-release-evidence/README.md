# Fixture: missing-release-evidence (regulated-only)

**This scenario has no JSON or evidence fixture on purpose.** It is a *documented
absence*, not a scanner finding. The gate is driven by the **absence of an evidence file
in the build output directory**, not by the content of any collector output.

There is deliberately **no `sbom.spdx.json` and no `release-evidence.md` present** in this
directory: an empty output dir is exactly what reproduces the regulated-only
`missing_release_evidence=true` condition.

## What triggers the gate

`scripts/build-security-summary.sh` derives the evidence flags from the reports/output
directory (see ~lines 194-197):

```
RELEASE_PATH="$REPORTS_DIR/release-evidence.md"
if [ -f "$RELEASE_PATH" ]; then RP=true; MR=false; else RP=false; MR=true; fi
```

So a build output directory that contains **no** `release-evidence.md` yields:

```json
{ "summary": { "missing_release_evidence": true } }
```

The flag is purely **presence/absence** of the file — content is never inspected. An empty
output dir (or one with unrelated collector output but no `release-evidence.md`) is the
correct way to reproduce `missing_release_evidence=true`.

## How the self-test should exercise it

1. Build a summary against an output directory that contains **no** `release-evidence.md`.
2. Assert `.summary.missing_release_evidence == true`.
3. Resolve gates and enforce:
   - **regulated** → `fail_on.missing_release_evidence = true` → build **FAILS**.
   - **strict** → `fail_on.missing_release_evidence = false` → build **PASSES** (strict
     requires an SBOM but intentionally does *not* require the release-evidence note).
   - **baseline / report-only** → `false` → PASS.

This is the regulated-only counterpart to the `clean/` fixture, which ships a
`release-evidence.md` so the same gate resolves clean.

## Why no JSON

This gate has no collector: it is computed by the summary builder from the
presence/absence of evidence artifacts. Shipping a JSON here would misrepresent how the
gate works. The correct fixture is the **lack of the evidence file**, which this note
documents.
