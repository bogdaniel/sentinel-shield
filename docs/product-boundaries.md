# Product Boundaries (v0.1.16)

Sentinel Shield is a **reusable product**, not a per-project workspace. This document draws the
line between what the product owns (upstream, synced, versioned) and what a consuming project
owns (local, never overwritten). It is the rule used to decide where a change belongs.

## The rule

> **If logic is reusable across projects, upstream it into Sentinel Shield.
> If it is project-specific evidence, risk acceptance, or remediation, keep it in the project.**

A corollary, used during the zenchron-tools pilot and codified here: a fix discovered while
adopting Sentinel Shield in a real repo is upstreamed **only** if it is reusable. The project's
debt, baselines, and accepted risks stay in the project.

## Sentinel Shield owns

| Owned artifact | Where |
| --- | --- |
| Reusable scanner **runners / adapters / audits** | `scripts/runners/`, `scripts/adapters/`, `scripts/audits/` |
| **Collectors** (raw report → summary key) | `scripts/collectors/` |
| **Release gate logic** (resolve / enforce / build / select) | `scripts/*.sh` |
| **Accepted-risk schema and enforcement** | `schemas/accepted-risks.schema.json`, `enforce-gates.sh` |
| **Profile manifests** | `profiles/**/profile.manifest.json`, `profiles/combinations/` |
| **Workflow templates** | `templates/workflows/` |
| **Generic remediation docs** | `docs/remediation/` |
| **Governance templates** | `templates/*.md` |
| **Finding contract** + schema | `schemas/security-summary.schema.json`, `docs/raw-report-contract.md` |
| **Semgrep rule trees** (app vs supply-chain) | `semgrep/app/`, `semgrep/supply-chain/` |
| **The self-test** | `scripts/self-test.sh` |

## Consuming projects own

| Owned artifact | Why it stays local |
| --- | --- |
| `.sentinel-shield/profile.yaml` **values** | Stack, criticality, mode, overrides are per-project |
| `.sentinel-shield/accepted-risks.json` **decisions** | Risk acceptance is owner-bound and project-specific; **never** upstreamed |
| `phpstan-baseline.neon` / `phpstan.neon` | Project debt snapshot |
| **Project code fixes** | The project's own remediation |
| **Project-specific docs** | Project context, not reusable standard |
| **Staging / DAST target allowlists** | Per-environment, security-sensitive |
| **Local infrastructure decisions** | Deployment-specific |

## Hard protections (enforced, not just documented)

`install-baseline.sh` and `sync-baseline.sh` **never** create or overwrite
`.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`, any manifest
`never_touch` path, project-owned (`create-if-missing`) files, or project code — regardless of
`--force`. Managed files (`overwrite-if-force`) are updated only with explicit `--force`.

## Decision examples

- A new way to normalize a scanner's output → **upstream** (collector).
- "Larastan needs APP_KEY set in CI" → **upstream** (the runner handles it).
- "We accept DL3018 in `Dockerfile.prod` until 2026-09" → **project** (`accepted-risks.json`).
- "Our PHPStan baseline has 412 entries" → **project** (`phpstan-baseline.neon`).
- A reusable Docker base-digest detector → **upstream** (audit + collector).
- "Our staging host is `stg.example.com`" → **project** (DAST allowlist).

See also [`architecture-boundaries.md`](architecture-boundaries.md) and
[`profile-driven-adoption.md`](profile-driven-adoption.md).
</content>
