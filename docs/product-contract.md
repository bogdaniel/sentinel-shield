# Product Contract (pre-1.0)

This is the **stability contract** for Sentinel Shield. It tells consumers which
surfaces they may depend on today, which are still moving, and how compatibility
will be handled before a `v1.0` exists.

> **Pre-1.0 status.** Sentinel Shield has **not** reached `v1.0`. Nothing here is a
> `v1.0` readiness claim. Maturity labels in this document defer to the single source
> of truth, [`product-status.md`](product-status.md) — where any other doc disagrees on
> a label, `product-status.md` wins. This contract describes *interface stability*
> (what may break and when), which is related to but distinct from per-tool maturity.

---

## 1. Stable vs experimental surfaces

A **STABLE** surface is one a consuming project may build automation on; it changes
only additively before `v1.0` (see §5). An **EXPERIMENTAL/INTERNAL** surface may change
shape, severity behavior, or be removed without an additive guarantee — depend on it
only with review.

These designations are grounded in [`product-status.md`](product-status.md): the gate
**engine** is `proven`, so its interfaces are STABLE; most individual scanner
integrations are `supported`/`experimental` and not yet live-validated, so their
*coarse severity output* is EXPERIMENTAL even where the collector contract around them
is stable.

### STABLE (consumers may depend on these)

| Surface | What is promised |
| --- | --- |
| `scripts/resolve-gates.sh` CLI | Reads `.sentinel-shield/profile.yaml`, applies mode defaults + overrides, writes `reports/sentinel-shield-gates.{env,json,md}`. Flags/output keys are additive. |
| `scripts/enforce-gates.sh` CLI | Consumes resolved flags + `reports/security-summary.json`; exit `0` pass / `1` fail / `2` config-or-input error. |
| `scripts/build-security-summary.sh` CLI | Merges collector output into one `security-summary.json` consistent with the schema. |
| `scripts/select-security-summary.sh` CLI | Fail-closed summary selection (example never accepted outside `report-only`). |
| `scripts/install-baseline.sh` / `scripts/sync-baseline.sh` CLIs | Dry-run-by-default install/sync; `--apply`, `--force`, `--mode`, `--profile`, `--target` flags; hard protections on project-local files. |
| `reports/security-summary.json` schema | [`schemas/security-summary.schema.json`](../schemas/security-summary.schema.json) — additive (see §2). |
| Profile manifest schema | [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json) — additive (see §3). |
| Accepted-risk schema | [`schemas/accepted-risks.schema.json`](../schemas/accepted-risks.schema.json) — additive; never-suppressible gates stay never-suppressible. |
| `SENTINEL_SHIELD_*` env var names | The resolver/enforcer contract vars (e.g. `SENTINEL_SHIELD_MODE`, `SENTINEL_SHIELD_FAIL_ON_*`, `SENTINEL_SHIELD_PATH`, `SENTINEL_SHIELD_REF`) keep their names and meaning; new ones are added, existing ones are not silently repurposed. |
| Exit-code conventions | `0` pass / `1` gate fail / `2` config-or-input error, across the engine scripts. |
| Adoption **modes** | `report-only`, `baseline`, `strict`, `regulated` — names and relative ordering are stable. |

### EXPERIMENTAL / INTERNAL (depend on these only with review)

| Surface | Why it is not yet stable |
| --- | --- |
| Individual collectors' **coarse severity** mapping | Severity fidelity is best-effort for OSV/CodeQL/Grype/OWASP Dependency-Check and similar; the bucket a finding lands in may be tuned. The collector *I/O contract* (§2) is stable; the *severity it assigns* is not. |
| Scanner wrappers **not yet live-validated** | Per [`product-status.md`](product-status.md), `supported`/`experimental` tools (e.g. npm audit, ESLint, Psalm, Deptrac, Checkov/Conftest/Terrascan, Scorecard, TruffleHog, Trivy-image, OWASP Dependency-Check) have fixtures but no cited consumer run. Their wrapper flags/behavior may change. |
| `sentinel-shield-main.yml`, `sentinel-shield-scheduled.yml`, combined `sentinel-shield.yml` | `template-only` — not executed by default; topology may change. |
| DAST (`manual`) and AI review (`non-gating`) surfaces | Manual/advisory by design; never a default gate, may evolve. |
| `sync-managed-block` file mode | Reserved; treated like `manual` today (see §3). |
| Internal helpers (`scripts/lib/`, `scripts/collectors/` internals, `scripts/runners/`, `scripts/adapters/`, `scripts/audits/`) | These exist to *produce* the contract artifacts. Call the documented CLIs and consume the JSON/env contracts, not the internals. |

**Rule of thumb:** depend on the **CLIs, exit codes, env-var names, and JSON/schema
contracts** above. Treat **severity numbers from not-yet-live-validated scanners** as
review prompts, not as a stable interface.

---

## 2. Raw report compatibility promises

Authoritative reference: [`raw-report-contract.md`](raw-report-contract.md).

