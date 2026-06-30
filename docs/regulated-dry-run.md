# Regulated-Mode Dry Run — v0.1.25

> **Status: regulated mode is NOT marked ready in v0.1.25.** This document is a *dry run*:
> a reproducible walkthrough that exercises the regulated-only gates end-to-end against
> fixtures, so we can validate the wiring (collectors → summary → gate resolution →
> enforcement) and the evidence flow **before** any project flips to `gates.mode:
> regulated`. It is **not** a readiness sign-off and **not** a v1.0 claim. The readiness
> bar lives in [`regulated-mode-readiness.md`](regulated-mode-readiness.md); the promotion
> rules in [`gate-promotion-policy.md`](gate-promotion-policy.md).

Companion fixtures: [`../tests/fixtures/regulated-v025/`](../tests/fixtures/regulated-v025/README.md).

---

## 61. Scope of this dry run

Regulated is the only built-in mode that promotes these three gates from advisory to
blocking (see `default_for "regulated"` in
[`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh)):

| Gate (`fail_on.*`) | Source | Summary key |
| --- | --- | --- |
| `dast_findings` | OWASP ZAP / Nuclei (`collectors/zap.sh`) | `dast_findings` |
| `missing_release_evidence` | `build-security-summary.sh` (evidence-file presence) | `missing_release_evidence` |
| `repository_health_warnings` | OpenSSF Scorecard (`collectors/scorecard.sh`) | `repository_health_warnings` |

The dry run drives one fixture per gate plus a `clean/` control where all three resolve
green, and observes the pass/fail outcome under each of the four modes.

## 62. Prerequisites

- `jq` on PATH (collectors and the summary builder require it).
- POSIX `sh`. No `yq` needed for the built-in modes used here (the dry run forces the mode
  via `--mode`, so no profile parsing is exercised).
- Run everything from the **worktree / repo root**.

## 63. Fixtures used

```
tests/fixtures/regulated-v025/
  dast-finding/zap.json                 # riskcode>=2 ×2  → dast_findings=2
  repo-health/scorecard.json            # one check score<5 → repository_health_warnings=1
  missing-release-evidence/             # no JSON, no evidence → missing_release_evidence=true
  clean/gitleaks.json ([])              # secrets=0
  clean/sbom.spdx.json                  # missing_sbom=false   (evidence artifact)
  clean/release-evidence.md             # missing_release_evidence=false (evidence artifact)
```

See the [fixtures README](../tests/fixtures/regulated-v025/README.md) for the full
fixture → gate → mode table.

## 64. Collector dry run (real counts)

Run the two regulated-only collectors directly and confirm the counts:

```sh
sh scripts/collectors/zap.sh       --input tests/fixtures/regulated-v025/dast-finding/zap.json   | jq .summary.dast_findings              # 2
sh scripts/collectors/scorecard.sh --input tests/fixtures/regulated-v025/repo-health/scorecard.json | jq .summary.repository_health_warnings  # 1
sh scripts/collectors/gitleaks.sh  --input tests/fixtures/regulated-v025/clean/gitleaks.json      | jq .summary.secrets                    # 0
```

Observed in this worktree (v0.1.25):

```
zap       → dast_findings              = 2   (status=fail)
scorecard → repository_health_warnings = 1   (status=warn)
gitleaks  → secrets                    = 0   (status=pass)
```

`zap.sh` counts ZAP alerts with `riskcode >= 2` (the High=3 and Medium=2 alerts; the
Low=1 and Informational=0 alerts are excluded). `scorecard.sh` counts checks with
`score >= 0 and score < 5` (Branch-Protection score=2 qualifies; Pinned-Dependencies
score=-1 is excluded as inconclusive).

## 65. Baseline vs strict vs regulated — behavior differences

The per-mode default for each regulated-only gate (from `default_for()`):

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| `dast_findings` | false | false | false | **true** |
| `missing_release_evidence` | false | false | false | **true** |
| `repository_health_warnings` | false | false | false | **true** |
| `missing_sbom` (context) | false | false | **true** | **true** |

So a build carrying a DAST finding, a missing release-evidence note, or a low Scorecard
check **passes under report-only/baseline/strict and fails only under regulated**. Strict
already requires an SBOM; regulated adds the release-evidence note on top of it.

## 66. Whole-fixture-set outcome per mode

| Fixture set | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| `dast-finding/` | PASS | PASS | PASS | **FAIL** |
| `missing-release-evidence/` | PASS | PASS | PASS | **FAIL** |
| `repo-health/` | PASS | PASS | PASS | **FAIL** |
| `clean/` | PASS | PASS | PASS | PASS |

This is the signal the dry run is meant to produce: the three gates are *inert* up to
strict and *blocking* at regulated, and the clean control never false-positives.

## 67. Harness example (manual, copy-paste)

A minimal end-to-end run for the `dast-finding` fixture (regulated should FAIL, strict
should PASS). The captain wires the equivalent into the self-test (see §73); this is the
manual form for local exploration.

```sh
set -eu
ROOT=$(pwd)
WORK=$(mktemp -d)
RAW="$WORK/reports/raw"
OUT="$WORK/reports"
mkdir -p "$RAW" "$OUT"

# 1. Stage the raw collector input.
cp tests/fixtures/regulated-v025/dast-finding/zap.json "$RAW/zap.json"

# 2. Build the security summary (no SBOM / release-evidence in OUT on purpose here).
sh scripts/build-security-summary.sh --raw-dir "$RAW" --output "$OUT/security-summary.json"
jq '.summary.dast_findings' "$OUT/security-summary.json"      # 2

# 3. Resolve gates for each mode and enforce.
for MODE in strict regulated; do
  sh scripts/resolve-gates.sh --mode "$MODE" --output-dir "$OUT" --format env
  # enforce-gates.sh consumes the resolved env + the summary and exits non-zero on a block.
  if sh scripts/enforce-gates.sh \
        --summary "$OUT/security-summary.json" \
        --gates "$OUT/sentinel-shield-gates.env"; then
    echo "$MODE: PASS"
  else
    echo "$MODE: FAIL (expected for regulated)"
  fi
done

rm -rf "$WORK"
```

> Confirm `enforce-gates.sh`'s exact flag names against
> [`scripts/enforce-gates.sh`](../scripts/enforce-gates.sh) in your checkout before
> scripting CI around it; the dry run only depends on the resolved env + summary being the
> two inputs.

For the **clean** control, additionally copy the evidence artifacts into `OUT` so the
regulated evidence gate resolves green:

```sh
cp tests/fixtures/regulated-v025/clean/gitleaks.json       "$RAW/gitleaks.json"
cp tests/fixtures/regulated-v025/clean/sbom.spdx.json      "$OUT/sbom.spdx.json"
cp tests/fixtures/regulated-v025/clean/release-evidence.md "$OUT/release-evidence.md"
```

## 68. Evidence checklist (what regulated demands before it can block honestly)

Before regulated's evidence gates can be trusted as blockers:

- [ ] **SBOM** is produced per release and lands at `<output-dir>/sbom.spdx.json`
      (`missing_sbom=false`). Already required by strict.
- [ ] **Release-evidence note** lands at `<output-dir>/release-evidence.md`
      (`missing_release_evidence=false`) — approver, date, test status, provenance.
- [ ] **DAST** has a configured target + allowlist + approval per
      [`dast-policy.md`](dast-policy.md); otherwise `dast_findings` must stay advisory.
- [ ] **Scorecard** baseline is captured and triaged so a low check is a real signal, not
      an environment artifact.
- [ ] Each evidence artifact is reproducible in CI (not hand-placed), and its absence is a
      genuine release blocker your team accepts.

## 69. Adoption checklist (flipping a project to regulated)

- [ ] The project already runs **strict** cleanly for a sustained period (regulated is a
      superset of strict — read [`strict-mode-readiness.md`](strict-mode-readiness.md)).
- [ ] All [§68](#68-evidence-checklist-what-regulated-demands-before-it-can-block-honestly)
      evidence artifacts are produced automatically in CI.
- [ ] DAST and Scorecard have run **advisory** long enough to tune out noise before they
      block (see [`gate-promotion-policy.md`](gate-promotion-policy.md)).
- [ ] Owners agreed that a missing evidence note / DAST finding / low Scorecard check
      should **stop a release**.
- [ ] A rollback path ([§70](#70-rollback-checklist)) is documented and tested.
- [ ] Only after all the above: set `gates.mode: regulated` in the profile.

## 70. Rollback checklist

If regulated blocks releases for the wrong reasons:

- [ ] **Fastest:** set `gates.mode: strict` (or `baseline`) in
      `.sentinel-shield/profile.yaml`. Regulated-only gates revert to advisory.
- [ ] **Targeted:** keep `regulated` but override the offending gate in the profile, e.g.
      `gates.fail_on.dast_findings: false` ([§74](#74-profile-override-example)) until it
      is tuned.
- [ ] **CI-side:** force the mode for one pipeline run with `resolve-gates.sh --mode
      strict` without editing the profile.
- [ ] File the regression against [`gate-promotion-policy.md`](gate-promotion-policy.md)
      so the gate is demoted in the defaults if it is systemically too noisy.

## 71. When regulated is appropriate

- Compliance-heavy contexts (regulated industries, audited release processes) where
  **release evidence and an SBOM are mandatory artifacts**, not nice-to-haves.
- Projects that have already run strict cleanly and have DAST + Scorecard tuned.
- Releases where a missing audit trail genuinely *should* stop the release.

## 72. Why regulated is NOT the default

- It blocks on **evidence and supply-chain/DAST/repo-health signals that are still
  maturing**; making it default would convert advisory noise into release-stopping
  failures for projects that have not tuned them.
- Several of its inputs (DAST target/approval, Scorecard baseline) require **per-project
  configuration** that does not exist out of the box.
- The default ladder is intentionally `report-only → baseline → strict → regulated`; teams
  opt into the strictest tier only after the lower tiers are green and the evidence
  pipeline is automated. Regulated is **NOT marked ready** in v0.1.25 (see
  [`regulated-mode-readiness.md`](regulated-mode-readiness.md)).

## 73. Self-test the captain should wire (regulated-only gates)

A regulated-only enforcement self-test (captain-owned wiring) should, for each fixture in
`tests/fixtures/regulated-v025/`:

1. Stage the collector input(s) into a temp `reports/raw`, and (for `clean/`) copy the
   evidence artifacts into the temp output dir.
2. Build the summary with `build-security-summary.sh` and assert the count:
   - `dast-finding/` → `.summary.dast_findings == 2`
   - `repo-health/` → `.summary.repository_health_warnings == 1`
   - `missing-release-evidence/` → `.summary.missing_release_evidence == true`
   - `clean/` → `secrets==0`, `missing_sbom==false`, `missing_release_evidence==false`,
     `dast_findings==0`, `repository_health_warnings==0`
3. Resolve + enforce under **strict** and **regulated** and assert:
   - `dast-finding/`, `repo-health/`, `missing-release-evidence/`: **strict PASS,
     regulated FAIL**.
   - `clean/`: **strict PASS, regulated PASS**.

This is the assertion that proves the three gates are regulated-only and that the clean
control does not false-positive. (Lane D ships the fixtures; the captain wires the
self-test.)

## 74. Profile override example

Regulated defaults can be tightened or loosened per project. Example: adopt regulated but
keep DAST advisory until the target/allowlist are configured, and additionally turn ON the
otherwise-non-gating AI review:

```yaml
# .sentinel-shield/profile.yaml
project:
  name: example-app
  type: php
  criticality: high
gates:
  mode: regulated
  fail_on:
    dast_findings: false        # keep advisory until DAST target+approval exist
    ai_review_findings: true    # opt in to AI-review blocking (off by default even in regulated)
```

`resolve-gates.sh` reports every override on stderr and in
`sentinel-shield-gates.{json,md}`, so deviations from the mode defaults are never hidden.

## 75. Release-gates note

The resolved gates (`<output-dir>/sentinel-shield-gates.env`) are what the CI release gate
consumes — see [`.github/workflows/ci-release-gate.yml`](../.github/workflows/ci-release-gate.yml)
and [`scripts/enforce-gates.sh`](../scripts/enforce-gates.sh). Under regulated, the three
gates in this dry run join the strict set as hard blockers in that workflow. The dry run
deliberately exercises `resolve-gates.sh` + `build-security-summary.sh` in isolation so
the *gate math* can be validated independently of the CI plumbing.

## 76. v1 / product contract — captain-owned

The v1 product contract and any v1.0 statement for regulated mode are **captain-owned**
and out of scope for this lane. This dry run makes no v1.0 claim. (Placeholder; see the
captain's v1 docs.)

## 77. Readiness sign-off — captain-owned

Promotion of regulated mode to "ready" (the formal readiness sign-off) is **captain-owned**
and tracked in [`regulated-mode-readiness.md`](regulated-mode-readiness.md) /
[`gate-promotion-policy.md`](gate-promotion-policy.md). This document does not grant it.

## 78. Known limitations

- DAST (`dast_findings`) is only meaningful with a configured target + allowlist +
  approval; without those the fixture exercises the *gate math*, not a real scan.
- Scorecard (`repository_health_warnings`) can produce environment-dependent low scores
  (e.g. Branch-Protection on a fork); treat as advisory until baselined.
- The evidence gates (`missing_sbom`, `missing_release_evidence`) are pure
  presence/absence checks — they do **not** validate the *content* of the SBOM or evidence
  note.
- The dry run forces modes via `--mode`; it does **not** exercise profile-driven mode
  selection or `yq`-based parsing.
- `enforce-gates.sh` flag names should be confirmed against the script in your checkout
  before wiring CI (see §67).

## 79. Strict → regulated migration

1. Run **strict** cleanly and continuously; resolve all strict blockers first.
2. Turn the regulated-only gates on **advisory** (run the collectors, watch
   `dast_findings` / `repository_health_warnings` / `missing_release_evidence` in the
   summary) without blocking, per [`gate-promotion-policy.md`](gate-promotion-policy.md).
3. Automate the evidence pipeline so SBOM + release-evidence land in the output dir every
   release.
4. Tune DAST and Scorecard until their findings are real, not noise.
5. Flip `gates.mode: regulated`, optionally with per-gate overrides ([§74](#74-profile-override-example))
   for any gate still being tuned.
6. Keep the rollback path ([§70](#70-rollback-checklist)) ready.

## 80. Honesty statement — regulated NOT marked ready

**Regulated mode is NOT marked ready in Sentinel Shield v0.1.25.** This is a *dry run*:
it validates that the regulated-only gates (`dast_findings`, `missing_release_evidence`,
`repository_health_warnings`) wire through collectors → summary → resolution → enforcement
correctly, and that the clean control does not false-positive. It is **not** a readiness
sign-off and makes **no v1.0 claim**. Readiness and v1 statements are captain-owned
(§76–§77). Do not flip a production project to `gates.mode: regulated` on the strength of
this document alone; satisfy the readiness bar in
[`regulated-mode-readiness.md`](regulated-mode-readiness.md) first.
