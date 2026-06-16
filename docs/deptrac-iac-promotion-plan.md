# Deptrac / IaC Consumer-Evidence Promotion Plan (v1.1.0)

> **Status: PLANNING ONLY — no maturity change.** Per the contract, a tool is promoted to
> `live-validated` **only** when a real `reports/raw/*` artifact from a real consumer is cited and its
> collector parsed it ([`main-gate-live-evidence.md`](main-gate-live-evidence.md)). Deptrac and the IaC
> scanners (Checkov / Conftest / Terrascan) remain **`experimental` / not-configured** until that
> evidence exists. This doc defines the path; it does **not** upgrade any maturity label.

## Why they are not promoted yet

| Tool | Gate key | Current status | Blocker |
|---|---|---|---|
| Deptrac | `architecture_violations` | `experimental` / not-configured | no consumer with a `deptrac.yaml` (defined layers) has a cited run |
| Checkov / Conftest / Terrascan | `iac_violations` | `experimental` / not-applicable | no consumer with IaC (Terraform/K8s/Dockerfile policy) has a cited run |

## Candidate projects

- **Deptrac:** a layered PHP/Laravel or Symfony consumer that already defines architecture layers.
  `zenchron-tools` is a candidate **only if** it adds a `deptrac.yaml` (it does not have one today — do
  not invent one to force a pass). Otherwise a dedicated layered fixture project.
- **IaC:** a repo with real `*.tf` (Terraform), Kubernetes manifests, or a Dockerfile policy surface.
  No current pilot has IaC; a controlled IaC fixture repo is the realistic first source.

## Deptrac evidence checklist

```txt
[ ] consumer has a real deptrac.yaml with defined layers + ruleset
[ ] run scripts/runners/deptrac.sh -> reports/raw/deptrac.json (valid JSON, real violations or clean)
[ ] scripts/collectors/deptrac.sh --input reports/raw/deptrac.json parses it
[ ] summary mapping: architecture_violations = count of rule violations
[ ] artifact uploaded if: always(); no app code changed; findings NOT remediated/suppressed
[ ] cite run ID + artifact (size, validity) in main-gate-live-evidence.md
```

- **Expected raw path:** `reports/raw/deptrac.json`
- **Collector mapping:** `deptrac.sh` → `architecture_violations` (baseline + strict + regulated gate it)
- **Promotion criteria:** a real cited consumer run where the collector parses a valid `deptrac.json`
  with a known violation count (clean or non-zero). Until then: `experimental`.

## IaC (Checkov / Conftest / Terrascan) evidence checklist

```txt
[ ] consumer/fixture has real IaC (*.tf, k8s yaml, or policy surface)
[ ] run the audit wrapper(s):
      scripts/audits/checkov.sh    -> reports/raw/checkov.json
      scripts/audits/conftest.sh   -> reports/raw/conftest.json
      scripts/audits/terrascan.sh  -> reports/raw/terrascan.json
[ ] validate JSON; collectors parse:
      scripts/collectors/checkov.sh / conftest.sh / terrascan.sh -> iac_violations
[ ] strict gates iac_violations; baseline does NOT (severity-policy)
[ ] artifact uploaded if: always(); no app code changed; findings NOT remediated/suppressed
[ ] cite run ID + artifact in main-gate-live-evidence.md
```

- **Expected raw paths:** `reports/raw/{checkov,conftest,terrascan}.json`
- **Collector mapping:** each → `iac_violations` (gated in **strict**/regulated; advisory in baseline)
- **Promotion criteria:** a real cited consumer/fixture run where a collector parses a valid IaC report
  with a known violation count. Until then: `experimental` / not-applicable.

## Honesty guardrails (carry into any future promotion PR)

- No maturity upgrade in `product-status.md` / `enterprise-scanner-matrix.md` without the cited run ID.
- The wrappers report `unavailable` (not fake-clean) when the tool/config is absent — that stays true.
- Do not add a `deptrac.yaml` or IaC files to a consumer just to manufacture a pass; use a consumer
  that genuinely has them, or a clearly-labelled controlled fixture.
- These are gated by the existing self-test collector mappings; promotion adds **evidence**, not a
  behavior change to the STABLE contract.
