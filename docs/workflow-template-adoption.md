# Workflow Template Adoption Guide (v0.1.24)

How to adopt the Sentinel Shield workflow templates in a consuming project: how to **pin** them,
the **steps** to install, the **secrets**, **inputs**, **safe defaults**, **runtime budget**,
**artifact expectations**, and **failure behavior** of each template.

Templates live in `templates/workflows/`:

| Template | Trigger | Gating? | Purpose |
|----------|---------|---------|---------|
| `sentinel-shield.yml` | `pull_request`, `push` (master), `workflow_dispatch` | **Yes** (release-gate job) | Combined Laravel+React+Docker pipeline (managed by installer). |
| `sentinel-shield-pr-fast.yml` | `pull_request`, `workflow_dispatch` | **Yes** | Fast deterministic PR gate; no external target scanning. |
| `sentinel-shield-main.yml` | `push` (main/master), `workflow_dispatch` | **Yes** | Heavier trusted-branch gate (CodeQL, OSV, Trivy, Grype, IaC, SBOM). |
| `sentinel-shield-scheduled.yml` | `schedule` (daily 03:23 UTC), `workflow_dispatch` | **No** (report-only) | Nightly deep scans + dedicated Dependency-Check job. |
| `sentinel-shield-dependency-check.yml` | `workflow_dispatch` (optional weekly cron, commented) | **No** | Single-purpose OWASP Dependency-Check evidence. |
| `sentinel-shield-dast.yml` | `workflow_dispatch` **only** | **No** | Controlled ZAP/Nuclei DAST; fails closed without an allowlisted host. |
| `sentinel-shield-ai-review.yml` | `workflow_dispatch`, `pull_request` (labeled `ai-review`) | **No** (assistive) | Non-gating AI security review. |

---

## 212 — Template pinning

Templates ship **readable tags and placeholders by default** — they are NOT production-pinned. Pin
before you rely on them as a gate:

1. **Sentinel Shield itself** — set `SENTINEL_SHIELD_REPOSITORY` to your fork/mirror and pin
   `SENTINEL_SHIELD_REF` to a **full commit SHA** (not a moving branch, not a floating tag). The
   templates default to a version tag (`v0.1.x`) for first adoption only.
2. **Third-party `uses:` actions** — pin every `actions/*`, `aquasecurity/trivy-action`,
   `anchore/sbom-action`, `shivammathur/setup-php`, `actions/setup-node`, `actions/cache`, etc. to a
   verified commit SHA. The audit `audit-github-actions-pins.sh` flags unpinned refs into
   `unsafe_github_actions`.
3. **Scanner container images** — override the `SENTINEL_SHIELD_*_IMAGE` env defaults with the
   `@sha256:` digest form (each default has the digest in an adjacent comment). See
   `docs/scanner-image-digest-pinning.md` and `docs/pinned-tool-references.md`.
   - `SENTINEL_SHIELD_SEMGREP_IMAGE` (pr-fast, combined)
   - `SENTINEL_SHIELD_GRYPE_IMAGE` (main, scheduled)
   - `SENTINEL_SHIELD_DOCKLE_IMAGE` (scheduled)
   - `SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE` (scheduled, dependency-check)
4. **Never** use `pull_request_target`. **Never** switch Semgrep to `--config=auto` (curated
   `semgrep/app` rules only).

A `sync-baseline.sh --apply --force` re-writes the managed `sentinel-shield.yml`; keep project
specifics in `.sentinel-shield/profile.yaml` + `.sentinel-shield/accepted-risks.json`, not in the
workflow body.

## 213 — Adoption steps

1. **Choose a source strategy.** Option B (recommended): check Sentinel Shield out into
   `tools/sentinel-shield` via the two `actions/checkout` steps already in each template. Option A:
   vendor `scripts/ schemas/ templates/` into the project and repoint `${{ env.SENTINEL_SHIELD_PATH }}`.
2. **Copy the templates you need** into `.github/workflows/`. Most projects: `pr-fast` + `main` +
   `scheduled`. The installer manages the combined `sentinel-shield.yml` for Laravel+React+Docker.
3. **Set env vars** at the top of each file: `SENTINEL_SHIELD_REPOSITORY`, `SENTINEL_SHIELD_REF`
   (replace the `YOUR_ORG`/`TODO` placeholders). If Sentinel Shield is private, add
   `token: ${{ secrets.SENTINEL_SHIELD_RO_TOKEN }}` to the checkout steps.
