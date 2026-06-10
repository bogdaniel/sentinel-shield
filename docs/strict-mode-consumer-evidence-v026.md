# Strict-Mode Consumer Evidence (v0.1.26)

> **Scope.** A real run of the Sentinel Shield enforcement engine
> (`scripts/resolve-gates.sh` → `scripts/enforce-gates.sh`) in **baseline** and **strict**
> modes over a **controlled consumer fixture**. This is a **dry-run**, not a live full-CI
> consumer run. It proves the strict gate path behaves correctly and identifies exactly which
> gates flip strict to fail. It does **not** claim strict mode is production-ready — see §4.
>
> Maturity claims defer to [`product-status.md`](product-status.md); strict gate semantics to
> [`strict-mode-readiness.md`](strict-mode-readiness.md).

## 1. Fixture

A `laravel-react-docker`-derived `security-summary.json`: **clean in baseline**, but carrying two
findings that are **only** gated in strict —

- `medium_vulnerabilities = 3`
- `style_violations = 2`

Everything else is zero, and the SBOM/release-evidence blocks are present (so `missing_sbom` /
`missing_release_evidence` do not fire). This isolates the medium + style gates as the strict-flip
drivers. Nothing is suppressed (`.sentinel-shield/accepted-risks.json` absent →
`accepted_risks.loaded = 0`).

## 2. Result

| Mode | `enforce-gates.sh` exit | `result` | `failed_gates` |
|---|---|---|---|
| `baseline` | **0** | `pass` | `[]` |
| `strict` | **1** | `fail` | `["medium_vulnerabilities", "style_violations"]` |

Strict `evaluated_gates` (excerpt) — both flips visible, nothing else regressed:

```json
{ "key": "medium_vulnerabilities", "enabled": true, "value": 3, "result": "fail" }
{ "key": "style_violations",       "enabled": true, "value": 2, "result": "fail" }
{ "key": "critical_vulnerabilities","enabled": true, "value": 0, "result": "pass" }
{ "key": "high_vulnerabilities",   "enabled": true, "value": 0, "result": "pass" }
```

## 3. Which gates strict adds (resolved gate-env diff, baseline → strict)

```
SENTINEL_SHIELD_FAIL_ON_MEDIUM_VULNERABILITIES        false → true
SENTINEL_SHIELD_FAIL_ON_STYLE_VIOLATIONS              false → true
SENTINEL_SHIELD_FAIL_ON_MISSING_SBOM                  false → true
SENTINEL_SHIELD_FAIL_ON_IAC_VIOLATIONS                false → true
SENTINEL_SHIELD_FAIL_ON_CONTAINER_IMAGE_VIOLATIONS    false → true
SENTINEL_SHIELD_FAIL_ON_THIRD_PARTY_INSTALL_SCRIPT_RISK false → true
SENTINEL_SHIELD_FAIL_ON_THIRD_PARTY_NETWORK_BEHAVIOR  false → true
```

This matches [`strict-mode-readiness.md`](strict-mode-readiness.md) §1 exactly.

## 4. Verdict — is strict usable today?

- **The engine is correct.** Baseline passes; strict fails *only* on the documented strict-only
  blockers; the failure is expected, attributable, and not noisy. Nothing is suppressed.
- **Adoptability is consumer-side, not engine-side.** A consumer can flip to strict once it has
  triaged its `medium_vulnerabilities` and configured a style gate (Pint / PHP-CS-Fixer / PHPCS or
  the JS equivalent). For a project with unconfigured style or untriaged medium findings, strict
  will (correctly) block — that is migration work, not a Sentinel Shield bug.
- **NOT production-ready claim.** This is a controlled-fixture dry-run. Strict mode is **not** marked
  production-ready. Promotion to that claim requires a **live strict CI run on a real consumer**,
  cited in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## 5. Reproduce

```sh
MUT='.summary.medium_vulnerabilities=3 | .summary.style_violations=2'
for MODE in baseline strict; do
  d=$(mktemp -d)
  jq "$MUT" templates/security-summary.example.json > "$d/security-summary.json"
  sh scripts/resolve-gates.sh --mode "$MODE" --output-dir "$d" --format env
  sh scripts/enforce-gates.sh --gates-env "$d/sentinel-shield-gates.env" \
     --summary "$d/security-summary.json" --output-dir "$d" --format all
  echo "$MODE -> exit $?"; jq -c '{result,failed_gates}' "$d/sentinel-shield-enforcement.json"
done
```

Regression-guarded by `scripts/self-test.sh v026-live` (cases `(56)`).
