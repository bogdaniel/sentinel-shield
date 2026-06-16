# IaC Evidence Guide (v1.2.0)

> **PLANNING ONLY — no maturity change.** This guide describes how to *collect and cite*
> evidence for the IaC scanners (Checkov / Conftest / Terrascan). It does **not** promote
> any of them. They remain **`experimental` / not-applicable** in
> [`product-status.md`](product-status.md) and [`enterprise-scanner-matrix.md`](enterprise-scanner-matrix.md)
> until a real, cited consumer/fixture run is recorded in
> [`main-gate-live-evidence.md`](main-gate-live-evidence.md). Reading or following this guide
> changes **no** labels and adds **no** IaC files to any consumer. Do not fabricate IaC inputs
> to force a pass — `unavailable` is the honest, load-bearing result when there is nothing to scan.

This guide is the evidence-readiness companion to
[`deptrac-iac-promotion-plan.md`](deptrac-iac-promotion-plan.md) (the promotion *path*) and
[`iac-scanner-realism.md`](iac-scanner-realism.md) (the realistic *behavior*). It does not
duplicate them; it explains what an evidence run looks like and how to cite it.

---

## Supported IaC surfaces

Sentinel Shield normalizes IaC misconfiguration findings across three scanners. The surfaces
each scanner applies to (see [`iac-scanner-realism.md`](iac-scanner-realism.md) §152 and
[`iac-security-policy.md`](iac-security-policy.md)):

| Surface | Detected via | Primary scanners |
| --- | --- | --- |
| Terraform | `*.tf`, `*.tf.json` | Checkov, Terrascan |
| Kubernetes manifests | k8s YAML (Deployments, Pods, etc.) | Checkov, Terrascan, Conftest (with Rego) |
| Docker / Compose policy | `docker-compose.yml` / `compose.yml`, Dockerfile policy | Checkov, Conftest (with Rego) |

IaC scanning is **applicable only when the repo actually manages infrastructure declaratively**.
A repo that ships application code only has **no IaC surface**; the dimension stays
`unavailable`/skipped and must not block merges.

---

## Raw report paths

The audit wrappers run each tool *if installed* and write its native JSON:

| Audit wrapper | Raw report |
| --- | --- |
| `scripts/audits/checkov.sh` | `reports/raw/checkov.json` |
| `scripts/audits/conftest.sh` | `reports/raw/conftest.json` |
| `scripts/audits/terrascan.sh` | `reports/raw/terrascan.json` |

If the tool binary is **absent**, the wrapper logs `unavailable` and exits 0 — it does **not**
write a fake-clean report. The collector then reports `status=unavailable`.

---

## Collector mapping → `iac_violations`

Each collector parses the matching raw report and maps the tool-specific finding count onto a
single normalized summary key, `iac_violations`:

| Collector | Reads | Count source | Maps to |
| --- | --- | --- | --- |
| `scripts/collectors/checkov.sh` | `reports/raw/checkov.json` | `.summary.failed`, else length of `.results.failed_checks` | `iac_violations` |
| `scripts/collectors/conftest.sh` | `reports/raw/conftest.json` | sum of `.failures` lengths (array or single-object form) | `iac_violations` |
| `scripts/collectors/terrascan.sh` | `reports/raw/terrascan.json` | length of `.results.violations`, else `.results.scan_summary.violated_policies` | `iac_violations` |

Status is `fail` when `iac_violations > 0`, else `pass`. A missing/empty input yields
`status=unavailable` (via `ss_collector_guard`) — **never** a fabricated `pass`.

**Gating:** `iac_violations` is **advisory in baseline** and **gated in strict / regulated**
(see [`iac-security-policy.md`](iac-security-policy.md) and `strict-mode-readiness.md`). In
strict mode any `iac_violations > 0` should fail; an `unavailable` IaC dimension surfaces the
gap but does not fabricate a pass. In regulated mode IaC is **required** — an `unavailable`
dimension is itself a gate failure, and any violation blocks unless covered by an in-date
accepted risk.

---

## What counts as evidence

A run is **evidence** (not a fixture demo) only when **all** of these hold:

- A real consumer **or** a clearly-labelled controlled fixture has **real IaC** (`*.tf`,
  k8s manifests, or a Compose/Dockerfile policy surface).
- An audit wrapper produced a **valid** `reports/raw/<tool>.json` from an actual scanner run.
- The matching collector **parsed** it and emitted a **known** `iac_violations` count
  (clean `0`, or a specific non-zero count).
