# Mode gate fixtures

Executable `reports/raw`-style fixture inputs that the self-test enforces against the
mode-resolution truth table. Each fixture is a minimal scanner output that a Sentinel
Shield collector maps to exactly one summary count (or, for the evidence gate, a
documented *absence*). The mapping and the mode that should **FAIL** on each fixture are
derived from `scripts/resolve-gates.sh` — see the readiness matrix in
[`docs/gate-promotion-policy.md`](../../../docs/gate-promotion-policy.md).

## Fixture → gate → failing mode

| Fixture | Collector | Summary key (count) | Gate `fail_on.*` | Modes that FAIL on it |
| --- | --- | --- | --- | --- |
| `style-violation/php-style.json` | `collectors/php-style.sh` | `style_violations=2` | `style_violations` | **strict**, regulated |
| `iac-violation/checkov.json` | `collectors/checkov.sh` | `iac_violations=2` | `iac_violations` | **strict**, regulated |
| `medium-vuln/grype.json` | `collectors/grype.sh` | `medium_vulnerabilities=1` | `medium_vulnerabilities` | **strict**, regulated *(baseline-and-up tier: blocks at strict+; baseline leaves it advisory)* |
| `dast-finding/zap.json` | `collectors/zap.sh` | `dast_findings=1` | `dast_findings` | **regulated** only |
| `missing-release-evidence/` (no JSON) | `build-security-summary.sh` (absence of `release-evidence.md`) | `missing_release_evidence=true` | `missing_release_evidence` | **regulated** only |

> "Modes that FAIL" lists every mode whose default `fail_on.<key>` is `true` for that gate.
> The **bold** mode is the lowest tier at which the gate first becomes a hard blocker by
> default — the promotion boundary the self-test pins.

### Notes on the tiering

- **style / iac → strict.** Both are `false` in report-only and baseline and flip to `true`
  at strict (and stay `true` in regulated). The fixtures prove strict starts blocking them.
- **dast / missing-release-evidence → regulated.** Both stay `false` through strict and only
  flip to `true` in regulated. `missing_release_evidence` is intentionally **not** gated in
  strict (strict requires an SBOM but not the release-evidence note).
- **medium-vuln → baseline+ (strict).** `medium_vulnerabilities` is `false` in report-only
  **and baseline**, then `true` at strict and regulated. It is the canonical "tightens at
  strict" vuln-severity fixture. (Critical/high block from baseline; medium waits for strict.)

The authoritative per-mode booleans live in `default_for()` in
`scripts/resolve-gates.sh`; this table is a derived view, not a second source of truth.

## How to run a fixture

```sh
# Collector mapping (count > 0):
sh scripts/collectors/php-style.sh --input tests/fixtures/modes/style-violation/php-style.json | jq .summary.style_violations   # 2
sh scripts/collectors/grype.sh     --input tests/fixtures/modes/medium-vuln/grype.json        | jq .summary.medium_vulnerabilities # 1
sh scripts/collectors/checkov.sh   --input tests/fixtures/modes/iac-violation/checkov.json     | jq .summary.iac_violations        # 2
sh scripts/collectors/zap.sh       --input tests/fixtures/modes/dast-finding/zap.json          | jq .summary.dast_findings         # 1

# Confirm the mode that should block (resolved fail_on for the gate):
sh scripts/resolve-gates.sh --mode strict    --format json --output-dir /tmp/ss | jq '.fail_on.style_violations'        # true
sh scripts/resolve-gates.sh --mode baseline  --format json --output-dir /tmp/ss | jq '.fail_on.style_violations'        # false
sh scripts/resolve-gates.sh --mode regulated --format json --output-dir /tmp/ss | jq '.fail_on.dast_findings'           # true
sh scripts/resolve-gates.sh --mode strict    --format json --output-dir /tmp/ss | jq '.fail_on.dast_findings'           # false
```

The `missing-release-evidence/` case has **no JSON** by design — see its
[`README.md`](missing-release-evidence/README.md). It is driven by the absence of
`reports/release-evidence.md` (and `reports/sbom.spdx.json` for `missing_sbom`), computed by
`scripts/build-security-summary.sh`.
