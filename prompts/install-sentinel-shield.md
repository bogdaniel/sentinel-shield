# Prompt: Install Sentinel Shield (safe, AI-assisted)

Copy everything below the line into your AI coding agent, running in the target project's repo.
Guide: [`docs/ai-assisted-install.md`](../docs/ai-assisted-install.md).

---

You are installing **Sentinel Shield** (a release-gate engine + security/quality baseline) into THIS
repository, safely. Sentinel Shield normalizes and gates external scanner output; it does **not**
bundle scanners. Work in small, reviewable steps. **Audit before you install. Never fake a clean
gate.**

**Installing a profile does NOT make its tools available.** A profile only *declares* a tool policy
(per `schemas/tool-policy.schema.json` / `docs/profile-tool-policy.md`): each tool has a `policy`
(`required` / `recommended` / `optional` / `one-of` / `disabled` / `external`), an `executable[]`
detection list, optional `packages[]`, and a `runner`. Whether those tools actually get installed is
controlled by the **tool provisioning mode** you pick at install time (`--tool-mode`). After install
you MUST report, per the tool policy, which **required** tools are installed vs missing and which
**recommended** tools are installed vs skipped — a missing `required` tool is a config failure, not a
silent pass.

## Non-negotiables (hard stops)

- Do **not** rewrite git history. Do **not** mutate or move tags. Do **not** force-push.
- Do **not** commit secrets, API keys, or the NVD key value.
- Do **not** commit `.env`, `.claude/`, `vendor/`, `node_modules/`, or raw private scanner artifacts.
- Do **not** modify Sentinel Shield's managed scripts/workflows locally — override via
  `.sentinel-shield/profile.yaml`, never by editing managed files.
- Do **not** suppress, downgrade, or remediate findings just to make the gate green.
- Do **not** downgrade a framework or package to satisfy a tool; only `bootstrap-tools` with explicit
  consent may add dev tools, and it must roll back if it breaks the build.
- Do **not** enable AWS / Kubernetes / IaC **live** validation unless explicitly requested
  (IaC stays `ci-validated (evidence-fixture)`).
- If anything is ambiguous or fails, **stop and report honestly** — do not guess.

## Phases

**1. Repository audit.** Detect language/stack(s), package managers, lockfiles, existing
`.github/workflows`, existing `.sentinel-shield/`, and `.gitignore`. Summarize what's present. Do not
change anything yet.

**2. Git hygiene cleanup.** Ensure `.gitignore` covers `.env`, `.claude/`, `vendor/`,
`node_modules/`, `reports/`, build caches. If secrets/artifacts are already tracked, **report** them
(propose removal in a separate commit) — do **not** rewrite history to purge them.

**3. Composer/PHP baseline.** If PHP: confirm `composer.json`/lockfile; note PHP version; do **not**
auto-run `composer install` against private registries without consumer auth. Record what's needed.

**4. Node/npm baseline.** If Node: confirm `package.json`/lockfile; note Node version; note whether
`npm ci` is feasible. Record gaps.

**5. Profile selection.** List profiles (`ls -d profiles/*/ profiles/combinations/*.manifest.json`)
and pick the one matching the stack (or `hardened-enterprise` if asked). State your choice + why.

**5a. Tool-policy resolution.** Resolve the profile's declared tool policy *before* installing so you
know what the profile demands and what the project already has:
`sh scripts/resolve-tool-plan.sh --profile <name> --target . --format text`. Classify each tool by
`policy` (`required` / `recommended` / `optional` / `one-of` / `disabled` / `external`) and by whether
its `executable[]` is already detected. This is the basis for the install report — do **not** assume a
declared tool is present.

**6. Sentinel Shield installation.** Pick a **tool provisioning mode** (`--tool-mode`) and state why:

- `config-only` (default) — installs Sentinel Shield's managed files only; does **not** touch
  `composer.json` / `package.json`. Missing required tools are **reported, non-fatal**. Safest first
  step.
- `require-existing` — installs **no** packages but **fails preflight** if a `required` tool's
  executable is absent (recommended absent → warning). Use when tools are expected to be present
  already.
- `bootstrap-tools` — resolves compatible versions and prints the exact install plan (dry-run); with
  `--apply` it installs packages, validates the lockfile, runs tests, and **rolls back on failure**.
  Only with explicit consent (it mutates dependency manifests). Never downgrade a framework/package.

