# IaC Scanner Realism (v0.1.24)

Sentinel Shield ships Infrastructure-as-Code (IaC) scanning as an
**experimental, opt-in** capability. This document records the realistic
behaviour of the checkov / conftest / terrascan collectors, how the bundled
v0.1.24 fixtures exercise them, and the onboarding / gating guidance that goes
with them.

Honesty contract: IaC scanners only run when the matching binary is installed
**and** the repository is configured for them. When a scanner binary is absent,
the collector reports `unavailable` — it never emits a fake `pass`. A `pass`
means the tool ran and found nothing; `unavailable` means we could not assert
anything. These are deliberately distinct.

All collectors map their tool-specific finding count onto a single normalized
summary key: `iac_violations`.

---

## Fixtures

The v0.1.24 IaC fixtures live under `tests/fixtures/iac-v024/`:

| Path | Purpose |
| --- | --- |
| `terraform/insecure.tf` | Public-read S3 bucket + open (0.0.0.0/0:22) security group. |
| `k8s/insecure-deployment.yaml` | Privileged container, runs as root, host network/PID, no resource limits. |
| `compose/insecure-compose.yml` | `privileged: true`, host network/PID, Docker socket mount, `cap_add: ALL`. |
| `checkov-findings.json` | Valid checkov output: `summary.failed = 3` with 3 matching `results.failed_checks`. |
| `conftest-findings.json` | Conftest array form: one result object with 3 `failures`. |
| `terrascan-findings.json` | Terrascan output: `results.violations` with 3 entries. |

The three source files (`.tf` / `.yaml` / `.yml`) are the *inputs* a real
scanner would analyze; the three `*-findings.json` files are pre-captured
*outputs* in each tool's native schema, used to drive the collectors
deterministically in CI without requiring the scanner binaries.

---

## 147 — checkov collector expectation

Collector: `scripts/collectors/checkov.sh`.

It reads `.summary.failed` if present, else falls back to the length of
`.results.failed_checks`, and writes that integer to `summary.iac_violations`.
Status is `fail` when the count is > 0, else `pass`.

Observed against the fixture:

```
$ sh scripts/collectors/checkov.sh --input tests/fixtures/iac-v024/checkov-findings.json
{"tool":"checkov","status":"fail","iac_violations":3}
```

Expectation: **`iac_violations = 3`, `status = fail`.**

## 148 — conftest collector expectation

Collector: `scripts/collectors/conftest.sh`.

Conftest emits a top-level JSON array; each element carries a `failures` array.
The collector sums the lengths of every `failures` array (handling both the
array and single-object forms) into `summary.iac_violations`.

Observed against the fixture:

```
$ sh scripts/collectors/conftest.sh --input tests/fixtures/iac-v024/conftest-findings.json
{"tool":"conftest","status":"fail","iac_violations":3}
```

Expectation: **`iac_violations = 3`, `status = fail`.**

## 149 — terrascan collector expectation

Collector: `scripts/collectors/terrascan.sh`.

It reads the length of `.results.violations` if present, else falls back to
`.results.scan_summary.violated_policies`, and writes that to
`summary.iac_violations`.

Observed against the fixture:

```
$ sh scripts/collectors/terrascan.sh --input tests/fixtures/iac-v024/terrascan-findings.json
{"tool":"terrascan","status":"fail","iac_violations":3}
```

Expectation: **`iac_violations = 3`, `status = fail`.**

## 150 — no IaC files present

When a repository contains no IaC files (no Terraform, Kubernetes manifests, or
Compose files), the corresponding audit produces no scanner input. The audit
scripts (`scripts/audits/{checkov,conftest,terrascan}.sh`) skip the scan, and
the collector — given a missing/empty input — reports `unavailable` (with a
`status=unavailable` warning on stderr). The IaC dimension is therefore
**skipped / unavailable**, not failed and not a fake pass.

## 151 — scanner binary not installed

When the scanner binary itself is not on `PATH` (the default for the bundled
test environment, where checkov / conftest / terrascan are not installed), the
audit produces no report file, and `ss_collector_guard` emits:

```
{"tool":"checkov","status":"unavailable","iac_violations":0}
```

This is the load-bearing honesty rule: **no binary → `unavailable`, never a
fabricated `pass`.** An `iac_violations` count of `0` paired with status
`unavailable` must never be interpreted as "clean".

## 152 — IaC scanner applicability

IaC scanning is applicable only when a repository actually manages
infrastructure declaratively. Use this matrix:

| Scanner | Applies to | Skip when |
| --- | --- | --- |
| checkov | Terraform, CloudFormation, Kubernetes, Helm, ARM, Compose | No IaC files of those kinds. |
| terrascan | Terraform (primary), Kubernetes, Helm, Compose | No Terraform / supported manifests. |
| conftest | Any structured config evaluated against Rego policies | No `policy/` Rego rules configured. |

