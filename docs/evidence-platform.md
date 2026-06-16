# Evidence Platform (v1.7.0 — Agent A)

Turns the one-off v1.6.0 evidence repo into a **reusable platform** for proving — honestly — what
Sentinel Shield's scanners do. It defines the relationship between the engine repo and evidence
consumers, the repo categories, and the metadata every piece of evidence must carry.

## Purpose

Sentinel Shield **normalizes and gates** scanner output; it does not bundle scanners. Maturity claims
must therefore rest on **real runs with cited artifacts**, not assertions. The evidence platform is
the infrastructure that produces those runs and the conventions that keep the claims honest.

## Repos and their relationship

- **`sentinel-shield`** (engine) — collectors, gate engine, self-test, docs, the **evidence registry**
  ([`main-gate-live-evidence.md`](main-gate-live-evidence.md)) and canonical maturity
  ([`product-status.md`](product-status.md)).
- **Evidence consumers** — separate repos that run scanners in CI and upload raw artifacts. The engine
  downloads those artifacts, runs its collectors, and records the result.

## Evidence repo categories

| Category | Example | Findings | Max maturity it can justify |
|---|---|---|---|
| **evidence-fixture** | `bogdaniel/sentinel-shield-iac-evidence` | engineered (intentionally insecure, non-deployed) | `ci-validated (evidence-fixture)` |
| **real-consumer** | a public app with genuine config (e.g. silver-potato for Deptrac) | incidental | `live-validated` |
| **private-consumer (aggregate)** | a private app (e.g. zenchron-tools for Dependency-Check) | incidental | `live-validated` — **aggregate counts only**, raw artifact kept private |

## Required metadata (per evidence entry)

tool name · tool version · repo/context + category · CI **run ID** (or reproducible command) ·
raw artifact name + validity (size) · collector result · mapped summary key · pass/fail behavior ·
caveats. Missing any field ⇒ not promotable (see [`scanner-maturity-policy.md`](scanner-maturity-policy.md)).

## Conventions

- **Artifact naming:** `<tool>.json` (e.g. `checkov.json`, `terrascan.json`). **Exception:** Conftest
  output must **not** be `conftest.{json,toml,yaml}` (conftest auto-loads those as config) → use
  `conftest-report.json`.
- **Run ID:** the GitHub Actions numeric run ID, cited verbatim in the registry.
- **Scanner version:** pin and record the exact version (image digest / release tag / `pip` version).
- **Fixture sanitization:** committed fixtures under `tests/fixtures/<area>-v<rel>/` are
  **derived/sanitized** — no absolute/runner paths, no account IDs, no credentials, no private
  class/path data. Raw artifacts stay out of the engine repo.
- **Maturity vocabulary:** see [`scanner-maturity-policy.md`](scanner-maturity-policy.md). `ci-validated
  (evidence-fixture)` and `live-validated` are **distinct** and never conflated.

## How to add evidence

See [`evidence-contribution-guide.md`](evidence-contribution-guide.md) (rules) and, for promoting a
fixture-validated tool to a real consumer, [`live-validation-playbook.md`](live-validation-playbook.md).

## What this platform is NOT

- Not a scanner bundler. Not a deploy system (evidence fixtures never deploy). Not a way to
  manufacture `live-validated` claims from engineered fixtures.
