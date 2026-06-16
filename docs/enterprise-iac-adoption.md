# Enterprise IaC Adoption & Scale (v1.6.0 — Agent H)

How enterprise/multi-team adopters wire Sentinel Shield's IaC gate without changing defaults. **No
default behavior changes**; everything here is opt-in. Engine stays `proven`.

## Supported vs unsupported IaC providers

| Provider / surface | Checkov | Terrascan | Conftest | Notes |
|---|---|---|---|---|
| AWS Terraform | ✅ mature | ✅ mature | ✅ (plan-JSON or AWS rego) | best-supported surface |
| Azure / GCP Terraform | ✅ | ✅ | ✅ (with policy) | mature policy coverage |
| Kubernetes YAML | ✅ | ✅ | ✅ (native YAML) | strong; Conftest ideal |
| Helm | ✅ (rendered) | ⚠️ render first | ✅ (rendered) | render templates before scanning |
| **Hetzner `hcloud`** | ⚠️ minimal | ❌ no policies | ⚠️ needs custom rego | **unsupported for promotion** (see v1.5.0) |

Rule of thumb: if your IaC is **AWS/Azure/GCP/Kubernetes**, the gate has real coverage. Niche
providers (e.g. `hcloud`) need custom policy and will not produce meaningful `iac_violations`
out of the box — Sentinel Shield reports `unavailable`/0 honestly rather than faking a clean pass.

## The evidence-consumer pattern

Validate the IaC pipeline against a **dedicated, non-deployable evidence repo** before trusting it
on production IaC — exactly what `sentinel-shield-iac-evidence` does
([`iac-evidence-consumer-design.md`](iac-evidence-consumer-design.md)): intentionally-insecure
AWS+k8s, static scanners only, no credentials, real CI run IDs. Teams can copy this pattern to
sanity-check coverage before gating real infra.

## Bring your own IaC repo

1. Point Checkov/Terrascan at your Terraform dir; point Conftest at k8s YAML or `terraform show -json`
   plan output with your Rego.
2. Run them in an **evidence-only** workflow first (`if: always()` artifact upload, no gate).
3. Download the JSON; confirm `scripts/collectors/{checkov,terrascan,conftest}.sh` map to
   `iac_violations`.
4. Only then enable the `iac_violations` gate (strict+/regulated, or `if IaC`).
5. IaC findings are **consumer-owned** — Sentinel Shield never suppresses or remediates them.

## Multi-team adoption checklist

- [ ] Each team installs in `report-only` first (`install-baseline.sh --mode report-only`).
- [ ] PR-fast gate wired + pinned (proven).
- [ ] IaC surface identified and confirmed supported (table above).
- [ ] Evidence-only IaC run produces a parseable artifact + collector mapping.
- [ ] `accepted-risks.json` owned per team; never auto-created.
- [ ] Promote to `baseline` → `strict` per team readiness, not globally.

## Scanner maturity checklist (before relying on a gate)

- [ ] Tool has a cited run (run ID / reproducible command).
- [ ] Raw artifact downloaded + collector-verified.
- [ ] Severity caveats understood (IaC = count, not graded; OSV/CodeQL coarse).
- [ ] Maturity tier read from [`product-status.md`](product-status.md) (source of truth).

## Regulated-team rollout

- Use `regulated` mode only when audit evidence is required; keep DAST/AI manual/non-gating.
- Pin every scanner image/action by digest/SHA ([`enterprise-hardening.md`](enterprise-hardening.md)
  + the hardened snippet's v1.4.0 operational block).
- Retain evidence artifacts (`retention-days`) for the audit window.

## Supportability

Symptom → cause → fix for IaC scanners lives in
[`troubleshooting.md`](troubleshooting.md#iac-checkov--terrascan--conftest). Maturity tiers and the
exact evidence basis (incl. the `ci-validated (evidence-fixture)` tier) are in
[`product-status.md`](product-status.md) and [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
