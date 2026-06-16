# Real-Consumer Live-Validation Playbook (v1.7.0 — Agent G)

How to promote a scanner from **`ci-validated (evidence-fixture)`** to **`live-validated`** by running
it in a **real consumer's** CI. This is the path Checkov/Terrascan/Conftest still need (they are
`ci-validated` on the evidence fixture, not `live-validated`). It mirrors how Deptrac reached
`live-validated` (silver-potato, run 27633798174).

## Promotion bar (what `live-validated` requires)

A real CI run on a **real consumer** (third-party or production-shaped, **not** a `*-evidence`
fixture) with a **supported surface**, producing **incidental** findings (not engineered), with the
collector verified on the downloaded artifact and the run ID cited in
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). See
[`scanner-maturity-policy.md`](scanner-maturity-policy.md).

## Onboarding a real consumer with supported IaC

1. Identify a consumer with **AWS / Azure / GCP / Kubernetes** IaC (mature scanner coverage).
   Avoid niche providers (e.g. Hetzner `hcloud` — Terrascan ships no policies; see v1.5.0).
2. Confirm the IaC parses: scanner reports real resources/findings, not `resource_count:0`.

## Evidence-only workflow requirements

- A **separate** workflow file; runs on its **own branch** / `workflow_dispatch`, off deploy paths.
- **Static scanners only** — no `apply`, no `plan` against a live account, no credentials.
- `permissions: contents: read`; pin actions by SHA; `if: always()` artifact upload; bounded
  `timeout-minutes`; sane `retention-days`.
- Modify **only** the evidence workflow/config — never the consumer's application code.

## Privacy & raw-artifact handling

- **Public** consumer → artifact may be committed as a **sanitized derived fixture**.
- **Private** consumer → commit **aggregate counts + run ID only**; keep raw local/gitignored;
  strip any class/path/host data.

## Run ID & caveat language

- Cite the GitHub Actions **run ID** verbatim. Record exact scanner version.
- Caveat honestly: severity fidelity (IaC = count; OSV/CodeQL coarse), surface scope, and — until a
  second independent consumer — "validated on one consumer".

## Rollback

- Digests/SHAs are immutable: pin the previous ref to restore the exact validated toolchain.
- If a promotion is later found unsupported, **demote** per the maturity policy (record the reason,
  add a guard). Never mutate a released tag.

## Failure / blocker reporting

If the run fails or the surface is unsupported, **document the exact blocker** (e.g. v1.5.0 hcloud:
"Terrascan ships no hcloud policies") and keep the tool at its current label. **No run ID is
invented; no fixture is fabricated to force a pass.** A blocker honestly recorded is a valid outcome.

## Cleanup

After capturing evidence, the evidence-only branch/workflow on the consumer may be deleted (the run
ID + artifact persist in Actions history). Cite the run ID in the registry regardless.
