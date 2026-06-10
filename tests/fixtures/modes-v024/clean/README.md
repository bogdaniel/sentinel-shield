# Fixture: clean (all gates pass)

A "nothing blocks" raw set. Used to prove that **report-only, baseline, strict, and
regulated all PASS** when there are no findings and all evidence is present.

## Contents

| File | Role |
| --- | --- |
| `gitleaks.json` (`[]`) | Empty secrets scan → `secrets=0`. An empty array is the canonical "clean" gitleaks output. |
| `sbom.spdx.json` | Present → `missing_sbom=false`. |
| `release-evidence.md` | Present → `missing_release_evidence=false`. |

## IMPORTANT — placement in the build output directory

`sbom.spdx.json` and `release-evidence.md` are **evidence artifacts**, not collector
inputs. `scripts/build-security-summary.sh` derives the evidence flags from their
**presence in the reports/output directory** (`<output-dir>/sbom.spdx.json` and
`<output-dir>/release-evidence.md`), *not* from a `reports/raw` collector input.

So when the self-test exercises this fixture, these two files MUST be copied into the
**same build output directory** that `build-security-summary.sh` reads (the `--output-dir`
/ reports dir), e.g.:

```sh
mkdir -p "$OUT"
cp tests/fixtures/modes-v024/clean/sbom.spdx.json       "$OUT/sbom.spdx.json"
cp tests/fixtures/modes-v024/clean/release-evidence.md  "$OUT/release-evidence.md"
# gitleaks.json goes to the raw inputs dir the secrets collector reads.
```

If they are left only here (in the fixture tree) and not placed in the output dir, the
builder will report `missing_sbom=true` / `missing_release_evidence=true` and the clean
scenario would falsely fail under regulated.

## Expected mapping

| Key | Value |
| --- | --- |
| `secrets` | 0 |
| `missing_sbom` | false |
| `missing_release_evidence` | false |

All four modes (report-only, baseline, strict, regulated) PASS on this set.
