# Enterprise Buyer Pack (v1.7.0 — Agent F)

For platform leads, security architects, and procurement evaluating Sentinel Shield. Deliberately
conservative and evidence-first.

## What it is

A **reusable release-gate engine + security/quality baseline**. It owns a deterministic gate engine
(`resolve-gates` → `enforce-gates` → `build-security-summary` → `select`), a normalized finding
contract (`security-summary.json` + JSON Schema), collectors/runners/adapters, profile-driven
install/sync, accepted-risk governance, workflow templates, and a blocking self-test.

## What it is NOT

- **Not a bundled scanner suite** — it normalizes/gates scanner output; you run the scanners.
- **Not "30 scanners all proven"** — most are `supported`/`experimental`/`ci-validated`.
- **Not turnkey/zero-config** — needs a profile, pinned tool refs, per-project risk decisions.
- **Not AI-gated** — AI review is assistive and non-gating.
- **Not a DAST platform** — DAST is manual, allowlisted, fail-closed.

## Maturity model (honest)

Labels: `proven` (engine, self-gated) · `live-validated` (real consumer CI) · **`ci-validated
(evidence-fixture)`** (real CI on a dedicated non-deployed insecure fixture) · `supported` ·
`experimental` · `manual` · `non-gating`. Rules in
[`scanner-maturity-policy.md`](scanner-maturity-policy.md). **`ci-validated` is not `live-validated`.**

- **Engine:** `proven`.
- **`live-validated`:** CodeQL, OSV, Trivy-fs, Syft, Grype, Dockle, OWASP Dependency-Check, Deptrac.
- **`ci-validated (evidence-fixture)`:** Checkov, Terrascan, Conftest (CI run 27636439883).
- **manual/non-gating:** ZAP, Nuclei / AI review, Kuzushi.

## Evidence registry

Every promotion cites a real run ID + artifact + collector result in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). No claim without evidence; blockers are
recorded honestly (e.g. IaC on Hetzner `hcloud` = unsupported). Evidence is produced via the
[`evidence-platform.md`](evidence-platform.md).

## Semver & STABLE contract

STABLE surfaces (engine CLIs, exit codes, `SENTINEL_SHIELD_*` env vars, additive schemas, the four
modes, profile file modes) follow semver — [`product-contract.md`](product-contract.md). Minor
releases are drop-in; STABLE behavior changes are deferred to a major. The 6 frozen engine scripts
are diff-checked to **0 lines** each release.

## Secret handling

- NVD API key is **consumer-provided**, passed via a `0600 --propertyfile`, **never** logged, in a
  report, or committed; rotation guidance in [`security-hygiene.md`](security-hygiene.md).
- Evidence fixtures carry **no credentials** and never deploy.
- Secret scanning (`secrets`) is **never suppressible**.

## Audit artifacts

`security-summary.json` (schema-validated), raw scanner reports (uploaded `if: always()`, retained),
cited CI run IDs, the evidence registry, and the blocking self-test (currently **593 checks**).
`regulated` mode is available when audit evidence is required.

## Support model

- **Canonical truth:** [`product-status.md`](product-status.md).
- **Adoption:** [`public-adoption-kit.md`](public-adoption-kit.md).
- **Troubleshooting:** [`troubleshooting.md`](troubleshooting.md) (symptom → cause → fix).
- **Promotion to live-validated on your own infra:** [`live-validation-playbook.md`](live-validation-playbook.md).
- **Versioning/immutability:** [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md).
