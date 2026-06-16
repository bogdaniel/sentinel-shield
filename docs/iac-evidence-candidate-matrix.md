# IaC Evidence Candidate Matrix (v1.4.0 — A01)

Maps the IaC surfaces available to Sentinel Shield against the scanners that can actually parse
them, so the next consumer-CI evidence run targets a **scanner/surface pair that works** rather
than repeating the v1.3.0 dead-ends. This is a **planning** document — it promotes nothing.

## Surfaces present in this repo (fixtures only — no production IaC)

| Surface | Path | Provider | Parseable by |
|---|---|---|---|
| Terraform (insecure) | `tests/fixtures/iac-v024/terraform/insecure.tf` | AWS | Checkov ✅, Terrascan ✅, Conftest (via plan-JSON) ✅ |
| Terraform (minimal) | `tests/fixtures/iac/terraform/main.tf` | AWS | Checkov ✅, Terrascan ✅ |
| Kubernetes manifest | `tests/fixtures/iac-v024/k8s/insecure-deployment.yaml` | k8s | Checkov ✅, Terrascan ✅, Conftest ✅ |
| Docker Compose | `tests/fixtures/iac-v024/compose/insecure-compose.yml` | compose | Checkov (partial), Conftest ✅ |
| Rego policies | `policies/opa/{terraform,docker,production-env,github-actions}.rego` | OPA | Conftest ✅ |

## Scanner suitability (validated locally — see `iac-local-evidence-v140.md`)

| Scanner | Best surface | Works? | Known gap |
|---|---|---|---|
| **Checkov** | Terraform / k8s | ✅ via `pip`/Action | the Docker image tried in v1.3.0 did **not** parse TF |
| **Terrascan** | AWS/Azure/GCP/k8s Terraform | ✅ | **no `hcloud` policies** (Hetzner unsupported) |
| **Conftest** | `terraform show -json` plan, k8s YAML, compose | ✅ | needs correct `--namespace`; HCL needs plan-JSON for the TF rego |

## Unsupported / gap providers

- **Hetzner (`hcloud`)** — Terrascan ships no policies; Checkov coverage minimal. The v1.3.0
  consumer (`zenchron-infra`) is `hcloud`-based → genuinely a poor IaC-evidence target.
- A real consumer-CI promotion needs an **AWS/Azure/GCP/k8s** surface.

## Recommended scanner/surface pair for the next promotion attempt

**Checkov on AWS/k8s Terraform via the official GitHub Action**, artifact `checkov.json` →
`checkov.sh`. Highest signal, simplest execution path, no plan-pipeline dependency. Terrascan
(AWS) is a strong second. Conftest needs the plan-JSON wiring first.

## Acceptance criteria for promotion (per tool)

- Real consumer, real CI run ID recorded in [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
- Valid downloaded artifact (`reports/raw/*.json`), parsed by the collector.
- Caveat documented (severity coarseness, namespace, provider scope).
- No fake-clean: a tool that cannot run reports `unavailable`, never `pass`.

False positives and consumer-owned exceptions are governed by
[`accepted-risk-suppression.md`](accepted-risk-suppression.md) (broad `scope:gate` for
`iac_violations`); the **consumer** owns IaC remediation, not Sentinel Shield.
