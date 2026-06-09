# Main-Gate Execution Hardening (v0.1.19)

Makes the remaining main-gate tools (**Grype, OWASP Dependency-Check, Dockle**) run predictably
from `scripts/run-main-gate-validation.sh` + the workflow templates, and adds a **Semgrep image
verification** path — all without project-specific workflow hacks. **No new scanners. No gates
weakened. No findings suppressed. No live-validation claims without artifact evidence.**

## Current behavior → why unavailable → v0.1.19 change → still unproven

| Tool | Before (why unavailable on pilot run 27214865086) | v0.1.19 change | Still unproven after v0.1.19 |
|---|---|---|---|
| **Grype** | wrapper did `grype dir:.` only; binary absent on runner → unavailable | SBOM-first (default) + fs mode; local binary **or** container image; env-driven (`SENTINEL_SHIELD_GRYPE_MODE/IMAGE/SBOM_PATH`); harness exports the Syft SBOM path | **live consumer run** with a real `grype.json` (no consumer has run it yet) |
| **OWASP Dependency-Check** | `dependency-check --scan .` only; binary absent; slow (NVD) | **disabled by default**; `enabled` mode; cache dir; container image; documented as scheduled/nightly | live run on a consumer (no evidence) |
| **Dockle** | required `SENTINEL_SHIELD_IMAGE`; none supplied | local binary **or** container; explicit image only (never builds/scan-arbitrary); `SENTINEL_SHIELD_DOCKLE_IMAGE/EXIT_CODE` | live run with a built image (no evidence) |
| **Semgrep image** | 1.90.0 → 118 PartialParsing errors on app PHP; 1.165.0 set in v0.1.18 but **not tested** | `scripts/verify-semgrep-image.sh` + modern-PHP fixture; **fixture-verified 1.165.0 = 0 parser errors** (see below) | **live consumer** re-run (the 118 were on zenchron's full Modules/**/app, not the fixture) |

## Semgrep 1.165.0 — fixture verification (real, this release)
`scripts/verify-semgrep-image.sh` ran **`semgrep/semgrep:1.165.0`** (output `.version` = `1.165.0`,
via Docker) against `tests/fixtures/semgrep/php-modern` (readonly props, constructor promotion,
attributes, enum, match, typed props): **`errors: []` — 0 PartialParsing/Syntax errors**, 15 rules,
0 findings. This **fixture-verifies** that 1.165.0 parses modern PHP that 1.90.0 failed on.
**It is NOT live consumer validation** — promote only after re-running on zenchron's real codebase
and confirming the 118 errors drop. Recorded in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## Honest status after v0.1.19
Grype/Dependency-Check/Dockle remain **supported, not live-validated** (no consumer artifact).
Semgrep 1.165.0 is **fixture-verified, not consumer-verified**. Deptrac/IaC remain
not-configured unless the consumer provides config/IaC.
