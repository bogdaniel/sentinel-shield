# Workflow Template Inventory (v0.1.16)

Every shipped workflow template, what it is for, and its honest status. Maturity labels per
[`product-status.md`](product-status.md). All templates use minimal `permissions:` and have **no**
`pull_request_target` trigger (enforced by `self-test workflow-sanity`).

> **Pinning status (applies to all consumer templates):** third-party actions/images carry
> version tags or `YOUR_ORG`/TODO placeholders by default — **not digest-pinned**. The consumer
> must pin to SHAs/digests before production ([`pinned-tool-references.md`](pinned-tool-references.md)).
> ALL workflows and templates are SHA-pinned: **126 of 126** `uses:` lines across `.github/workflows/` and `templates/workflows/` carry a full 40-hex commit SHA, enforced fail-closed by `workflow-runtime-audit.sh` (`uses-sha-pin`). An earlier revision of this line claimed only `ci-self-test.yml` was pinned.

---

## `templates/workflows/sentinel-shield.yml`
- **Purpose:** combined consuming-project pipeline (Laravel + React + Docker); the managed
  workflow installed/synced by the installer.
- **Gate category:** PR + main (combined).
- **Required inputs:** `.sentinel-shield/profile.yaml`; a real `tests.json` step.
- **Required secrets:** none (checks out Sentinel Shield via `SENTINEL_SHIELD_REPOSITORY`/`_REF`).
- **Default enabled?** Yes (managed, `overwrite-if-force`).
- **Safe for PR?** Yes (no external target scanning).
- **Tool maturity:** core scanners `proven`; aggregate pipeline `template-only` (not yet run
  end-to-end on a live consumer — the pilot used the pr-fast workflow).
- **Known limitations:** whole-file managed; local edits overwritten on sync.
- **Pinning status:** `SENTINEL_SHIELD_REPOSITORY`/`_REF` + action refs must be set/pinned.

## `templates/workflows/sentinel-shield-pr-fast.yml`
- **Purpose:** fast, deterministic PR gate (php -l, PHPStan, Psalm, Pint/PHP-CS-Fixer, ESLint,
  tsc, Semgrep curated, Gitleaks, composer/npm audit, actionlint, zizmor, GH-pin audit, base
  digest, Hadolint, tests).
- **Gate category:** PR fast.
- **Required inputs:** project profile; `.semgrepignore`.
- **Required secrets:** none.
- **Default enabled?** Yes (offered as `manual` in the combo manifest; the pilot's validation
  workflow was based on it).
- **Safe for PR?** Yes — no external target scanning.
- **Tool maturity:** **`proven`** — live-validated on zenchron-tools (run 27170148123); Semgrep
  hardened to curated `semgrep/app` (**never `--config=auto`**).
- **Known limitations:** Psalm/Deptrac/ESLint only fire if the project configures them.
- **Pinning status:** action refs carry tags; pin before production.

## `templates/workflows/sentinel-shield-main.yml`
- **Purpose:** heavier main-branch gate (CodeQL, OSV-Scanner, Trivy fs, Dependency-Check, Grype,
  Deptrac, architecture tests, Syft SBOM, IaC when present).
- **Gate category:** MAIN.
- **Required inputs:** profile; IaC files (optional) for Checkov/Conftest/Terrascan.
- **Required secrets:** none for the default tools; `security-events: write` permission for CodeQL upload.
- **Default enabled?** No (installed `manual`).
- **Safe for PR?** Heavy → main only, not PR.
- **Tool maturity:** **`template-only` / `experimental`** — `workflow_dispatch`+push, never live-run;
  OSV/CodeQL severity parsing coarse.
- **Known limitations:** not dispatchable from a feature branch until it exists on the default branch
  (chicken-and-egg). **v0.1.17:** validate the same scanners branch-safely **first** with
  `scripts/run-main-gate-validation.sh --all` ([`main-gate-validation-strategy.md`](main-gate-validation-strategy.md)),
  then merge; do not merge unvalidated.
- **Pinning status:** unpinned by default.

## `templates/workflows/sentinel-shield-scheduled.yml`
- **Purpose:** nightly deep scans. Job `nightly` (Grype fs, OpenSSF Scorecard, TruffleHog deep,
  Dockle) + a dedicated job `dependency-check` running the slow NVD-backed OWASP Dependency-Check
  with a **persisted monthly NVD cache** (`actions/cache`, foreground only). Optional ZAP/Nuclei on
  staging only when a target+allowlist is configured.
- **Gate category:** NIGHT.
- **Required inputs:** `SENTINEL_SHIELD_IMAGE` (Dockle); repo token (Scorecard).
- **Required secrets:** repo token for Scorecard; DAST target/allowlist if ZAP/Nuclei enabled.
- **Default enabled?** No (installed `manual`); report-only by default.
- **Safe for PR?** N/A — scheduled.
- **Tool maturity:** **`experimental`** (deep scanners) / **`manual`** (optional DAST).
  Dependency-Check: **attempted, NOT live-validated** — nightly/cached is its validation path
  ([`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)).
- **Known limitations:** needs a built image + repo token; not live-validated. Dependency-Check's
  first run pays the cold NVD download once; the cache rotates monthly.
- **Pinning status:** scanner images carry **readable tags + digest overrides in `env`** (Grype,
  Dockle); upload steps use `if: always()`. Pin by digest before production
  ([`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md)).