4. **Add `.sentinel-shield/profile.yaml`** with your profile mode (`report-only` → `baseline` →
   `strict`/`regulated`) and criticality. The gate resolves from this.
5. **Wire real test reporters** (PHPUnit JUnit, Vitest/Jest JSON) so `tests.json` is real — never
   faked; if unwired the tool stays `unavailable`.
6. **Pin** everything per §212.
7. **Validate before merging the main gate**: run the branch-safe harness
   `sh scripts/run-main-gate-validation.sh --target . --output-dir reports/raw --all`, review
   `reports/raw/*`, then merge `sentinel-shield-main.yml` to the default branch.
8. **Run the sanity self-test**: `sh scripts/self-test.sh workflow-sanity`.

## 214 — Required secrets per template

| Template | Required secrets | Optional secrets |
|----------|------------------|------------------|
| `sentinel-shield.yml` | none (public Sentinel Shield repo) | `SENTINEL_SHIELD_RO_TOKEN` if private |
| `sentinel-shield-pr-fast.yml` | none | `SENTINEL_SHIELD_RO_TOKEN` if private |
| `sentinel-shield-main.yml` | none (uses built-in `GITHUB_TOKEN` for CodeQL SARIF upload via `security-events: write`) | `SENTINEL_SHIELD_RO_TOKEN` if private |
| `sentinel-shield-scheduled.yml` | none | `SENTINEL_SHIELD_RO_TOKEN` if private; repo **var** `SENTINEL_SHIELD_IMAGE` enables Dockle |
| `sentinel-shield-dependency-check.yml` | none | `SENTINEL_SHIELD_RO_TOKEN` if private |
| `sentinel-shield-dast.yml` | none required by the template | target auth secrets only if your scan needs them |
| `sentinel-shield-ai-review.yml` | `ANTHROPIC_API_KEY` (only if you wire a real AI tool; absent → emits an empty non-gating report) | — |

No secret is required for the core gates. `ANTHROPIC_API_KEY` is the only secret any template reads,
and only in the non-gating AI review.

## 215 — Required inputs

- **Profile file (all gating templates):** `.sentinel-shield/profile.yaml` drives `resolve-gates.sh`
  / `enforce-gates.sh`. Without it the resolver falls back to defaults.
- **`.semgrepignore` (pr-fast, combined):** honors vendored/generated paths so Semgrep is quiet.
- **`sentinel-shield-dast.yml` `workflow_dispatch` inputs** (all required unless noted):
  - `target_url` (required) — must match the allowlisted host.
  - `allowed_host` (required) — exact allowlisted host; guard fails closed on mismatch.
  - `scan` (required, default `zap-baseline`) — one of `zap-baseline | zap-full | nuclei`. Requires a
    completed `templates/dast-scan-approval.md` + `nuclei-target-allowlist.md`.
- **`sentinel-shield-ai-review.yml`:** opt-in only via the `ai-review` PR label or manual dispatch.
- **Repo variable (scheduled):** `vars.SENTINEL_SHIELD_IMAGE` — when set, the nightly Dockle step runs
  against that built image; when empty, Dockle self-skips (marked `unavailable`, never faked).

## 216 — Safe defaults

- **Permissions:** every template is `contents: read`; `sentinel-shield-main.yml` adds the single
  documented `security-events: write` for CodeQL SARIF upload. No write/`id-token`/`packages` scopes.
- **`persist-credentials: false`** on every checkout.
- **No `pull_request_target`** anywhere (PR-fast/combined use plain `pull_request`).
- **DAST fails closed** without an allowlisted host; Nuclei is reachable only through the manual DAST
  workflow.
- **AI review is non-gating** unless the profile explicitly sets `fail_on.ai_review_findings: true`.
- **Scheduled is report-only** — it never blocks a merge; Dependency-Check defaults to `disabled` in
  the main gate and is `enabled` only in its isolated nightly/evidence jobs.
- **Scanner steps are best-effort** (`continue-on-error: true` / `|| true`) so a scanner crash does not
  abort the pipeline before the gate evaluates real findings — the gate, not the scanner exit code,
  decides pass/fail.
- **Grype defaults to SBOM mode** in the main gate (`SENTINEL_SHIELD_GRYPE_MODE: sbom`) and `fs` mode in
  the nightly (no prior SBOM there).

