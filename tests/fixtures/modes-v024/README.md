# Mode gate fixtures — v0.1.24 (strict / regulated execution)

Executable `reports/raw`-style fixture inputs (plus two documented *absences* and two
evidence artifacts) that the v0.1.24 enforcement self-tests run against the
mode-resolution truth table. Each collector input maps to exactly one summary count; the
mode that should **FAIL** on each is derived from `default_for()` in
[`scripts/resolve-gates.sh`](../../../scripts/resolve-gates.sh).

This set is the **execution** counterpart to the single-gate fixtures in
[`../modes/`](../modes/README.md): it adds a *combined* multi-violation set, an all-clean
set, and a repository-health fixture, to exercise pass/fail end-to-end per mode.

See also: [`docs/strict-regulated-execution.md`](../../../docs/strict-regulated-execution.md),
[`docs/strict-mode-readiness.md`](../../../docs/strict-mode-readiness.md),
[`docs/regulated-mode-readiness.md`](../../../docs/regulated-mode-readiness.md),
[`docs/gate-promotion-policy.md`](../../../docs/gate-promotion-policy.md).

## Fixture → gate → mode that fails

| Fixture | Collector / source | Summary key (count) | Gate `fail_on.*` | Lowest mode that FAILS |
| --- | --- | --- | --- | --- |
| `multi-violation/php-style.json` | `collectors/php-style.sh` | `style_violations=3` | `style_violations` | **strict** (also regulated) |
| `multi-violation/grype.json` | `collectors/grype.sh` | `medium_vulnerabilities=2` | `medium_vulnerabilities` | **strict** (also regulated) |
| `multi-violation/checkov.json` | `collectors/checkov.sh` | `iac_violations=3` | `iac_violations` | **strict** (also regulated) |
| `clean/gitleaks.json` (`[]`) | `collectors/gitleaks.sh` | `secrets=0` | `secrets` | none (all modes PASS) |
| `clean/sbom.spdx.json` | `build-security-summary.sh` (presence) | `missing_sbom=false` | `missing_sbom` | none (all modes PASS) |
| `clean/release-evidence.md` | `build-security-summary.sh` (presence) | `missing_release_evidence=false` | `missing_release_evidence` | none (all modes PASS) |
| `dast-finding/zap.json` | `collectors/zap.sh` | `dast_findings=2` | `dast_findings` | **regulated** only |
| `missing-release-evidence/` (no JSON) | `build-security-summary.sh` (absence) | `missing_release_evidence=true` | `missing_release_evidence` | **regulated** only |
| `repo-health/scorecard.json` | `collectors/scorecard.sh` | `repository_health_warnings=1` | `repository_health_warnings` | **regulated** only |

> "Lowest mode that FAILS" is the first tier whose default `fail_on.<key>` is `true`. The
> authoritative per-mode booleans live in `default_for()` in `scripts/resolve-gates.sh`;
> this table is a derived view, not a second source of truth.

## Expected pass/fail per mode (whole fixture set)

| Fixture set | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| `multi-violation/` (style+medium+iac) | PASS | PASS | **FAIL** | **FAIL** |
| `clean/` (no findings, evidence present) | PASS | PASS | PASS | PASS |
| `dast-finding/` | PASS | PASS | PASS | **FAIL** |
| `missing-release-evidence/` | PASS | PASS | PASS | **FAIL** |
| `repo-health/` | PASS | PASS | PASS | **FAIL** |

baseline does NOT block style / iac / medium-vuln — only strict promotes those. dast,
missing-release-evidence, and repository-health are regulated-only.

## Verified collector mappings (run in worktree root)

```
php-style → style_violations           = 3   # multi-violation/php-style.json
grype     → medium_vulnerabilities      = 2   # multi-violation/grype.json
checkov   → iac_violations              = 3   # multi-violation/checkov.json
gitleaks  → secrets                     = 0   # clean/gitleaks.json ([])
zap       → dast_findings               = 2   # dast-finding/zap.json  (riskcode>=2: the 3 and the 2; the 1 is excluded)
scorecard → repository_health_warnings  = 1   # repo-health/scorecard.json (Branch-Protection score=2; score<0 excluded)
```

Reproduce:

```sh
sh scripts/collectors/php-style.sh --input tests/fixtures/modes-v024/multi-violation/php-style.json | jq .summary.style_violations            # 3
sh scripts/collectors/grype.sh     --input tests/fixtures/modes-v024/multi-violation/grype.json     | jq .summary.medium_vulnerabilities      # 2
sh scripts/collectors/checkov.sh   --input tests/fixtures/modes-v024/multi-violation/checkov.json   | jq .summary.iac_violations              # 3
sh scripts/collectors/gitleaks.sh  --input tests/fixtures/modes-v024/clean/gitleaks.json            | jq .summary.secrets                     # 0
sh scripts/collectors/zap.sh       --input tests/fixtures/modes-v024/dast-finding/zap.json          | jq .summary.dast_findings               # 2
sh scripts/collectors/scorecard.sh --input tests/fixtures/modes-v024/repo-health/scorecard.json     | jq .summary.repository_health_warnings  # 1
```

## Notes on the two non-JSON / evidence cases

- `clean/sbom.spdx.json` and `clean/release-evidence.md` are **evidence artifacts**. They
  must be placed in the **build output directory** that `build-security-summary.sh` reads
  (not the `reports/raw` collector inputs dir). See [`clean/README.md`](clean/README.md).
- `missing-release-evidence/` ships **no JSON by design**: the gate fires on the
  *absence* of `release-evidence.md` in the output dir. See
  [`missing-release-evidence/README.md`](missing-release-evidence/README.md).
