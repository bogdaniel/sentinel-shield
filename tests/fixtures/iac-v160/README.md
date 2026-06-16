# IaC v1.6.0 fixtures — provenance (real CI artifacts)

Derived from the **real CI run** in the dedicated evidence-consumer repo
`bogdaniel/sentinel-shield-iac-evidence`
([design](../../../docs/iac-evidence-consumer-design.md)), workflow `iac-evidence`,
**run 27636439883** (all jobs success).

| File | Source artifact | Tool | Collector result |
|---|---|---|---|
| `checkov-ci.json` | `checkov.json` (real `.summary` kept; `results` trimmed; abs paths → `/main.tf`) | Checkov **3.3.1** (`--framework terraform`) | `fail` / `iac_violations=27` |
| `terrascan-ci.json` | `terrascan.json` (runner abs dir → `terraform/aws`) | Terrascan **1.19.9** | `fail` / `iac_violations=8` |
| `conftest-ci.json` | `conftest-report.json` (verbatim; already clean) | Conftest **0.56.0** / OPA 0.69.0 | `fail` / `iac_violations=5` |

Sanitized: no `/home/runner` paths, no account IDs, no credentials. The IaC scanned is the
intentionally-insecure (non-deployed) evidence fixture. Guarded by `scripts/self-test.sh v160-iac`.

**Tier:** these support the **`ci-validated (evidence-fixture)`** maturity tier — real CI run +
artifact + collector mapping, but engineered findings on a dedicated fixture, **not** third-party
production `live-validated`.
