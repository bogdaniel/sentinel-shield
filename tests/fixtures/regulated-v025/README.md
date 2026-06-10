# Regulated-mode dry-run fixtures — v0.1.25

Executable `reports/raw`-style fixture inputs (plus two documented *absences* and two
evidence artifacts) for the **regulated dry-run**. They focus on the three gates that are
**regulated-only** — i.e. the gates whose default `fail_on.*` is `true` **only** in
`regulated` and `false` in `strict`/`baseline`/`report-only`:

- `dast_findings` (DAST / ZAP)
- `missing_release_evidence` (release-evidence artifact presence)
- `repository_health_warnings` (OpenSSF Scorecard)

The mode that should **FAIL** on each is derived from `default_for()` in
[`scripts/resolve-gates.sh`](../../../scripts/resolve-gates.sh) — that function is the
single source of truth; the tables here are a derived view.

> **Honesty note:** regulated mode is **NOT marked ready** in v0.1.25. These fixtures and
> the walkthrough in [`docs/regulated-dry-run.md`](../../../docs/regulated-dry-run.md) are
> a **dry run** to validate the gate wiring and evidence flow, not a readiness claim. See
> [`docs/regulated-mode-readiness.md`](../../../docs/regulated-mode-readiness.md).

See also: [`docs/regulated-dry-run.md`](../../../docs/regulated-dry-run.md),
[`docs/gate-promotion-policy.md`](../../../docs/gate-promotion-policy.md),
[`../modes-v024/README.md`](../modes-v024/README.md) (the v0.1.24 execution counterpart).

## Fixture → gate → mode that fails

| Fixture | Collector / source | Summary key (count) | Gate `fail_on.*` | Lowest mode that FAILS |
| --- | --- | --- | --- | --- |
| `dast-finding/zap.json` | `collectors/zap.sh` | `dast_findings=2` | `dast_findings` | **regulated** only |
| `missing-release-evidence/` (no JSON, no evidence) | `build-security-summary.sh` (absence) | `missing_release_evidence=true` | `missing_release_evidence` | **regulated** only |
| `repo-health/scorecard.json` | `collectors/scorecard.sh` | `repository_health_warnings=1` | `repository_health_warnings` | **regulated** only |
| `clean/gitleaks.json` (`[]`) | `collectors/gitleaks.sh` | `secrets=0` | `secrets` | none (all modes PASS) |
| `clean/sbom.spdx.json` | `build-security-summary.sh` (presence) | `missing_sbom=false` | `missing_sbom` | none (all modes PASS) |
| `clean/release-evidence.md` | `build-security-summary.sh` (presence) | `missing_release_evidence=false` | `missing_release_evidence` | none (all modes PASS) |

> "Lowest mode that FAILS" is the first tier whose default `fail_on.<key>` is `true`. The
> authoritative per-mode booleans live in `default_for()` in `scripts/resolve-gates.sh`;
> this table is a derived view, not a second source of truth.

## Expected pass/fail per mode (whole fixture set)

| Fixture set | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| `dast-finding/` | PASS | PASS | PASS | **FAIL** |
| `missing-release-evidence/` | PASS | PASS | PASS | **FAIL** |
| `repo-health/` | PASS | PASS | PASS | **FAIL** |
| `clean/` (no findings, evidence present) | PASS | PASS | PASS | PASS |

strict requires an SBOM but intentionally does **not** require the release-evidence note,
and leaves `dast_findings` / `repository_health_warnings` non-blocking. Only regulated
promotes all three to blocking. This is exactly what makes them a meaningful "dry run" of
the regulated tier.

## Verified collector mappings (run in worktree root)

```
zap       → dast_findings              = 2   # dast-finding/zap.json   (riskcode>=2: the 3 and the 2; the 1 and 0 are excluded)
scorecard → repository_health_warnings = 1   # repo-health/scorecard.json (Branch-Protection score=2; Pinned-Dependencies score=-1 excluded)
gitleaks  → secrets                    = 0   # clean/gitleaks.json ([])
```

Reproduce:

```sh
sh scripts/collectors/zap.sh       --input tests/fixtures/regulated-v025/dast-finding/zap.json   | jq .summary.dast_findings              # 2
sh scripts/collectors/scorecard.sh --input tests/fixtures/regulated-v025/repo-health/scorecard.json | jq .summary.repository_health_warnings  # 1
sh scripts/collectors/gitleaks.sh  --input tests/fixtures/regulated-v025/clean/gitleaks.json      | jq .summary.secrets                    # 0
```

## Notes on the two non-JSON / evidence cases

- `clean/sbom.spdx.json` and `clean/release-evidence.md` are **evidence artifacts**. They
  must be placed in the **build output directory** that `build-security-summary.sh` reads
  (not the `reports/raw` collector inputs dir). See [`clean/README.md`](clean/README.md).
- `missing-release-evidence/` ships **no JSON and no evidence by design**: the gate fires
  on the *absence* of `release-evidence.md` in the output dir. See
  [`missing-release-evidence/README.md`](missing-release-evidence/README.md).