- **Missing or empty raw input → `unavailable`, counts `0`, exit `0`.** A tool that did
  not run is reported as unavailable; it is **never** reported as fake-clean.
- **Invalid JSON → exit `2`** (a hard error, not a silent zero). A missing *required*
  summary key in the enforcer path is likewise exit `2`.
- **Collectors normalize to a fixed object shape:** `{ tool, status, summary{…}, tool_report }`,
  which `build-security-summary.sh` merges by summing counts.
- **The `security-summary.json` summary keys are additive.** The contract started from a
  small core of count/flag gates and has grown (the schema now defines 20+ summary keys —
  e.g. `secrets`, `critical/high/medium_vulnerabilities`, `type_errors`, `test_failures`,
  `unsafe_docker`, `unsafe_github_actions`, `missing_sbom`, `missing_release_evidence`,
  `expired_exceptions`, plus later additions like `style_violations`, `iac_violations`,
  `container_image_violations`, `ai_review_findings`). **New keys are added; existing keys
  are not renamed or removed** before `v1.0`. Consumers must tolerate unknown keys.
- **Existing semantics are preserved:** a key's meaning (what it counts, which gate it
  feeds, whether it is suppressible) does not change underneath consumers without a
  CHANGELOG callout.

---

## 3. Profile manifest compatibility promises

Authoritative reference: [`profile-driven-adoption.md`](profile-driven-adoption.md) and
the schema [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json).

- **The schema is additive.** It sets `additionalProperties: true` at the top level, so
  new manifest fields can be introduced without breaking existing manifests or consumers.
- **The four file modes are stable:** `create-if-missing`, `overwrite-if-force`,
  `sync-managed-block` (reserved; treated like `manual` today), and `manual`. Their
  meanings do not change before `v1.0`.
- **The `never_touch` list is honored** by both install and sync. Project-local files
  (e.g. `.sentinel-shield/accepted-risks.json`, `phpstan-baseline.neon`, `phpstan.neon`)
  are **never** created or overwritten — regardless of `--force`.
- **Resolution order is stable:** a profile name resolves by looking in `profiles/<name>/`
  first, then `profiles/combinations/<name>` (the `*.manifest.json` combination form).
- **Scope honesty:** manifests exist for laravel/react/node/docker and `php-library`,
  plus the `laravel-react-docker` combination. There is **no** general onboarding for
  arbitrary stacks (Symfony/Go/Python have profiles but no install manifests). This is a
  coverage limit, not a contract weakness — see [`product-status.md`](product-status.md).

---

## 4. What is NOT promised

- **No live-validation claim for unproven tools.** In particular, **OWASP
  Dependency-Check is not live-validated** (attempted; cold NVD exceeds the CI budget —
  it is intended to run via a cached nightly job). Do not read its presence as a proven
  gate.
- **No digest pinning by default.** Tool images/actions ship as readable tags; the
  consumer must pin digests before production ([`pinned-tool-references.md`](pinned-tool-references.md),
  [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).
- **No cross-workflow artifact discovery.** The release gate consumes summaries produced
  in the same run; cross-run handoff is deliberately not automated.
- **No `v1.0` / turnkey guarantee.** Adoption still requires a profile, pinned refs, and
  per-project risk decisions.

---

## 5. Migration policy before v1.0

- **Pre-1.0 versioning.** While Sentinel Shield is below `v1.0`, **minor tags may
  introduce additive changes** (new summary keys, new env vars, new manifest fields, new
  collectors/runners) without being treated as breaking.
- **Breaking changes are called out in [`CHANGELOG.md`](../CHANGELOG.md).** Any change
  that renames/removes a STABLE surface, changes an exit-code meaning, or changes the
  semantics of an existing summary key is announced there. Absence of a CHANGELOG
  breaking-change note means a release is intended to be drop-in for the STABLE surfaces
  in §1–§3.
- **Tags are immutable.** A published tag is never moved or rewritten (see
  [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md)). To get
  changes, bump the ref — never expect an existing tag's contents to change.
- **Consumers pin `SENTINEL_SHIELD_REF`** to a **tag or full commit SHA**, never a moving
  branch. Combined with immutable tags, this makes adoption reproducible: a consumer's
  behavior changes only when it deliberately bumps the ref.
- **No `v1.0` until the roadmap clears it.** `v1.0` requires the open frontier in
  [`roadmap.md`](roadmap.md) (Phase 3 — live validation of main-gate tools, and beyond)
  to land with cited evidence. This document does not assert that frontier is closed.

---

## See also

- [`product-status.md`](product-status.md) — canonical maturity (source of truth).
- [`raw-report-contract.md`](raw-report-contract.md) — per-collector raw report behavior.
- [`profile-driven-adoption.md`](profile-driven-adoption.md) — install/sync model.
- [`product-readiness-checklist.md`](product-readiness-checklist.md) — readiness evidence.
- [`roadmap.md`](roadmap.md) — maturity-ordered plan to (eventually) `v1.0`.
- [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md) — tags, immutability, release gate.
