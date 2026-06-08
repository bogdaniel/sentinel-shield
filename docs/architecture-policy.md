# Architecture Policy (v0.1.14)

Architectural boundaries (Deptrac) + architecture tests → `architecture_violations`
(baseline+ gating for Deptrac; architecture-tests opt-in).

- Deptrac: `runners/deptrac.sh` → `deptrac.json`. Define layers/rules in `deptrac.yaml`.
- Architecture tests: `runners/architecture-tests.sh` runs `$SENTINEL_SHIELD_ARCH_TEST_CMD`
  (e.g. Pest arch tests) → `architecture-tests.json` `{violations:N}` → collector → architecture_violations.
- Missing config/command → unavailable (never fake). Triage:
  [`remediation/deptrac-architecture-triage.md`](remediation/deptrac-architecture-triage.md).
