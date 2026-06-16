# IaC Local Tool-Execution Evidence (v1.4.0)

> **Maturity status: UNCHANGED. Checkov / Conftest / Terrascan remain `experimental`.**
> This document records **real local tool-execution evidence** — actual scanner binaries run
> against the repo's committed IaC fixtures, producing real artifacts that the real collectors
> parsed. It is the same class of evidence as [`live-evidence-v025.md`](live-evidence-v025.md):
> a **local** validation, **NOT** a consumer-CI promotion. The project defines `live-validated`
> as a cited run on a **real consumer in CI** (see [`product-status.md`](product-status.md)
> §"Maturity vocabulary"). No such run exists for IaC, so **nothing is promoted here.**

## Why this matters

v1.3.0 attempted IaC evidence and got **nothing usable** (Checkov image parsed 0 resources;
Terrascan had no `hcloud` policies; Conftest produced no output — see
[`main-gate-live-evidence.md`](main-gate-live-evidence.md)). v1.4.0 closes the **diagnostic** gap:
with the scanners installed via their *supported* execution paths (not the broken image), all three
parse real Terraform and the collectors map their output correctly. This pins each v1.3.0 blocker to
a **root cause** and gives the next consumer-CI attempt a known-good command set.

## Environment

| Tool | Version | Install path | Notes |
|---|---|---|---|
| Checkov | **3.3.1** | `pip install checkov` (Python 3.13 venv) | **Not** the Docker image that failed in v1.3.0 |
| Terrascan | **1.19.9** | `tenable/terrascan` Darwin arm64 release binary | built-in AWS/Azure/GCP/k8s policies |
| Conftest | **0.56.0** (OPA 0.69.0) | `open-policy-agent/conftest` Darwin arm64 binary | uses the repo's real Rego in `policies/opa/` |

Scanned surface: the committed, intentionally-insecure fixture
`tests/fixtures/iac-v024/terraform/insecure.tf` (public-read S3 bucket + 0.0.0.0/0 SSH security
group). No consumer code, no private data, no network IaC. Raw artifacts were kept in gitignored
scratch; **derived, sanitized** fixtures are committed under `tests/fixtures/iac-v140/`.

## Evidence

| Tool | Command | Raw result | Collector → `iac_violations` | Committed fixture |
|---|---|---|---|---|
| **Checkov 3.3.1** | `checkov -d tests/fixtures/iac-v024/terraform -o json` | **3 resources, 16 failed, 7 passed, 0 parsing_errors** | `fail` / **16** | `iac-v140/checkov-real-derived.json` |
| **Terrascan 1.19.9** | `terrascan scan -d <tf> -i terraform -o json` | **4 violations (4 high)** | `fail` / **4** | `iac-v140/terrascan-real.json` |
| **Conftest 0.56.0** | `conftest test --policy policies/opa/terraform.rego --namespace sentinel.terraform <plan.json>` | **2 failures** (S3 public ACL, SSH 0.0.0.0/0) | `fail` / **2** | `iac-v140/conftest-plan-real.json` |
| **Conftest (blocker repro)** | `conftest test --policy policies/opa/terraform.rego <insecure.tf>` | **0 failures** (HCL input, default `main` namespace) | `pass` / **0** | `iac-v140/conftest-hcl-namespace-miss.json` |

All four artifacts re-verified through the unmodified collectors
(`scripts/collectors/{checkov,terrascan,conftest}.sh`) and guarded by `self-test.sh v140-iac`.

## v1.3.0 blocker → root cause (diagnostic closure)

- **Checkov "`resource_count: 0`"** → the **Docker image** was not analyzing Terraform.
  A `pip`-installed Checkov 3.3.1 parses the same TF as **3 resources / 16 findings / 0 parsing
  errors**. The wrapper, collector, and fixture were never at fault. **Fix path:** run Checkov via
  `pip`/the official GitHub Action, not the previously-tried image. See
  [`troubleshooting.md`](troubleshooting.md#checkov-resource_count-0).
- **Terrascan "0/0 policies"** → was **`hcloud`-specific** (Terrascan ships no Hetzner policies).
  On **AWS** Terraform it reports **4 high violations**. **Fix path:** point Terrascan at an
  AWS/Azure/GCP/k8s surface; `hcloud` is genuinely unsupported (documented limitation).
- **Conftest "no output"** → **namespace + input-shape mismatch**. `policies/opa/terraform.rego`
  is `package sentinel.terraform` and reads `input.resource_changes` (the `terraform show -json`
  **plan** shape). Running it against raw HCL in the default `main` namespace yields 0. With
  `--namespace sentinel.terraform` against plan-JSON it produces **2 real failures**. **Fix path:**
  feed `terraform show -json` plan output and select the policy namespace.

## What this does and does NOT establish

- ✅ The Checkov/Terrascan/Conftest **wrappers and collectors correctly map real scanner output**
  to `iac_violations` (both violation and clean paths).
- ✅ The exact **known-good commands** for the next consumer-CI evidence run are now recorded.
- ✅ The v1.3.0 blockers are **diagnosed**, not hand-waved.
- ❌ This is **not** a consumer-CI run; there is **no run ID** and **no consumer artifact**.
- ❌ Therefore **no maturity promotion**. Checkov/Conftest/Terrascan stay `experimental`.
- ⚠️ The Conftest plan-JSON input is a **synthetic, policy-conformant fixture**
  (`iac-v140/tfplan-synthetic.json`), not the output of a real `terraform plan` (Terraform is not
  installed here). It exercises the *real* Rego; it does not prove a real plan pipeline.

## Next evidence (to promote IaC to `live-validated`)

1. On a real consumer with AWS/Azure/GCP/k8s IaC, run Checkov via `pip`/Action in CI; download
   `checkov.json`; confirm `checkov.sh` maps it; cite the run ID in
   [`main-gate-live-evidence.md`](main-gate-live-evidence.md).
2. Same for Terrascan on a supported provider.
3. For Conftest, wire `terraform plan -out … && terraform show -json` → `conftest test
   --namespace sentinel.terraform`; cite the run.

Until a cited consumer-CI run exists, IaC is **not promoted**.
