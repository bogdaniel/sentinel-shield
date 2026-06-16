# Scanner Maturity Policy v2 (v1.7.0 — Agent D)

The **promotion/demotion policy** for a *scanner's* maturity label. This is distinct from
[`gate-promotion-policy.md`](gate-promotion-policy.md) (which governs a *consumer's* adoption mode
`report-only → baseline → strict → regulated`). The canonical per-tool labels live in
[`product-status.md`](product-status.md); cited evidence lives in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). This doc defines the *rules*.

## Labels (canonical)

| Label | Meaning | Evidence basis |
|---|---|---|
| `experimental` | Wired (collector + self-test fixture), parser/severity coarse. Use with review. | fixture only, or coarse mapping |
| `supported` | Deterministic runner/collector/self-test, not yet run against any real consumer. | fixture round-trip |
| **`ci-validated (evidence-fixture)`** | Real scanner + **real CI run ID** + real artifact + collector-verified, but on a **dedicated, intentionally-insecure, non-deployed evidence fixture** (engineered findings). | CI run on `*-evidence` repo |
| `live-validated` | Real scanner run in **a real consumer's CI** (third-party / production-shaped), incidental findings, collector-verified, cited run ID/artifact. | real-consumer CI |
| `manual` | Runs only on explicit operator action + target/allowlist (DAST). Never a default gate. | n/a |
| `non-gating` | Advisory only; never blocks by default (AI review). | n/a |
| `deprecated` / `not-ready` | Withdrawn, or declared/known-incomplete; do not rely on it. | n/a |

> **`ci-validated` is strictly weaker than `live-validated`.** It proves the **tool → collector →
> gate pipeline runs in CI**, not real-world consumer coverage. The two MUST NOT be conflated in any
> doc (guarded by `self-test v160-iac`/`v170-platform`).

## Promotion requirements

To move **up** a label, ALL required fields must exist and be cited in the registry:
tool name, tool version, repo/context, **CI run ID or reproducible command**, raw artifact path/name,
collector result, mapped summary key, pass/fail behavior, caveats.

| Transition | Additional requirement |
|---|---|
| `experimental`/`supported` → `ci-validated (evidence-fixture)` | a real CI run on a dedicated evidence repo (no creds, no deploy); collectors verified on the downloaded artifact |
| `ci-validated (evidence-fixture)` → `live-validated` | a real CI run on a **real consumer** with a supported surface and **incidental** (not engineered) findings; see [`live-validation-playbook.md`](live-validation-playbook.md) |
| any → `proven` | engine-class only (self-gated in this repo's blocking self-test) |

**No evidence ⇒ no promotion.** Local-only runs do **not** qualify for `ci-validated`. An evidence
fixture does **not** qualify for `live-validated`.

## Demotion requirements

Demote when evidence is withdrawn, the tool/collector breaks, or a claim is found unsupported:
move the label down, record the reason in the registry, and add/adjust a self-test guard so the
stale claim cannot reappear. Demotion is never silent.

## Caveat requirements

Every non-`proven` label carries explicit caveats (severity coarseness, binary counts, engineered
findings, surface scope). Caveats are part of the registry row, not optional prose.

## Current state (v1.7.0)

- `proven`: engine (resolve/enforce/build/select/install/sync + self-test).
- `live-validated`: CodeQL, OSV, Trivy-fs, Syft, Grype, Dockle, OWASP Dependency-Check, **Deptrac**
  (real consumers; Deptrac also has CI run 27633798174).
- **`ci-validated (evidence-fixture)`**: **Checkov, Terrascan, Conftest** (CI run 27636439883 on
  `sentinel-shield-iac-evidence`). **Not** `live-validated`.
- `manual`: ZAP, Nuclei. `non-gating`: Claude Code review, Kuzushi. `experimental`: Scorecard,
  TruffleHog, Trivy-image.