- The raw artifact was **uploaded** under `if: always()`.
- **No application code was changed** to manufacture the result, and findings were **not**
  remediated or suppressed to force a pass.
- The run ID + artifact (size, validity) are **cited** in
  [`main-gate-live-evidence.md`](main-gate-live-evidence.md).

A fixture-only run (e.g. the `tests/fixtures/iac-v024/*-findings.json` inputs described in
[`iac-scanner-realism.md`](iac-scanner-realism.md)) proves the collectors parse correctly but is
**not** live evidence. The live-evidence registry is never updated from fixtures alone.

---

## Promotion criteria

A scanner is promoted from `experimental` / not-applicable only when a **real cited
consumer/fixture run** exists where a collector parsed a **valid** IaC report with a **known**
violation count, and that run is recorded in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). See the IaC evidence checklist in
[`deptrac-iac-promotion-plan.md`](deptrac-iac-promotion-plan.md). Until then, **no maturity
upgrade** is made in `product-status.md` / `enterprise-scanner-matrix.md` — those defer to the
live-evidence registry.

---

## Optional evidence workflow (sketch — DESCRIBE only; do not add a workflow)

The following is a *description* of what an evidence-collection job would do. It is intentionally
**not** a real workflow file and must not be committed as one without a separate, reviewed change.

```txt
job: iac-evidence (illustrative; not a committed workflow)
  on a runner / consumer that genuinely has IaC:
    1. install checkov / conftest / terrascan (prefer pinned, digest-pinned actions or containers)
    2. run the audit wrappers:
         sh scripts/audits/checkov.sh    reports/raw/checkov.json
         sh scripts/audits/conftest.sh   reports/raw/conftest.json   # needs policy/ Rego rules
         sh scripts/audits/terrascan.sh  reports/raw/terrascan.json
    3. run the collectors:
         sh scripts/collectors/checkov.sh   --input reports/raw/checkov.json
         sh scripts/collectors/conftest.sh  --input reports/raw/conftest.json
         sh scripts/collectors/terrascan.sh --input reports/raw/terrascan.json
    4. upload reports/raw/{checkov,conftest,terrascan}.json   # if: always()
    5. record run ID + artifact (size, validity) in main-gate-live-evidence.md
constraints:
    - no application code changed; findings NOT remediated or suppressed to force a pass
    - absent tool / no IaC -> unavailable is expected and acceptable (never fake-clean)
```

---

## Troubleshooting

- **Tool not installed.** The wrapper logs `... not installed; skipping` and exits 0; the
  collector reports `status=unavailable, iac_violations=0`. An `iac_violations=0` paired with
  `unavailable` must **never** be read as "clean". Prefer a pinned GitHub Action / container in
  CI (see `templates/workflows/`).
- **No IaC files present.** The audit produces no scanner input and skips; the collector reports
  `unavailable`. This is correct — the IaC dimension is skipped, not failed and not fake-passed.
- **Invalid / empty JSON.** A missing or empty input yields `unavailable` via
  `ss_collector_guard`. A malformed non-empty report that `jq` cannot parse to an integer count
  causes the collector to error (non-integer count → exit 2); re-run the scanner and validate the
  JSON rather than editing the count.
- **Conftest needs policies.** Conftest evaluates structured config against **Rego** rules. With
  no `policy/` rules configured it has nothing to assert and is effectively skipped — supply
  policies that `deny` the conditions you care about (privileged containers, host networking,
  missing resource limits, etc.) before treating its output as evidence.

---

## False positives & consumer-owned policy / exceptions

IaC policy and its exceptions are **consumer-owned**. Sentinel Shield **normalizes and gates**
the findings (`iac_violations`); it does **not** own the policy set:

- The **Conftest / OPA policies**, **accepted-risk records**, and tuning all belong to the
  consuming project. SS keys its gate off the normalized count produced by *their* policies.
- **False positives** are resolved by **consumer policy tuning** (narrow, per-resource /
  per-rule suppression with a justification) or by a recorded **accepted risk** — never by a
  blanket rule disable, by deleting the source/fixture, or by forcing the collector to `pass`.
- An accepted risk is an **owner-bound, reasoned, expiry-dated** record (see
  [`accepted-risk-suppression.md`](accepted-risk-suppression.md)). The raw finding count is
  preserved and the suppression is reported; stale records re-block via `expired_exceptions`.

See [`iac-scanner-realism.md`](iac-scanner-realism.md) §156–157 for accepted-risk and
false-positive triage detail, and [`iac-security-policy.md`](iac-security-policy.md) for the
policy/exception ownership boundary.
