# Deptrac / Architecture Triage (v0.1.14)

For `architecture_violations` from Deptrac or architecture tests.
1. **Fix the dependency direction** (move code, introduce an interface/port) — preferred.
2. **Adjust layers** in `deptrac.yaml` only if the boundary model is genuinely wrong (review required).
3. **Do not** broadly allow layer violations to pass; that defeats the boundary.
4. Architecture tests: fix the offending class/namespace; keep the arch suite in `$SENTINEL_SHIELD_ARCH_TEST_CMD`.
