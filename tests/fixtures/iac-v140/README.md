# IaC v1.4.0 fixtures — provenance

Derived from **real local scanner runs** against the public, intentionally-insecure repo fixture
`tests/fixtures/iac-v024/terraform/insecure.tf`. See [`../../../docs/iac-local-evidence-v140.md`](../../../docs/iac-local-evidence-v140.md).

| File | Source | Collector result |
|---|---|---|
| `checkov-real-derived.json` | Checkov 3.3.1 (`pip`), `.summary`+`.results` trimmed to representative findings; real `.summary.failed=16` preserved | `fail` / `iac_violations=16` |
| `terrascan-real.json` | Terrascan 1.19.9, verbatim (absolute paths sanitized to repo-relative) | `fail` / `iac_violations=4` |
| `conftest-plan-real.json` | Conftest 0.56.0 + real `policies/opa/terraform.rego`, `--namespace sentinel.terraform`, plan-JSON input | `fail` / `iac_violations=2` |
| `conftest-hcl-namespace-miss.json` | Conftest run reproducing the v1.3.0 "no output" miss (HCL input, default namespace) | `pass` / `iac_violations=0` |
| `tfplan-synthetic.json` | **Synthetic** `terraform show -json`-shaped input (Terraform not installed); policy-conformant input only | — (input) |

**No promotion.** These are local tool-execution fixtures, not consumer-CI evidence. No secrets,
no consumer data, no absolute local paths. Guarded by `scripts/self-test.sh v140-iac`.