If a project ships application code only (no IaC), the IaC dimension should
remain `unavailable`/skipped and must not block merges.

## 153 — Terraform onboarding

1. Install checkov (`pipx install checkov`) and/or terrascan.
2. Point the audit at the Terraform root (e.g. `tests/fixtures/iac-v024/terraform`).
3. Run the scanner with JSON output into `reports/raw/<tool>.json`.
4. Run the matching collector; confirm `iac_violations` reflects real findings.
5. Triage findings (see 157), record accepted risks (see 156), then enforce a
   gate appropriate to your profile (see 158 / 159).

The fixture `terraform/insecure.tf` is a known-bad baseline: a correctly
configured checkov/terrascan run should report multiple violations against it.

## 154 — Kubernetes onboarding

1. Install checkov and/or conftest with a Kubernetes Rego policy bundle.
2. Target the manifest directory (e.g. `tests/fixtures/iac-v024/k8s`).
3. For conftest, supply `policy/` rules that `deny` privileged containers,
   missing resource limits, host networking, etc.
4. Emit JSON, run the collector, and verify the `iac_violations` count.

`k8s/insecure-deployment.yaml` deliberately trips privileged-container,
run-as-root, host-network, and missing-resource-limit policies.

## 155 — Compose onboarding

1. Install checkov (Compose support) and/or conftest with Compose policies.
2. Target the Compose file (e.g. `tests/fixtures/iac-v024/compose`).
3. Emit JSON, run the collector, verify the count.

`compose/insecure-compose.yml` deliberately trips privileged, host-network,
host-PID, `cap_add: ALL`, and Docker-socket-mount checks.

## 156 — IaC accepted-risk guidance

Some findings are deliberate and acceptable (e.g. a public bucket that fronts a
static website). Record each accepted risk explicitly:

- Suppress at the source with the tool's inline mechanism (e.g. checkov
  `#checkov:skip=CKV_AWS_20:public website bucket, owner-approved`).
- Capture owner, justification, and an expiry/review date in the project's
  exceptions register so it surfaces under `expired_exceptions` when stale.
- Never silence a finding by deleting the fixture/source or by forcing the
  collector to `pass`; accepted risk is tracked, not hidden.

## 157 — IaC false-positive triage

1. Reproduce: re-run the scanner on the exact file and confirm the rule fires.
2. Classify: is the resource a real exposure, a fixture/test artifact, or a
   pattern the rule misreads?
3. For genuine false positives, suppress narrowly (per-resource, per-rule) with
   a justification — never a blanket disable of the rule across the repo.
4. For test fixtures (like those under `tests/fixtures/iac-v024/`), scope the
   scanner to production paths so intentionally-insecure fixtures are excluded.
5. Re-run the collector and confirm `iac_violations` reflects the corrected
   set.

## 158 — Strict-mode IaC gate criteria

In strict mode, IaC scanning is advisory-to-enforcing:

- If a scanner is configured and runs, any `iac_violations > 0` is reported and
  **should fail** the strict gate (HIGH/CRITICAL violations are blocking).
- If the scanner is `unavailable` (no binary / not configured), strict mode
  treats IaC as not-yet-onboarded: it surfaces the gap but does not fabricate a
  pass. Teams adopting strict mode are expected to onboard at least one IaC
  scanner.
- A fixture-driven `iac_violations = 3 / status = fail` (as above) is exactly
  the signal the strict gate keys on.

## 159 — Regulated-mode IaC gate criteria

Regulated mode is the strictest profile:

- IaC scanning is **required**, not optional. An `unavailable` IaC dimension is
  itself a gate failure (the control is mandated; absence is non-compliance).
- Any `iac_violations > 0` blocks unless covered by a recorded, in-date accepted
  risk (see 156). Expired exceptions re-block via `expired_exceptions`.
- Evidence (raw scanner JSON + collector output) must be retained for audit.

## 160 — Maturity note

IaC scanning in Sentinel Shield is **experimental** as of v0.1.24. The
collectors and normalization (`iac_violations`) are stable and tested via the
fixtures here, but:

- Scanner binaries are not bundled or installed by default; the default
  environment reports `unavailable`.
- Coverage depends on the user installing and configuring checkov / conftest /
  terrascan and supplying policies (especially for conftest).
- Treat IaC results as informative until your team has completed onboarding
  (153–155) and chosen an enforcement profile (158 / 159).

Do not represent the experimental IaC dimension as production-hardened, and
never convert an `unavailable` result into a `pass`.
