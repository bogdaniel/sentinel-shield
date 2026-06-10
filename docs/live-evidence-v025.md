# Live Evidence — v0.1.25 (real local scanner runs)

This sprint produced **real scanner artifacts** by running actual scanners (via Docker) against the
shipped fixtures, then parsing them with the Sentinel Shield collectors. Unlike fixture-mappings,
these are real tool outputs — the artifacts are committed under `tests/fixtures/live-evidence/` and
the `v025-live` self-test parses them. Run date: 2026-06-10. Docker server 29.4.0.

> Honesty: these are **local tool-execution validations on fixtures**, not live *consumer-CI* runs.
> They prove the scanner runs and the collector parses real output. Consumer-CI promotion still
> follows [`main-gate-live-evidence.md`](main-gate-live-evidence.md). No maturity label is inflated.

## 1. Checkov — REAL run ✓

```
docker run --rm -v <fixture>/terraform:/tf bridgecrew/checkov:latest -d /tf -o json
```
- **checkov 3.3.0**, scanning `tests/fixtures/iac-v024/terraform/insecure.tf` (public S3 + open SG).
- Result: **7 passed / 16 failed**, 3 resources.
- Artifact: `tests/fixtures/live-evidence/checkov-real.json` (50 KB, real).
- Collector `checkov.sh` → **`status: fail, iac_violations: 16`**.
- **Outcome: real IaC scanner execution validated locally** — the Checkov integration parses genuine
  Checkov 3.3.0 output, not a hand-authored fixture.

## 2. Grype — REAL run ✓

```
docker run --rm -v <fixtures>:/src anchore/grype:v0.114.0 dir:/src -o json
```
- **grype 0.114.0** (digest-pinned image), scanning the fixture project tree.
- Result: **4 matches** (1 mapped MEDIUM).
- Artifact: `tests/fixtures/live-evidence/grype-real.json` (14 KB, real).
- Collector `grype.sh` → **`status: fail, medium_vulnerabilities: 1`**.
- **Outcome: real vulnerability scan validated locally** against the digest-pinned Grype image.

## 3. OWASP Dependency-Check — REAL attempt, BLOCKED by NVD (external) ✗ (honest)

```
SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled \
SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE=owasp/dependency-check:latest \
sh scripts/audits/dependency-check.sh <out>.json
```
- The real cold NVD download **failed with HTTP 429** — NVD now rate-limits/refuses unauthenticated
  bulk pulls (an NVD API key is required). The tool exited **13 without producing valid JSON**.
- Excerpt: `tests/fixtures/live-evidence/dependency-check-429-excerpt.log` —
  `NvdApiException: NVD Returned Status Code: 429`.
- **The wrapper behaved correctly: reported `unavailable`, wrote NO fake-clean report** (88 MB partial
  NVD cache, but no `dependency-check.json`). This is the v0.1.24 anti-fake hardening **confirmed
  under a real failure**.
- **Outcome: Dependency-Check remains ATTEMPTED, NOT live-validated — proven blocked by an external
  constraint (NVD 429 / API-key requirement), not a Sentinel Shield deficiency.** No artifact, no
  run ID, nothing promoted, nothing fabricated.
- **Unblock path:** supply `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY` (or run on a consumer with a
  warm cache + key on the default branch) — see
  [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md) and the consumer
  attempt in [`dependency-check-live-evidence-v024.md`](dependency-check-live-evidence-v024.md).

## 4. Strict-mode gate — REAL engine execution ✓

Ran the real `build-security-summary.sh → resolve-gates.sh → enforce-gates.sh` pipeline in both
`baseline` and `strict` against the multi-violation fixture (with SBOM + release-evidence present so
only style/iac/medium are non-clean):

- **baseline → PASS**, **strict → FAIL** on exactly `medium_vulnerabilities`, `style_violations`,
  `iac_violations`.
- **Outcome: strict-mode gate execution validated** — baseline correctly tolerates what strict blocks.
  This is real engine execution, not a table. (A live *consumer-CI* strict run is still the v1.0 bar.)

## Summary

| Area | Real run? | Result | Status |
|---|---|---|---|
| Checkov (IaC) | ✓ checkov 3.3.0 | 16 iac_violations, collector parsed | locally tool-validated |
| Grype (vuln) | ✓ grype 0.114.0 | 1 medium, collector parsed | locally tool-validated |
| Dependency-Check | ✓ attempted | NVD 429 → wrapper `unavailable`, no fake | **NOT validated — externally blocked** |
| Strict-mode engine | ✓ | baseline pass / strict fail (3 gates) | engine-validated |

No scanners added; no gates weakened; no findings suppressed; no fake reports; no v1.0 claim.
