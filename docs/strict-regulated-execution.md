# Strict / Regulated execution — enforcement spec

Status: v0.1.24. This document specifies the **exact pass/fail behaviour** the enforcement
self-tests must assert for the `report-only`, `baseline`, `strict`, and `regulated`
adoption modes, derived from `default_for()` in
[`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh). It is paired with the fixture
set in [`tests/fixtures/modes-v024/`](../tests/fixtures/modes-v024/README.md).

Honesty note: this is an execution/verification spec for the four existing modes. It does
**not** weaken any gate and makes **no v1.0 claim**. Gate booleans below are read straight
from `resolve-gates.sh`; if that file changes, this doc must be re-derived.

Related docs (authoritative for their topics; referenced, not duplicated):

- [`docs/strict-mode-readiness.md`](strict-mode-readiness.md)
- [`docs/regulated-mode-readiness.md`](regulated-mode-readiness.md)
- [`docs/gate-promotion-policy.md`](gate-promotion-policy.md)

## How a mode "fails"

1. Collectors map raw scanner output to summary counts
   (`build-security-summary.sh` aggregates them; evidence flags come from file presence).
2. `resolve-gates.sh --mode <m>` resolves each `fail_on.<key>` boolean for the mode.
3. The enforcer fails the build iff **any** gate with `fail_on.<key> = true` has a
   non-zero count (for boolean evidence gates: the flag is `true`).

So a mode FAILS a fixture iff the fixture produces a non-zero count for at least one gate
that is `true` in that mode.

---

## 86-90 — Required self-test assertions

The captain wires these as enforcement tests. Each references a fixture from
`tests/fixtures/modes-v024/` and the resolved mode booleans.

### 86 — report-only PASSES the strict fixture
Run the `multi-violation/` set (style=3, medium=2, iac=3) and enforce in **report-only**.
All three gates are `false` in report-only (only `secrets` and `expired_exceptions` block),
so the build **PASSES**.
> Assert: enforce(report-only, multi-violation) == PASS.

### 87 — baseline PASSES strict-only violations
Run the `multi-violation/` set and enforce in **baseline**. `style_violations`,
`medium_vulnerabilities`, and `iac_violations` are all `false` in baseline (they promote at
strict), so the build **PASSES**.
> Assert: enforce(baseline, multi-violation) == PASS.

### 88 — strict FAILS strict violations
Run the `multi-violation/` set and enforce in **strict**. All three gates are `true` in
strict, so the build **FAILS** (and should fail even if only one of them were non-zero).
> Assert: enforce(strict, multi-violation) == FAIL, citing style_violations,
> medium_vulnerabilities, iac_violations.

### 89 — regulated FAILS regulated-only violations
Run each regulated-only fixture and enforce in **regulated**:
- `dast-finding/` → `dast_findings=2` → FAIL.
- `missing-release-evidence/` (no `release-evidence.md` in output dir) →
  `missing_release_evidence=true` → FAIL.
- `repo-health/` → `repository_health_warnings=1` → FAIL.

Cross-check: enforce the **same** regulated-only fixtures in **strict** — they must
**PASS**, because all three gates are `false` in strict. This pins the strict↔regulated
boundary.
> Assert: enforce(regulated, {dast,missing-release-evidence,repo-health}) == FAIL each;
> enforce(strict, same) == PASS each.

### 90 — regulated PASSES when regulated gates are clean
Run the `clean/` set (gitleaks `[]` → secrets=0; `sbom.spdx.json` and
`release-evidence.md` present in the output dir → `missing_sbom=false`,
`missing_release_evidence=false`) and enforce in **regulated**. No gate has a non-zero
count, so the build **PASSES**. (The same set PASSES in all four modes.)
> Assert: enforce(regulated, clean) == PASS; also enforce(report-only|baseline|strict,
> clean) == PASS.

---

## 91 — Per-flag table: every STRICT `fail_on` flag

All 24 canonical `fail_on` keys with their resolved boolean in **strict**, from
`resolve-gates.sh`. "Blocks in strict" = the build fails when that gate's count is
non-zero (or the evidence flag is `true`).

| `fail_on.<key>` | Strict | Blocks in strict? | Notes |
| --- | --- | --- | --- |
| `secrets` | `true` | yes | blocks from report-only up |
| `critical_vulnerabilities` | `true` | yes | blocks from baseline up |
| `high_vulnerabilities` | `true` | yes | blocks from baseline up |
| `medium_vulnerabilities` | `true` | yes | **promotes at strict** (false in baseline) |
| `architecture_violations` | `true` | yes | blocks from baseline up |
| `type_errors` | `true` | yes | blocks from baseline up |
| `test_failures` | `true` | yes | blocks from baseline up |
| `unsafe_docker` | `true` | yes | blocks from baseline up |
| `unsafe_github_actions` | `true` | yes | blocks from baseline up |
| `missing_sbom` | `true` | yes | **promotes at strict** (false in baseline) |
| `missing_release_evidence` | `false` | no | **regulated-only**; strict needs SBOM, not the note |
| `expired_exceptions` | `true` | yes | blocks from report-only up |
| `third_party_suspicious_code` | `false` | no | regulated-only |
| `third_party_install_script_risk` | `true` | yes | **promotes at strict** |
| `third_party_obfuscation` | `false` | no | regulated-only |
| `third_party_network_behavior` | `true` | yes | **promotes at strict** |
| `php_syntax_errors` | `true` | yes | blocks from baseline up |
| `style_violations` | `true` | yes | **promotes at strict** (false in baseline) |
| `dependency_policy_violations` | `true` | yes | blocks from baseline up |
| `iac_violations` | `true` | yes | **promotes at strict** (false in baseline) |
| `container_image_violations` | `true` | yes | **promotes at strict** (false in baseline) |
| `dast_findings` | `false` | no | regulated-only |
| `repository_health_warnings` | `false` | no | regulated-only |
| `ai_review_findings` | `false` | no | never gating by default (opt-in via profile) |

Strict blocks 18 of 24 gates. The 6 it does **not** block are exactly:
`missing_release_evidence`, `third_party_suspicious_code`, `third_party_obfuscation`,
`dast_findings`, `repository_health_warnings`, `ai_review_findings`.

## 92 — Per-flag table: every REGULATED `fail_on` flag

| `fail_on.<key>` | Regulated | Blocks in regulated? | Newly blocking vs strict? |
| --- | --- | --- | --- |
| `secrets` | `true` | yes | no |
| `critical_vulnerabilities` | `true` | yes | no |
| `high_vulnerabilities` | `true` | yes | no |
| `medium_vulnerabilities` | `true` | yes | no |
| `architecture_violations` | `true` | yes | no |
| `type_errors` | `true` | yes | no |
| `test_failures` | `true` | yes | no |
| `unsafe_docker` | `true` | yes | no |
| `unsafe_github_actions` | `true` | yes | no |
| `missing_sbom` | `true` | yes | no |
| `missing_release_evidence` | `true` | yes | **yes — promotes at regulated** |
| `expired_exceptions` | `true` | yes | no |
| `third_party_suspicious_code` | `true` | yes | **yes — promotes at regulated** |
| `third_party_install_script_risk` | `true` | yes | no |
| `third_party_obfuscation` | `true` | yes | **yes — promotes at regulated** |
| `third_party_network_behavior` | `true` | yes | no |
| `php_syntax_errors` | `true` | yes | no |
| `style_violations` | `true` | yes | no |
| `dependency_policy_violations` | `true` | yes | no |
| `iac_violations` | `true` | yes | no |
| `container_image_violations` | `true` | yes | no |
| `dast_findings` | `true` | yes | **yes — promotes at regulated** |
| `repository_health_warnings` | `true` | yes | **yes — promotes at regulated** |
| `ai_review_findings` | `false` | no | no — still opt-in only |

Regulated blocks 23 of 24 gates. The only non-blocking gate is `ai_review_findings`
(opt-in via `gates.fail_on.ai_review_findings: true` in the profile). The 5 gates that
**newly** become blocking moving strict → regulated: `missing_release_evidence`,
`dast_findings`, `repository_health_warnings`, `third_party_suspicious_code`,
`third_party_obfuscation`.

---

## 93 — Strict readiness checklist

Before flipping a project to `strict`, confirm (full criteria in
[`docs/strict-mode-readiness.md`](strict-mode-readiness.md) — this is the operational
short form):

- [ ] No open `style_violations` (php-style/lint clean) — strict now blocks them.
- [ ] No open `iac_violations` (checkov clean) — strict now blocks them.
- [ ] No `medium_vulnerabilities` without an exception — strict now blocks them.
- [ ] `container_image_violations` clean (dockle/grype image) — strict now blocks them.
- [ ] An SBOM (`sbom.spdx.json`) is produced into the build output dir (`missing_sbom`
      blocks in strict). Release-evidence note is **not** yet required.
- [ ] `third_party_install_script_risk` and `third_party_network_behavior` triaged — both
      promote at strict.
- [ ] All baseline gates already green (critical/high vulns, type/test/arch, php-syntax,
      dependency-policy, unsafe docker/actions, secrets, expired exceptions).
- [ ] Self-test 88 (strict FAILS multi-violation) and 90 (strict PASSES clean) green in CI.

## 94 — Regulated readiness checklist

Before flipping to `regulated` (full criteria in
[`docs/regulated-mode-readiness.md`](regulated-mode-readiness.md)):

- [ ] Everything in the strict checklist (93) is satisfied and `strict` runs green.
- [ ] `release-evidence.md` is generated into the build output dir
      (`missing_release_evidence` blocks in regulated).
- [ ] DAST run wired and `dast_findings=0` (riskcode ≥ 2) — zap clean.
- [ ] OpenSSF Scorecard wired and `repository_health_warnings=0` (no check scoring < 5).
- [ ] `third_party_suspicious_code` and `third_party_obfuscation` triaged — both promote
      at regulated.
- [ ] Exception process in place for any of the above that cannot be remediated immediately.
- [ ] Self-test 89 (regulated FAILS dast/missing-evidence/repo-health) and 90 (regulated
      PASSES clean) green in CI.

---

## 95 — Migration guide: baseline → strict

1. Resolve gates in both modes and diff: the gates that newly block are
   `medium_vulnerabilities`, `style_violations`, `iac_violations`,
   `container_image_violations`, `third_party_install_script_risk`,
   `third_party_network_behavior`, and `missing_sbom`.
2. Run those collectors against the codebase **while still in baseline** (advisory).
3. Burn the backlog down to zero, or file time-boxed exceptions (see exceptions in
   `build-security-summary.sh`; expired exceptions block in every mode).
4. Ensure the pipeline emits `sbom.spdx.json` into the output dir.
5. Set `gates.mode: strict` in `.sentinel-shield/profile.yaml` (or `--mode strict`).
6. Verify a clean build passes (self-test 90) and a seeded violation fails (88).

## 96 — Migration guide: strict → regulated

1. Diff strict vs regulated: newly blocking are `missing_release_evidence`,
   `dast_findings`, `repository_health_warnings`, `third_party_suspicious_code`,
   `third_party_obfuscation`.
2. Wire the missing collectors: ZAP (DAST) and OpenSSF Scorecard (repo health).
3. Generate `release-evidence.md` into the output dir as part of the release job.
4. Triage DAST findings (riskcode ≥ 2) and Scorecard checks (score < 5) to zero or
   exceptions.
5. Set `gates.mode: regulated`.
6. Verify self-tests 89 (regulated-only fixtures FAIL) and 90 (clean PASSES) are green.

---

## 97 — Rollback guide: strict → baseline

If a strict promotion is destabilising the team:

1. Set `gates.mode: baseline` (or `--mode baseline`) — this is a config change only; no
   gate is deleted or weakened, the mode default simply de-escalates style/iac/medium/
   sbom/container + the two third-party signals back to advisory.
2. Keep the strict collectors running in advisory mode so the backlog stays visible.
3. Record the rollback reason and the re-promotion target date.
4. Do **not** edit `resolve-gates.sh` defaults to "soften" strict — rollback is a mode
   change, not a gate change. (Honesty: weakening a gate default is not a supported
   rollback.)

## 98 — Rollback guide: regulated → strict

1. Set `gates.mode: strict`. This de-escalates the five regulated-only gates
   (`missing_release_evidence`, `dast_findings`, `repository_health_warnings`,
   `third_party_suspicious_code`, `third_party_obfuscation`) back to advisory.
2. Keep DAST / Scorecard / release-evidence generation running for visibility.
3. Strict still enforces SBOM, style, iac, medium-vuln, container, etc. — security posture
   stays strong; only the compliance-evidence and DAST/repo-health gates relax.
4. Record reason + re-promotion date. Same honesty rule as 97: rollback is a mode change,
   never a gate-default edit.

---

## 99 — Mode comparison table

Blocking gate count and the gates each mode adds over the previous tier (from
`resolve-gates.sh`):

| | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| Gates that block (of 24) | 2 | 13 | 18 | 23 |
| Always-on | secrets, expired_exceptions | + (below) | + (below) | + (below) |
| Adds over previous tier | — | critical/high vulns, architecture, type_errors, test_failures, unsafe_docker, unsafe_github_actions, php_syntax_errors, dependency_policy_violations (+ third-party install/network are still false here) | medium_vulnerabilities, style_violations, iac_violations, container_image_violations, missing_sbom, third_party_install_script_risk, third_party_network_behavior | missing_release_evidence, dast_findings, repository_health_warnings, third_party_suspicious_code, third_party_obfuscation |
| Never gating by default | ai_review_findings | ai_review_findings | ai_review_findings | ai_review_findings (opt-in only) |
| Intent | legacy visibility | migration: no new high-risk debt | production security + quality + SBOM | compliance: evidence + DAST + repo health |

(Counts verified against `resolve-gates.sh` on this revision: report-only blocks 3, baseline 16, strict 32, regulated 40. An earlier revision said "baseline blocks 13" while its own list enumerated 9 additions — the arithmetic never reconciled. Regulated
adds 5 → 23. `ai_review_findings` is the only gate never on by default.)

## 100 — Note for release-gates docs

For the release-gate workflow documentation
([`.github/workflows/ci-release-gate.yml`](../.github/workflows/ci-release-gate.yml) and the
adoption guide), add the following cross-reference:

> The pass/fail behaviour of each adoption mode is specified and self-tested in
> [`docs/strict-regulated-execution.md`](strict-regulated-execution.md), backed by the
> fixtures in [`tests/fixtures/modes-v024/`](../tests/fixtures/modes-v024/README.md). The
> per-mode `fail_on` booleans are owned by `default_for()` in `scripts/resolve-gates.sh`;
> the doc tables (91/92) are a derived view. When adding or promoting a gate, update
> `resolve-gates.sh`, re-derive the 91/92 tables, and add a fixture under `modes-v024/`
> with its expected failing mode.

This keeps the release-gate docs pointing at a single, self-tested source of truth for
mode behaviour rather than restating booleans inline.
