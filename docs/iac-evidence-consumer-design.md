# IaC Evidence-Consumer Design (v1.6.0 — Agent A)

Defines the **dedicated evidence-consumer** that unblocks IaC scanner evidence. Sentinel Shield
itself has no active CI (its `github/` workflows are templates), and the only real IaC consumer
(`zenchron-infra`) is Hetzner `hcloud` (unsupported). v1.6.0 closes that gap with a purpose-built,
**non-deployable** evidence repo on a supported surface.

## Repo

- **`bogdaniel/sentinel-shield-iac-evidence`** (public) — separate from `sentinel-shield`, clearly
  marked as an **evidence-only fixture repo** (per the evidence-consumer rule). Not a product, not a
  real consumer.

## No-deploy policy (hard)

- **No cloud credentials** anywhere — no provider auth, no backend/state, `skip_credentials_validation`.
- **No deploy step** — CI runs **static scanners only**; no `terraform apply`, no `kubectl apply`,
  no `plan` against a real account.
- **Intentionally insecure, labeled** — misconfigurations are deliberate so scanners have real
  findings; every file is headed `EVIDENCE-ONLY … NEVER DEPLOY`.
- **No real account IDs / secrets** — identifiers are placeholders.

## Supported IaC surfaces

| Surface | Path | Scanners |
|---|---|---|
| AWS Terraform | `terraform/aws/main.tf` | Checkov (`--framework terraform`), Terrascan |
| Kubernetes | `kubernetes/deployment.yaml` | Conftest (real Rego), Checkov (k8s) |
| OPA/Rego policy | `policy/kubernetes.rego` | Conftest |

AWS + Kubernetes chosen because Checkov/Terrascan/Conftest policies are mature there (unlike `hcloud`).

## Artifact paths + CI shape

One workflow `.github/workflows/iac-evidence.yml`, **three independent jobs**, each uploads raw JSON
(`if: always()`, 30-day retention):

| Job | Command | Artifact |
|---|---|---|
| checkov | `checkov -d terraform/aws --framework terraform -o json` | `checkov-evidence/checkov.json` |
| terrascan | `terrascan scan -d terraform/aws -i terraform -o json` | `terrascan-evidence/terrascan.json` |
| conftest | `conftest test kubernetes/deployment.yaml -p policy -o json` | `conftest-evidence/conftest.json` |

`--framework terraform` keeps Checkov's output a **single object** (the collector cannot index the
multi-framework array). Actions pinned by SHA (checkout, upload-artifact).

## Scanner versions

Checkov 3.3.x (`pip`), Terrascan 1.19.9 (pinned release binary), Conftest 0.56.0 / OPA 0.69.0
(pinned release binary).

## Promotion criteria (per tool)

Promote out of `experimental` to the **`ci-validated (evidence-fixture)`** tier only when ALL exist:
tool+version, the evidence repo/context, a real **CI run ID**, the raw artifact, the collector
result, the mapped key (`iac_violations`), pass/fail behavior, and caveats. See
[`main-gate-live-evidence.md`](main-gate-live-evidence.md).

## Privacy model

The IaC is synthetic and public; no consumer data, no credentials. Raw artifacts may be downloaded
locally for verification; only **sanitized/derived** fixtures (counts/structure, no host paths) are
committed into `sentinel-shield` under `tests/fixtures/iac-v160/`.

## Maturity honesty

This is a **dedicated evidence fixture**, so findings are **engineered** (we authored the insecure
IaC). Evidence from it earns the **`ci-validated (evidence-fixture)`** tier — strictly stronger than
v1.4.0 local runs (real CI, run ID, artifact), but **explicitly NOT** the third-party-production
`live-validated` tier used for CodeQL/OSV/Grype/Dockle/Dependency-Check/Deptrac. It validates the
**tool → collector → gate pipeline in CI**, not real-world consumer coverage.