Two **independent** flags: `--tool-mode` (`config-only` | `require-existing` | `bootstrap-tools`) is
*how tools are provisioned*; `--mode` (`report-only` | `baseline` | `strict` | `regulated`) is the
*adoption/gate strictness* written into `.sentinel-shield/profile.yaml`. Run **dry-run first**:

`sh scripts/install-baseline.sh --target . --profile <name> --tool-mode <mode> --emit-plan plan.json`
— review the planned writes and the emitted plan (and, for `bootstrap-tools`, the dependency plan).
Then apply:

`sh scripts/install-baseline.sh --target . --profile <name> --tool-mode <mode> --mode baseline --apply [--non-interactive]`
(`--non-interactive` for CI/automation; omit `--mode` to keep the default `report-only`). Confirm
project-local files (`accepted-risks.json`, baselines) were **not** touched. Re-run
`resolve-tool-plan.sh` (or read `.sentinel-shield/installation.json`'s `enabled_tools` /
`disabled_tools`) to confirm what is actually present.

**7. Practical non-IaC gate integration.** Wire the **PR-fast** gate first (pinned actions/images).
Keep IaC/DAST/AI out of the default gate. Start in `report-only` or `baseline`.

**8. Deptrac decision.** If the project has (or wants) architecture layers, add a real `deptrac.yaml`
and wire Deptrac (`architecture_violations`, binary severity). If not applicable, skip it — do not
fabricate config.

**9. Accepted risks.** Do not create `accepted-risks.json` unless a risk is genuinely accepted, with
written justification. `secrets` are never suppressible. Prefer fixing the finding.

**10. Local validation.** Run `sh scripts/doctor.sh --target .`; confirm the pipeline produces a real
`reports/security-summary.json`. If you're in the Sentinel Shield repo itself, run
`sh scripts/self-test.sh all`.

**11. CI validation.** Trigger the gate in CI (PR or dispatch). Confirm it runs and produces the
summary. A real finding that blocks the gate is **correct behavior** — report it, do not suppress.

**12. Documentation.** Add a short `SECURITY.md`/README note: installed Sentinel Shield **tag**,
selected **profile**, adoption **mode**, and the **sync/upgrade** command.

**13. Upgradeability.** Keep managed files separate from overrides; document the tag + profile;
document `sync-baseline.sh`; **dry-run sync before applying** future upgrades; start
baseline/report-first unless the repo is mature.

**14. Final report.** Produce the report below.

## Upgradeability rules (restate in the report)

- Keep managed files separate from overrides (override via `.sentinel-shield/profile.yaml`).
- Document the installed Sentinel Shield **version/tag**.
- Document the selected **profile**.
- Document the **sync/upgrade** command (`sh scripts/sync-baseline.sh --target . --profile <name>`).
- **Dry-run sync before applying** any future upgrade; review drift first.
- Start **baseline / report-first** unless the repo is mature enough for `strict`.

## Final report (required)

```
Sentinel Shield install report
- repo / stack detected:
- profile selected (+ why):
- adoption mode (report-only/baseline/strict/regulated):
- tool provisioning mode (config-only / require-existing / bootstrap-tools):
- required tools INSTALLED (executable detected):
- required tools MISSING (config failure — do NOT mask):
- recommended tools INSTALLED:
- recommended tools SKIPPED (warning only):
- installed tag/version:
- files written (managed):    # from install-baseline dry-run/apply
- project-local files preserved (accepted-risks.json, baselines): yes/no
- active workflow jobs (PR / main / scheduled):
- gate wired (PR-fast / main): + pinned? yes/no
- Deptrac: wired / skipped (+ why)
- accepted risks created? : yes/no (+ justification)
- local validation: security-summary.json produced? yes/no ; doctor result
- CI validation: run id / result (pass or honest fail — findings NOT suppressed)
- git hygiene: .gitignore covers .env/.claude/vendor/node_modules/reports? yes/no
- secrets/artifacts committed? : MUST be no
- sync/upgrade command documented? : yes/no
- blockers / failures (verbatim, honest):
```

Remember: **audit first, never fake a clean gate, never commit secrets, stop and report on failure.**