## 217 — Runtime budget

Indicative wall-clock on `ubuntu-latest` (network/cache dependent):

| Template | Budget | Notes |
|----------|--------|-------|
| `sentinel-shield-pr-fast.yml` | ~3–8 min | Designed to be fast/deterministic; no external scanning. |
| `sentinel-shield.yml` | ~10–20 min | Parallel jobs (php/node/docker/security) fan-in to summary + gate. |
| `sentinel-shield-main.yml` | ~10–25 min | CodeQL dominates; Dependency-Check disabled here by design. |
| `sentinel-shield-scheduled.yml` (nightly job) | ~10–20 min | Deep scans, report-only. |
| `sentinel-shield-scheduled.yml` (dependency-check job) | **cold ≤45 min, warm ~5–15 min** | `timeout-minutes: 45` + `SENTINEL_SHIELD_DEPENDENCY_CHECK_TIMEOUT: 40m`; foreground only; monthly NVD `actions/cache`. |
| `sentinel-shield-dependency-check.yml` | same as above | Cold first run downloads the full NVD feed; warm runs fetch the delta. |
| `sentinel-shield-dast.yml` | varies by target | `zap-full` and `nuclei` can be long; manual dispatch only. |
| `sentinel-shield-ai-review.yml` | minutes (advisory) | Depends on the AI tool wired in; non-gating. |

Dependency-Check **must** run in the foreground — `timeout-minutes` and the wrapper timeout are
ignored by a detached `docker run -d`, so never detach it.

## 218 — Artifact expectations

All uploads use `actions/upload-artifact@v4`, **`retention-days: 30`**, and (as of v0.1.24) carry
**`if: always()`** so a failing scan/gate step never erases the evidence.

| Template | Artifact name(s) | `if-no-files-found` |
|----------|------------------|---------------------|
| `sentinel-shield-pr-fast.yml` | `sentinel-shield-pr-fast` (`reports/**`) | warn |
| `sentinel-shield-main.yml` | `sentinel-shield-main` (`reports/**`) | warn |
| `sentinel-shield-scheduled.yml` | `sentinel-shield-scheduled`, `sentinel-shield-dependency-check` | warn |
| `sentinel-shield-dependency-check.yml` | `sentinel-shield-dependency-check` | warn |
| `sentinel-shield-dast.yml` | `sentinel-shield-dast` | warn |
| `sentinel-shield-ai-review.yml` | `sentinel-shield-ai-review` | warn |
| `sentinel-shield.yml` | `sentinel-shield-gate-resolution`, `-raw-security-{php,node,docker}`, `-raw-security`, `-sbom`, `-security-summary` (`error`), `-raw-security-merged`, `-enforcement`, `-release-evidence` | mostly warn; **security-summary = error** |

The combined pipeline's `security-summary` upload keeps `if-no-files-found: error` so an empty summary
is surfaced rather than silently passed; `upload-artifact@v4` forbids two jobs uploading the same name,
so the resolved gates are uploaded once by `prepare`.

## 219 — Failure behavior

- **Gate decision** comes from `enforce-gates.sh`: exit **0 = pass**, **1 = fail on real findings**,
  **2 = config error**. This is what blocks a PR/push on the gating templates (`pr-fast`, `main`,
  combined release-gate).
- **Scanner failures do not fake-pass:** a crashed/absent scanner leaves the tool `unavailable` (never
  a fake clean report). Best-effort `|| true` keeps the pipeline running so the gate sees the real
  picture; the gate still fails if required signal is missing in strict/regulated mode (e.g.
  `missing_sbom`).
- **Artifacts survive failures:** every upload is `if: always()`, so `reports/**` (raw scanner JSON,
  SBOM, summary, enforcement, release evidence) is available for triage even when the gate fails.
- **Scheduled/Dependency-Check are report-only:** findings are recorded and uploaded but never block a
  merge.
- **DAST fails closed:** a `target_url` not matching `allowed_host` aborts before any scan; an unknown
  `scan` value exits `2`.
- **AI review never blocks** unless the profile opts in via `fail_on.ai_review_findings: true`.
- **First-time main-gate caveat:** `sentinel-shield-main.yml` is `workflow_dispatch`+`push` only and
  cannot be dispatched from a feature branch until it exists on the default branch — validate with the
  branch-safe harness first (§213 step 7) before merging it.
