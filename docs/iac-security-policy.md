# IaC Security Policy (v0.1.14)

Infrastructure-as-Code scanning (Checkov, Conftest/OPA, Terrascan) → `iac_violations`
(strict+ gating; see resolve-gates.sh). Findings are misconfigurations in IaC, distinct from
container lint (`unsafe_docker`) and image checks (`container_image_violations`).

## When it runs
Only when IaC files exist: `*.tf`, `*.tf.json`, Kubernetes manifests, Helm charts,
`docker-compose.yml`/`compose.yml`, and `.github/workflows/*.yml`. **No IaC files → tool
unavailable/skipped, NOT fake-clean** (the audit wrappers no-op; collectors report unavailable).

## Tools & mapping
| Tool | Audit | Raw | Maps to |
|---|---|---|---|
| Checkov | `audits/checkov.sh` | checkov.json | iac_violations |
| Conftest/OPA | `audits/conftest.sh` | conftest.json | iac_violations |
| Terrascan | `audits/terrascan.sh` | terrascan.json | iac_violations |

## Triage & exceptions
Triage: [`remediation/iac-finding-triage.md`](remediation/iac-finding-triage.md). Time-boxed,
owner-approved exceptions: [`templates/iac-exception-request.md`](../templates/iac-exception-request.md).
Maturity: **experimental** until live-validated (v0.1.15).