## `templates/workflows/sentinel-shield-dast.yml`
- **Purpose:** controlled DAST (OWASP ZAP baseline/full + Nuclei) against an allowlisted target.
- **Gate category:** MANUAL.
- **Required inputs:** `target_url` + `allowed_host` workflow inputs; completed
  `dast-scan-approval.md` + `nuclei-target-allowlist.md`.
- **Required secrets:** none beyond the target; **fail-closed** without an allowlisted host.
- **Default enabled?** No — `workflow_dispatch` only; never a PR check.
- **Safe for PR?** **No** — explicitly not a PR check.
- **Tool maturity:** **`manual`** — never scans an arbitrary target; host mismatch → fail closed.
- **Known limitations:** active/full scan is intrusive; approval required; never live-run.
- **Pinning status:** unpinned by default.

## `templates/workflows/sentinel-shield-ai-review.yml`
- **Purpose:** assistive AI review (Claude Code Security Review / Kuzushi) → artifacts for human triage.
- **Gate category:** MANUAL / AI.
- **Required inputs:** PR label trigger or `workflow_dispatch`.
- **Required secrets:** AI provider API key (CI secret).
- **Default enabled?** No.
- **Safe for PR?** Advisory only (label-triggered).
- **Tool maturity:** **`non-gating`** — never blocks a release unless the profile explicitly sets
  `fail_on.ai_review_findings: true`.
- **Known limitations:** non-deterministic; assistive; not a substitute for scanners or humans.
- **Pinning status:** unpinned by default.

---

## Summary

| Template | Gate | Default on | Safe for PR | Maturity |
| --- | --- | --- | --- | --- |
| sentinel-shield.yml | PR+main | yes (managed) | yes | template-only (core `proven`) |
| sentinel-shield-pr-fast.yml | PR | yes | yes | **proven** |
| sentinel-shield-main.yml | MAIN | no | no | template-only / experimental |
| sentinel-shield-scheduled.yml | NIGHT | no | n/a | experimental / manual |
| sentinel-shield-dast.yml | MANUAL | no | **no** | manual (fail-closed) |
| sentinel-shield-ai-review.yml | AI | no | advisory | non-gating |
</content>

## v0.1.19 — main-gate execution hardening
Grype (SBOM-first/fs/container), Dependency-Check (disabled-default; nightly), Dockle (image-gated)
have hardened execution paths + env vars, but are **NOT promoted** (no live consumer artifact).
Semgrep 1.165.0 fixture-verified (0 parser errors), not consumer-verified. See
[`main-gate-execution-hardening-v0.1.19.md`](main-gate-execution-hardening-v0.1.19.md) and
[`main-gate-live-evidence.md`](main-gate-live-evidence.md). DAST/Nuclei/AI unchanged (manual/non-gating).

## v0.1.22 — workflow hardening + dedicated evidence workflow
- **`if: always()` on every artifact upload** across pr-fast, main, scheduled, dast, ai-review (and
  the combined `sentinel-shield.yml`) — a failing gate or scan step never erases the raw reports.
- **Digest-override env vars exposed in all templates** that run scanner images
  (`SENTINEL_SHIELD_SEMGREP_IMAGE`/`_GRYPE_IMAGE`/`_DOCKLE_IMAGE`) — readable tags by default, digest
  pins in [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).
- **Minimal permissions** (`contents: read`, `+ security-events: write` only on main for CodeQL),
  **no `pull_request_target`** trigger, and **workflow `name:` matches its filename** everywhere —
  all enforced by `self-test workflow-sanity`.
- **New `templates/workflows/sentinel-shield-dependency-check.yml`** — a dedicated, dispatch-only
  EVIDENCE workflow whose single job runs OWASP Dependency-Check (monthly NVD `actions/cache`,
  foreground, `timeout-minutes`, `if: always()` upload) to produce the **first real
  `dependency-check.json` artifact**. Until it does, Dependency-Check stays **attempted, NOT
  live-validated**. DAST/Nuclei/AI remain dispatch-only / non-gating (never a default gate).

## v0.1.21 — Dependency-Check nightly + scanner digest overrides
`sentinel-shield-scheduled.yml` gains a dedicated cached `dependency-check` job (monthly NVD
`actions/cache`, foreground, `if: always()` artifact upload). All templates now show **digest
override** env vars for validated scanner images (Semgrep/Grype/Dockle) — readable tags by default,
digest pins documented in [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md).
Dependency-Check remains **attempted, not live-validated**; the cached nightly is its validation path.
